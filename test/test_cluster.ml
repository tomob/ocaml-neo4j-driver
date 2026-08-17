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
      routing_context = None;
    }

let server addresses role =
  Packstream.Map
    [
      ("addresses", Packstream.List (List.map (fun a -> Packstream.String a) addresses));
      ("role", Packstream.String role);
    ]

let rt ?(ttl = 300L) ?db routers readers writers =
  let fields =
    [
      ("ttl", Packstream.Int ttl);
      ( "servers",
        Packstream.List [ server routers "ROUTE"; server readers "READ"; server writers "WRITE" ] );
    ]
    @ match db with Some db -> [ ("db", Packstream.String db) ] | None -> []
  in
  Packstream.Map fields

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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let c1 = ref None and c2 = ref None in
      Eio.Fiber.both
        (fun () ->
          c1 :=
            Some
              (match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)))
        (fun () ->
          c2 :=
            Some
              (match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)));
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
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
      let acquire mode =
        Cluster.acquire cluster ~mode ~database:None ~imp_user:None ~bookmarks:[]
      in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 =
        match acquire Config.Read with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match acquire Config.Write with
        | Ok (conn, _) -> conn
        | Error e -> fail (Errors.to_string e)
      in
      let c3 =
        match acquire Config.Read with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      let c4 =
        match acquire Config.Write with
        | Ok (conn, _) -> conn
        | Error e -> fail (Errors.to_string e)
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      check int "second read goes to the other reader" (List.nth ports 2) (port c2);
      Cluster.release cluster c1;
      let c3 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      check int "first read goes to B (tie, first)" (List.nth ports 1) (port c1);
      (match
         Conn.run c1 ~hydration:(Conn.hydration c1) ~query:"MATCH (n) RETURN n" ~parameters:[]
       with
      | Ok _ -> fail "expected the run on B to fail"
      | Error _ -> ());
      Cluster.release cluster c1;
      let c2 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
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
        (* router A: HELLO then ROUTE with writers C, then ROUTE with writers D
           (the refresh after the NotALeader) on the same reused connection *)
        [
          ( (5, 0),
            List.nth received 0,
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("rt", rt [ a ] [ a ] [ c ]) ];
              Test_mock.Success_meta [ ("rt", rt [ a ] [ a ] [ d ]) ];
            ] );
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Write ~database:None ~imp_user:None ~bookmarks:[]
      in
      let port conn = Addressing.port (Conn.address conn) in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      check int "write goes to C" (List.nth ports 1) (port c1);
      (match Conn.run c1 ~hydration:(Conn.hydration c1) ~query:"CREATE (n)" ~parameters:[] with
      | Ok _ -> fail "expected the run on C to fail"
      | Error _ -> ());
      Cluster.release cluster c1;
      let c2 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      check int "acquired connection is on B" (List.nth ports 1) (Addressing.port (Conn.address c1));
      let router_log = tags (List.nth received 0) in
      check int "procedure RUN on the router" 1 (count_tag 0x10 router_log);
      check int "procedure PULL on the router" 1 (count_tag 0x3F router_log);
      check int "no ROUTE message on the router" 0 (count_tag 0x66 router_log);
      Cluster.release cluster c1;
      Cluster.close cluster)

(* An [rt] routing table received from the server (SSR) replaces the cached
   table: the next acquire routes to the new address. *)
