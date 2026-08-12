(* Unit tests for Cluster (routing) with mock servers: address selection per
   access mode (least-loaded), the router fallback when a router's ROUTE fails,
   and address deactivation (failed servers are dropped until a refresh re-lists
   them). *)

open Neodriver
open Neodriver_eio
open Alcotest

let auth () = Conn.{ scheme = "basic"; principal = "neo4j"; credentials = "password" }

let config host port =
  Conn.
    {
      host;
      port;
      scheme = Addressing.Bolt;
      connection_timeout = 5.0;
      user_agent = "test-agent";
      auth = auth ();
    }

let server addresses role =
  Packstream.Map
    [
      ("addresses", Packstream.List (List.map (fun a -> Packstream.String a) addresses));
      ("role", Packstream.String role);
    ]

let rt ?(ttl = 300L) routers readers writers =
  Packstream.Map
    [
      ("ttl", Packstream.Int ttl);
      ( "servers",
        Packstream.List [ server routers "ROUTE"; server readers "READ"; server writers "WRITE" ] );
    ]

(* The RUN metadata of the routing procedure: its [fields]. *)
let procedure_fields_meta =
  [ ("fields", Packstream.List [ Packstream.String "ttl"; Packstream.String "servers" ]) ]

(* The single record the routing procedure returns: [ttl] followed by the
   [servers] list (the same shape as the ROUTE message's [rt]). *)
let procedure_record ?(ttl = 300L) routers readers writers =
  [
    Packstream.Int ttl;
    Packstream.List [ server routers "ROUTE"; server readers "READ"; server writers "WRITE" ];
  ]

let message_tag bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, _)) -> tag
  | _ -> fail "expected a structure"

let tags received = List.rev !received |> List.map message_tag
let count_tag tag log = List.fold_left (fun acc t -> if t = tag then acc + 1 else acc) 0 log

(* Concurrent acquires of the same database trigger a single routing-table fetch:
   the others wait on the in-flight marker instead of re-fetching. *)
let concurrent_acquires_single_fetch () =
  let received = List.init 2 (fun _ -> ref []) in
  Test_mock.with_servers 2
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      [
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ b ] [ b ]) ] ] );
        ];
        [
          ((5, 0), List.nth received 1, [ Test_mock.Success ]);
          ((5, 0), List.nth received 1, [ Test_mock.Success ]);
        ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      let c1 = ref None and c2 = ref None in
      Eio.Fiber.both
        (fun () ->
          c1 :=
            Some (match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e)))
        (fun () ->
          c2 :=
            Some (match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e)));
      let c1 = match !c1 with Some conn -> conn | None -> assert false in
      let c2 = match !c2 with Some conn -> conn | None -> assert false in
      check int "single ROUTE under concurrency" 1 (count_tag 0x66 (tags (List.nth received 0)));
      List.iter (fun conn -> Cluster.release cluster conn) [ c1; c2 ];
      Cluster.close cluster)

(* A failed fetch is remembered (negative cache): a following acquire gets the
   error without re-fetching. *)
let failed_fetch_negative_cache () =
  let received = ref [] in
  Test_mock.with_servers 1
    (fun _ports ->
      [
        [
          ( (5, 0),
            received,
            [
              Test_mock.Success; Test_mock.Failure ("Neo.ClientError.Request.Invalid", "route down");
            ] );
        ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      (match acquire () with Ok _ -> fail "expected the first acquire to fail" | Error _ -> ());
      (match acquire () with Ok _ -> fail "expected the second acquire to fail" | Error _ -> ());
      check int "no re-fetch on the negative cache" 1 (count_tag 0x66 (tags received));
      Cluster.close cluster)

(* Each role is selected independently (least-loaded): with two readers and one
   writer, a read/write/read/write sequence while holding the connections goes
   to the least-loaded reader each time and keeps hitting the single writer. *)
let per_role_least_loaded () =
  let received = List.init 4 (fun _ -> ref []) in
  Test_mock.with_servers 4
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      let c = addr (List.nth ports 2) in
      let d = addr (List.nth ports 3) in
      [
        (* router A: tables routing readers through B/C and the writer to D *)
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ b; c ] [ d ]) ] ] );
        ];
        (* readers B and C: one pool connection each *)
        [ ((5, 0), List.nth received 1, [ Test_mock.Success ]) ];
        [ ((5, 0), List.nth received 2, [ Test_mock.Success ]) ];
        (* writer D: one pool connection per write *)
        [
          ((5, 0), List.nth received 3, [ Test_mock.Success ]);
          ((5, 0), List.nth received 3, [ Test_mock.Success ]);
        ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire mode = Cluster.acquire cluster ~mode ~database:None in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 =
        match acquire Config.Read with Ok conn -> conn | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match acquire Config.Write with Ok conn -> conn | Error e -> fail (Errors.to_string e)
      in
      let c3 =
        match acquire Config.Read with Ok conn -> conn | Error e -> fail (Errors.to_string e)
      in
      let c4 =
        match acquire Config.Write with Ok conn -> conn | Error e -> fail (Errors.to_string e)
      in
      let p1, p2, p3 = (List.nth ports 1, List.nth ports 2, List.nth ports 3) in
      check (list int) "read/write least-loaded" [ p1; p3; p2; p3 ]
        [ port c1; port c2; port c3; port c4 ];
      List.iter (fun conn -> Cluster.release cluster conn) [ c1; c2; c3; c4 ];
      Cluster.close cluster)

