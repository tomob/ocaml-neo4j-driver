(* Unit tests for Cluster (routing) with mock servers: address selection per
   access mode (least-loaded, with the router fallback when a router's ROUTE
   fails). *)

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

(* The first refresh goes through a router whose ROUTE fails; the cluster falls
   back to the next router and still acquires a connection. *)
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
        (* router B: HELLO ok, ROUTE fails *)
        [
          ( (5, 0),
            List.nth received 1,
            [
              Test_mock.Success; Test_mock.Failure ("Neo.ClientError.Request.Invalid", "route down");
            ] );
        ];
        (* reader C: pool connection, then the fallback ROUTE, then a second
           pool connection (both acquires route to C) *)
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
      let c1 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      let c2 = match acquire () with Ok conn -> conn | Error e -> fail (Errors.to_string e) in
      (* The second acquire (a refresh, TTL 0) tried the failing router B — a
         ROUTE message reached it — and fell back to C. *)
      check bool "route attempted on the failing router" true
        (List.mem 0x66 (tags (List.nth received 1)));
      Cluster.release cluster c1;
      Cluster.release cluster c2;
      Cluster.close cluster)

let tests =
  [
    ( "[Cluster] acquire falls back to the next router",
      [ test_case "router ROUTE failure" `Quick acquire_falls_back_to_next_router ] );
    ( "[Cluster] per-role least loaded",
      [ test_case "independent role selection" `Quick per_role_least_loaded ] );
    ( "[Cluster] load balancing across readers",
      [ test_case "least-loaded reader" `Quick least_loaded_reader_selection ] );
    ( "[Cluster] concurrent acquires single fetch",
      [ test_case "single-flight routing" `Quick concurrent_acquires_single_fetch ] );
    ( "[Cluster] failed fetch negative cache",
      [ test_case "no re-fetch after failure" `Quick failed_fetch_negative_cache ] );
  ]