let update_table_replaces_table () =
  let received = List.init 3 (fun _ -> ref []) in
  Test_mock.with_servers 3
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      [
        (* router A: readers through B *)
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ b ] [ b ]) ] ] );
        ];
        (* reader B: one pool connection *)
        [ ((5, 0), List.nth received 1, [ Test_mock.Success ]) ];
        (* reader C: one pool connection *)
        [ ((5, 0), List.nth received 2, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let c1 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      check int "first read goes to B" (List.nth ports 1) (Addressing.port (Conn.address c1));
      let a = "127.0.0.1:" ^ string_of_int (List.nth ports 0) in
      let c = "127.0.0.1:" ^ string_of_int (List.nth ports 2) in
      Cluster.update_table cluster ~database:None ~imp_user:None (rt [ a ] [ c ] [ c ]);
      let c2 =
        match acquire () with Ok (conn, _) -> conn | Error e -> fail (Errors.to_string e)
      in
      check int "read after SSR table update goes to C" (List.nth ports 2)
        (Addressing.port (Conn.address c2));
      Cluster.release cluster c1;
      Cluster.release cluster c2;
      Cluster.close cluster)

(* End-to-end server-side routing: a session's RUN response carries an [rt]
   table (the server advertised ssr.enabled); the on_rt callback feeds it to
   the cluster, which then routes to the new address. *)
let session_rt_updates_routing_table () =
  let received = List.init 3 (fun _ -> ref []) in
  Test_mock.with_servers 3
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      let c = addr (List.nth ports 2) in
      [
        (* router A: readers through B *)
        [
          ( (5, 0),
            List.nth received 0,
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt [ a ] [ b ] [ b ]) ] ] );
        ];
        (* reader B: HELLO advertises ssr.enabled; the RUN's [rt] re-routes
           the readers to C *)
        [
          ( (5, 0),
            List.nth received 1,
            [
              Test_mock.Success_meta
                [ ("hints", Packstream.Map [ ("ssr.enabled", Packstream.Bool true) ]) ];
              Test_mock.Success_meta
                [
                  ("fields", Packstream.List [ Packstream.String "n" ]); ("rt", rt [ a ] [ c ] [ c ]);
                ];
            ] );
        ];
        (* reader C: one pool connection *)
        [ ((5, 0), List.nth received 2, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      let session_config = { Session.default_config with access_mode = Config.Read } in
      let session =
        Session.create session_config ~clock
          ~connect:(fun ~mode ~database ~bookmarks ->
            Cluster.acquire cluster ~mode ~database ~imp_user:None ~bookmarks)
          ~on_rt:(fun database rt -> Cluster.update_table cluster ~database ~imp_user:None rt)
          ()
      in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> ()
      | Error e -> fail (Errors.to_string e));
      Session.close session;
      let c2 =
        match
          Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
        with
        | Ok (conn, _) -> conn
        | Error e -> fail (Errors.to_string e)
      in
      check int "read after SSR re-routing goes to C" (List.nth ports 2)
        (Addressing.port (Conn.address c2));
      Cluster.release cluster c2;
      Cluster.close cluster)

(* The extra map of the ROUTE message (Bolt 4.4+: a map — the mock handshakes
   serve 5.0). *)
let route_extra received =
  match Packstream.unpack (List.hd !received) with
  | Ok (Packstream.Structure (0x66, [ Packstream.Map _; Packstream.List _; Packstream.Map extra ]))
    ->
      extra
  | _ -> fail "expected a ROUTE message"

(* The bookmarks of the ROUTE message (its second field). *)
let route_bookmarks received =
  match Packstream.unpack (List.hd !received) with
  | Ok
      (Packstream.Structure (0x66, [ Packstream.Map _; Packstream.List bookmarks; Packstream.Map _ ]))
    ->
      List.map
        (function Packstream.String b -> b | _ -> fail "expected a string bookmark")
        bookmarks
  | _ -> fail "expected a ROUTE message"

(* A default-database acquire resolves the home database from the ROUTE
   response's [db] field and caches it: the second acquire reuses it (and the
   aliased home-database table) without a new ROUTE. *)
let home_db_resolves_and_caches () =
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
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("rt", rt ~db:"homedb" [ a ] [ b ] [ b ]) ];
            ] );
        ];
        (* reader B: one pool connection per acquire *)
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
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let c1 =
        match acquire () with
        | Ok (conn, effective) ->
            check (option string) "first effective database" (Some "homedb") effective;
            conn
        | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match acquire () with
        | Ok (conn, effective) ->
            check (option string) "second effective database" (Some "homedb") effective;
            conn
        | Error e -> fail (Errors.to_string e)
      in
      check int "one ROUTE for two default-database acquires" 1
        (count_tag 0x66 (tags (List.nth received 0)));
      Cluster.release cluster c1;
      Cluster.release cluster c2;
      Cluster.close cluster)

(* An expired home-db cache entry is a miss: the next default-database acquire
   resolves (and routes) again. *)
let home_db_ttl_expires () =
  let received = List.init 2 (fun _ -> ref []) in
  Test_mock.with_servers 2
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      [
        (* router A: both ROUTEs on the same reused connection *)
        [
          ( (5, 0),
            List.nth received 0,
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("rt", rt ~ttl:0L ~db:"homedb" [ a ] [ b ] [ b ]) ];
              Test_mock.Success_meta [ ("rt", rt ~ttl:0L ~db:"homedb" [ a ] [ b ] [ b ]) ];
            ] );
        ];
        [
          ((5, 0), List.nth received 1, [ Test_mock.Success ]);
          ((5, 0), List.nth received 1, [ Test_mock.Success ]);
        ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let pool_config =
        match Config.make_pool_config ~home_db_cache_ttl:0.0 () with
        | Ok pool_config -> pool_config
        | Error error -> fail (Errors.to_string error)
      in
      let cluster = Cluster.create ~pool_config ~connect ~routing_context:[] ~initial clock in
      let acquire () =
        Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:None ~bookmarks:[]
      in
      let c1 =
        match acquire () with
        | Ok (conn, effective) ->
            check (option string) "first effective database" (Some "homedb") effective;
            conn
        | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match acquire () with
        | Ok (conn, effective) ->
            check (option string) "second effective database" (Some "homedb") effective;
            conn
        | Error e -> fail (Errors.to_string e)
      in
      check int "expired home-db cache re-routes" 2 (count_tag 0x66 (tags (List.nth received 0)));
      Cluster.release cluster c1;
      Cluster.release cluster c2;
      Cluster.close cluster)