(* Load balancing across readers: with readers B and C both idle, the first
   read goes to B (tie broken by list order); while B is held, the second read
   goes to C (B is now the more loaded); after B is released the next read goes
   back to B (both idle again). *)
let least_loaded_reader_selection () =
  let received = List.init 3 (fun _ -> ref []) in
  Test_mock.with_servers 3
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      let c = addr (List.nth ports 2) in
      [
        (* router A: readers B and C *)
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ b; c ] [ b ]) ] ] );
        ];
        (* reader B: one connection per acquire. The RESET of the first
           release is answered by the mock's closed flow, so the pool closes
           the connection instead of reusing it. *)
        [
          ((5, 0), List.nth received 1, [ Test_mock.Success ]);
          ((5, 0), List.nth received 1, [ Test_mock.Success ]);
        ];
        (* reader C: the middle acquire only *)
        [ ((5, 0), List.nth received 2, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      let c2 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "second read goes to the other reader" (List.nth ports 2) (port c2);
      Cluster.release cluster c1;
      let c3 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "read after release returns to the first reader" (List.nth ports 1) (port c3);
      Cluster.release cluster c2;
      Cluster.release cluster c3;
      Cluster.close cluster)

(* The first refresh goes through a router whose ROUTE fails with a non-fatal
   error; the router is deactivated and the cluster falls back to the next one.
   A later refresh (TTL 0) skips the deactivated router. *)
let acquire_falls_back_to_next_router () =
  let received = List.init 3 (fun _ -> ref []) in
  Test_mock.with_servers 3
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let b = addr (List.nth ports 1) in
      let c = addr (List.nth ports 2) in
      [
        (* router A (initial): returns a table routing through B and C *)
        [
          ( (5, 0),
            List.nth received 0,
            [
              Test_mock.Success; Test_mock.Success_meta [ ("rt", rt ~ttl:0L [ b; c ] [ c ] [ c ]) ];
            ] );
        ];
        (* router B: HELLO ok, ROUTE fails (non-fatal -> deactivated) *)
        [
          ( (5, 0),
            List.nth received 1,
            [
              Test_mock.Success;
              Test_mock.Failure ("Neo.TransientError.General.DatabaseUnavailable", "route down");
            ] );
        ];
        (* reader/router C: the first pool connection, the fallback ROUTE, then
           the second pool connection (both acquires route to C) *)
        [
          ((5, 0), List.nth received 2, [ Test_mock.Success ]);
          ( (5, 0),
            List.nth received 2,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt ~ttl:0L [ c ] [ c ] [ c ]) ] ]
          );
          ((5, 0), List.nth received 2, [ Test_mock.Success ]);
        ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      let c2 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "the failing router got exactly one ROUTE" 1
        (count_tag 0x66 (tags (List.nth received 1)));
      check int "first connection is on C" (List.nth ports 2) (port c1);
      check int "second connection is on C" (List.nth ports 2) (port c2);
      Cluster.release cluster c1;
      Cluster.release cluster c2;
      Cluster.close cluster)

(* A DatabaseUnavailable error on a pool connection deactivates the address: a
   following acquire picks a different reader. *)