(* The home-db cache is keyed by the impersonated user: two impersonations get
   separate ROUTEs and separate effective databases. *)
let home_db_per_imp_user () =
  let received = List.init 2 (fun _ -> ref []) in
  Test_mock.with_servers 2
    (fun ports ->
      let addr i = "127.0.0.1:" ^ string_of_int i in
      let a = addr (List.nth ports 0) in
      let b = addr (List.nth ports 1) in
      [
        (* router A: both ROUTEs on the same reused connection *)
        [
          ( (5, 0),
            List.nth received 0,
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("rt", rt ~ttl:0L ~db:"homedb-a" [ a ] [ b ] [ b ]) ];
              Test_mock.Success_meta [ ("rt", rt ~ttl:0L ~db:"homedb-b" [ a ] [ b ] [ b ]) ];
            ] );
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
      let c1 =
        match
          Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:(Some "a")
            ~bookmarks:[]
        with
        | Ok (conn, effective) ->
            check (option string) "user a's home database" (Some "homedb-a") effective;
            conn
        | Error e -> fail (Errors.to_string e)
      in
      let c2 =
        match
          Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:(Some "b")
            ~bookmarks:[]
        with
        | Ok (conn, effective) ->
            check (option string) "user b's home database" (Some "homedb-b") effective;
            conn
        | Error e -> fail (Errors.to_string e)
      in
      check int "one ROUTE per impersonated user" 2 (count_tag 0x66 (tags (List.nth received 0)));
      Cluster.release cluster c1;
      Cluster.release cluster c2;
      Cluster.close cluster)

(* The ROUTE request carries the impersonated user in its extra map (Bolt
   4.4+), so the server resolves that user's home database. *)
let route_carries_imp_user () =
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
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("rt", rt ~db:"homedb" [ a ] [ b ] [ b ]) ];
            ] );
        ];
        [ ((5, 0), List.nth received 1, [ Test_mock.Success ]) ];
      ])
    (fun net clock sw ports ->
      let initial = Addressing.IPv4 ("127.0.0.1", List.nth ports 0) in
      let connect addr = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port addr)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      (match
         Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:(Some "u") ~bookmarks:[]
       with
      | Ok (conn, _) ->
          let extra = route_extra (List.nth received 0) in
          check string "imp_user in the ROUTE extra" "u"
            (match List.assoc_opt "imp_user" extra with
            | Some (Packstream.String user) -> user
            | _ -> "");
          check bool "no db in the ROUTE extra" true (List.assoc_opt "db" extra = None);
          Cluster.release cluster conn
      | Error e -> fail (Errors.to_string e));
      Cluster.close cluster)

(* A routed session's bookmarks go into the ROUTE request when its routing
   table is first fetched (the server uses them for routing), so a session
   created with bookmarks sends them on the first acquire. *)
let route_carries_session_bookmarks () =
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
          ( (5, 0),
            List.nth received 1,
            [
              Test_mock.Success;
              Test_mock.Success_meta [ ("fields", Packstream.List [ Packstream.String "n" ]) ];
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
      let session_config = { Session.default_config with bookmarks = [ "bm1"; "bm2" ] } in
      let session =
        Session.create session_config ~clock
          ~connect:(fun ~mode ~database ~bookmarks ->
            Cluster.acquire cluster ~mode ~database ~imp_user:None ~bookmarks)
          ()
      in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> ()
      | Error e -> fail (Errors.to_string e));
      Session.close session;
      check bool "session bookmarks on the ROUTE" true
        (route_bookmarks (List.nth received 0) = [ "bm1"; "bm2" ]);
      Cluster.close cluster)

(* An SSR [rt] table (update_table) caches the home database and its table: the
   next default-database acquire for the same user reuses both without a
   ROUTE. *)
let update_table_captures_home_db () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((5, 0), received, [ Test_mock.Success ]))
    (fun net clock sw port ->
      let addr = "127.0.0.1:" ^ string_of_int port in
      let initial = Addressing.IPv4 ("127.0.0.1", port) in
      let connect a = Conn.connect net clock sw (config "127.0.0.1" (Addressing.port a)) in
      let cluster =
        Cluster.create ~pool_config:Config.default_pool_config ~connect ~routing_context:[] ~initial
          clock
      in
      Cluster.update_table cluster ~database:None ~imp_user:(Some "u")
        (rt ~db:"homedb" [ addr ] [ addr ] [ addr ]);
      (match
         Cluster.acquire cluster ~mode:Config.Read ~database:None ~imp_user:(Some "u") ~bookmarks:[]
       with
      | Ok (conn, effective) ->
          check (option string) "effective database from SSR table" (Some "homedb") effective;
          check int "no ROUTE after the SSR table update" 0 (count_tag 0x66 (tags received));
          Cluster.release cluster conn
      | Error e -> fail (Errors.to_string e));
      Cluster.close cluster)

(* The cached table is visible through routing_table_of only after a fetch; a
   forced update stores the table (with the ROUTE bookmarks on the wire), and a
   following acquire uses its readers. *)
let routing_table_of_returns_cached () =
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
            [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt ~db:"adb" [ a ] [ b ] [ b ]) ] ]
          );
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
      check bool "no table before the first fetch" true
        (Cluster.routing_table_of cluster ~database:None = None);
      (match
         Cluster.force_routing_table_update cluster ~database:(Some "adb") ~bookmarks:[ "bm" ]
       with
      | Ok () -> ()
      | Error e -> fail (Errors.to_string e));
      check bool "forced update stored the table" true
        (match Cluster.routing_table_of cluster ~database:(Some "adb") with
        | Some table -> Routing_table.database table = Some "adb"
        | None -> false);
      check bool "the requested bookmarks went out on the ROUTE" true
        (route_bookmarks (List.nth received 0) = [ "bm" ]);
      let c1 =
        match
          Cluster.acquire cluster ~mode:Config.Read ~database:(Some "adb") ~imp_user:None
            ~bookmarks:[]
        with
        | Ok (conn, _) -> conn
        | Error e -> fail (Errors.to_string e)
      in
      check int "acquire uses the forced table's readers" (List.nth ports 1)
        (Addressing.port (Conn.address c1));
      check int "no new ROUTE for a fresh forced table" 1
        (count_tag 0x66 (tags (List.nth received 0)));
      Cluster.release cluster c1;
      Cluster.close cluster)

(* A failed forced update returns the error and stores nothing. *)
let force_routing_table_update_failure () =
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
      (match Cluster.force_routing_table_update cluster ~database:(Some "adb") ~bookmarks:[] with
      | Ok () -> fail "expected the forced update to fail"
      | Error _ -> ());
      check bool "failed forced update stores no table" true
        (Cluster.routing_table_of cluster ~database:(Some "adb") = None);
      Cluster.close cluster)

let tests =
  [
    ( "[Cluster] acquire falls back to the next router",
      [ test_case "router ROUTE failure" `Quick acquire_falls_back_to_next_router ] );
    ( "[Cluster] routing table is readable before and after a fetch",
      [ test_case "routing_table_of + forced update" `Quick routing_table_of_returns_cached ] );
    ( "[Cluster] forced update failure stores nothing",
      [ test_case "error surfaced, table untouched" `Quick force_routing_table_update_failure ] );
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
    ( "[Cluster] SSR update replaces the table",
      [ test_case "update_table re-routes" `Quick update_table_replaces_table ] );
    ( "[Cluster] SSR rt from a session run updates the table",
      [ test_case "on_rt end-to-end" `Quick session_rt_updates_routing_table ] );
    ( "[Cluster] home-db resolves and caches",
      [ test_case "default-db acquire reuses the home db" `Quick home_db_resolves_and_caches ] );
    ( "[Cluster] home-db cache TTL expiry",
      [ test_case "expired entry re-routes" `Quick home_db_ttl_expires ] );
    ( "[Cluster] home-db cache per impersonated user",
      [ test_case "separate home dbs" `Quick home_db_per_imp_user ] );
    ( "[Cluster] ROUTE carries the impersonated user",
      [ test_case "imp_user in the ROUTE extra" `Quick route_carries_imp_user ] );
    ( "[Cluster] ROUTE carries the session's bookmarks",
      [ test_case "bookmarks in the ROUTE request" `Quick route_carries_session_bookmarks ] );
    ( "[Cluster] SSR update captures the home db",
      [ test_case "update_table seeds the cache" `Quick update_table_captures_home_db ] );
  ]