let deactivate_on_database_unavailable () =
  let received = List.init 3 (fun _ -> ref []) in
  Test_mock.with_servers 3
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      let c = addr (List.nth ports 2) in
      [
        (* router A: readers B and C *)
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ b; c ] [ b ]) ] ] );
        ];
        (* reader B: HELLO ok, RUN fails with DatabaseUnavailable *)
        [
          ( (5, 0),
            List.nth received 1,
            [
              Test_mock.Success;
              Test_mock.Failure ("Neo.TransientError.General.DatabaseUnavailable", "db down");
            ] );
        ];
        (* reader C: the second acquire's connection *)
        [ ((5, 0), List.nth received 2, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "first read goes to B (tie, first)" (List.nth ports 1) (port c1);
      (match
         Conn.run c1 ~hydration:(Conn.hydration c1) ~query:"MATCH (n) RETURN n" ~parameters:[]
       with
      | Ok _ -> fail "expected the run on B to fail"
      | Error _ -> ());
      Cluster.release cluster c1;
      let c2 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "read after deactivation goes to C" (List.nth ports 2) (port c2);
      Cluster.release cluster c2;
      Cluster.close cluster)

(* A NotALeader error removes the address from the writers: the next write
   acquires a refreshed table and goes to the new writer. *)
let remove_writer_on_not_a_leader () =
  let received = List.init 3 (fun _ -> ref []) in
  Test_mock.with_servers 3
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let c = addr (List.nth ports 1) in
      let d = addr (List.nth ports 2) in
      [
        (* router A: writers C, then D (the second ROUTE after the refresh) *)
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ a ] [ c ]) ] ] );
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ a ] [ d ]) ] ] );
        ];
        (* writer C: HELLO ok, RUN fails with NotALeader *)
        [
          ( (5, 0),
            List.nth received 1,
            [
              Test_mock.Success;
              Test_mock.Failure ("Neo.ClientError.Cluster.NotALeader", "not the leader");
            ] );
        ];
        (* writer D: the second acquire's connection *)
        [ ((5, 0), List.nth received 2, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Write ~database:None in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "write goes to C" (List.nth ports 1) (port c1);
      (match Conn.run c1 ~hydration:(Conn.hydration c1) ~query:"CREATE (n)" ~parameters:[] with
      | Ok _ -> fail "expected the run on C to fail"
      | Error _ -> ());
      Cluster.release cluster c1;
      let c2 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "write after NotALeader goes to D" (List.nth ports 2) (port c2);
      check int "two ROUTEs to the router" 2 (count_tag 0x66 (tags (List.nth received 0)));
      Cluster.release cluster c2;
      Cluster.close cluster)

(* A dead reader is deactivated on acquire failure; the next acquire retries on
   the surviving reader. *)
let acquire_retries_after_dead_reader () =
  let received = List.init 2 (fun _ -> ref []) in
  Test_mock.with_servers 2
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      [
        (* router A: readers "127.0.0.1:1" (unreachable) and B *)
        [
          ( (5, 0),
            List.nth received 0,
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("rt", rt [ a ] [ "127.0.0.1:1"; b ] [ b ]) ];
            ] );
        ];
        (* reader B: the retried acquire's connection *)
        [ ((5, 0), List.nth received 1, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr =
        if Addressing.port addr = 1 then Error (Errors.Service_unavailable "server down")
        else Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr))
      in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "acquire retries on the surviving reader" (List.nth ports 1)
        (Addressing.port (Conn.address c1));
      Cluster.release cluster c1;
      Cluster.close cluster)

(* A Bolt 4.2 router serves its routing table through the procedure fallback:
   the cluster's acquire routes over RUN/PULL instead of the ROUTE message. *)
let routing_via_procedure_bolt42 () =
  let received = List.init 2 (fun _ -> ref []) in
  Test_mock.with_servers 2
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      [
        (* router A (Bolt 4.2): the procedure RUN/PULL returning a table routing
           readers through B *)
        [
          ( (4, 2),
            List.nth received 0,
            [
              Test_mock.Success;
              Test_mock.Success_meta procedure_fields_meta;
              Test_mock.Records ([ procedure_record [ a ] [ b ] [ b ] ], false);
            ] );
        ];
        (* reader B: one pool connection *)
        [ ((5, 0), List.nth received 1, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () = Cluster.acquire cluster ~mode:Config.Read ~database:None in
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      check int "acquired connection is on B" (List.nth ports 1) (Addressing.port (Conn.address c1));
      let router_log = tags (List.nth received 0) in
      check int "procedure RUN on the router" 1 (count_tag 0x10 router_log);
      check int "procedure PULL on the router" 1 (count_tag 0x3F router_log);
      check int "no ROUTE message on the router" 0 (count_tag 0x66 router_log);
      Cluster.release cluster c1;
      Cluster.close cluster)

let tests =
  [
    ( "[Cluster] acquire falls back to the next router",
      [ test_case "router ROUTE failure" `Quick acquire_falls_back_to_next_router ] );
    ( "[Cluster] deactivate on DatabaseUnavailable",
      [ test_case "address dropped on db-down" `Quick deactivate_on_database_unavailable ] );
    ( "[Cluster] remove writer on NotALeader",
      [ test_case "writer dropped on NotALeader" `Quick remove_writer_on_not_a_leader ] );
    ( "[Cluster] acquire retries after a dead reader",
      [ test_case "deactivate and retry" `Quick acquire_retries_after_dead_reader ] );
    ( "[Cluster] per-role least loaded",
      [ test_case "independent role selection" `Quick per_role_least_loaded ] );
    ( "[Cluster] load balancing across readers",
      [ test_case "least-loaded reader" `Quick least_loaded_reader_selection ] );
    ( "[Cluster] concurrent acquires single fetch",
      [ test_case "single-flight routing" `Quick concurrent_acquires_single_fetch ] );
    ( "[Cluster] failed fetch negative cache",
      [ test_case "no re-fetch after failure" `Quick failed_fetch_negative_cache ] );
    ( "[Cluster] routing via the procedure fallback",
      [ test_case "Bolt 4.2 router" `Quick routing_via_procedure_bolt42 ] );
  ]
