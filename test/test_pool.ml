(* Unit tests for the connection pool (acquire/reuse, lifetime, liveness,
   defunct connections and the acquisition timeout) on a mock Bolt server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let config host port scheme =
  Conn.
    {
      host;
      port;
      scheme;
      connection_timeout = 5.0;
      user_agent = "test-agent";
      auth = Conn.basic_auth ();
      routing_context = None;
      telemetry_disabled = false;
    }

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, _)) -> tag
  | _ -> fail "expected a structure"

let message_tags received = List.map unpack_message (List.rev !received)

(* Connect to the mock server and run [query] to completion on [conn]. *)
let run_query conn query =
  let hydration = Conn.hydration conn in
  (match Conn.run conn ~hydration ~query ~parameters:[] with
  | Ok _ -> ()
  | Error e -> fail (Errors.to_string e));
  match Conn.pull conn ~hydration with
  | Ok (_, Ok _) -> ()
  | Ok (_, Error e) -> fail (Errors.to_string e)
  | Error e -> fail (Errors.to_string e)

(* A pool whose connections come from the mock server at [port]. *)
let pool net clock sw port ?(pool_config = Config.default_pool_config) () =
  let connect () = Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) in
  Pool.create ~pool_config ~connect clock

(* A pool whose connections resolve their token from [manager] at connect time,
   with the manager wired in (like the Driver). *)
let pool_with_manager net clock sw port ?(pool_config = Config.default_pool_config)
    (manager : Auth_manager.t) () =
  let connect () =
    match manager.get_auth () with
    | Ok auth -> Conn.connect net clock sw { (config "127.0.0.1" port Addressing.Bolt) with auth }
    | Error _ -> fail "get_auth"
  in
  Pool.create ~pool_config ~connect ~auth_manager:(Some manager) clock

(* Acquire, use and release a connection; the second acquire reuses it (no new
   HELLO: the wire has RUN/PULL for the second use, not HELLO/LOGON). *)
let reuse () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([ [ Packstream.Int 1L ] ], false);
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([ [ Packstream.Int 2L ] ], false);
         ] ))
    (fun net clock sw port ->
      let pool = pool net clock sw port () in
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 1";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 2";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire" [ 0x01; 0x6A; 0x10; 0x3F; 0x0F; 0x10; 0x3F ] (message_tags received))

(* A connection that failed a query is closed on release; the next acquire
   creates a fresh one (HELLO again). *)
let defunct_not_reused () =
  let received = ref [] in
  Test_mock.with_mock_multi
    [
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Failure ("Neo.ClientError.Statement.SyntaxError", "bad");
        ] );
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Records ([ [ Packstream.Int 1L ] ], false);
        ] );
    ]
    (fun net clock sw port ->
      let pool = pool net clock sw port () in
      (match Pool.acquire pool with
      | Ok conn ->
          let hydration = Conn.hydration conn in
          (match Conn.run conn ~hydration ~query:"NOT CYPHER" ~parameters:[] with
          | Ok _ -> fail "expected a failure"
          | Error _ -> ());
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 1";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire" [ 0x01; 0x6A; 0x10; 0x01; 0x6A; 0x10; 0x3F ] (message_tags received))

(* A connection idle past its max lifetime is closed on reuse; a fresh one is
   created. *)
let lifetime_expired () =
  let received = ref [] in
  Test_mock.with_mock_multi
    [
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Records ([ [ Packstream.Int 1L ] ], false);
        ] );
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Records ([ [ Packstream.Int 2L ] ], false);
        ] );
    ]
    (fun net clock sw port ->
      let pool_config = { Config.default_pool_config with max_connection_lifetime = 0.0 } in
      let pool = pool net clock sw port ~pool_config () in
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 1";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 2";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire"
        [ 0x01; 0x6A; 0x10; 0x3F; 0x01; 0x6A; 0x10; 0x3F ]
        (message_tags received))

(* With a liveness check enabled, reusing an idle connection sends a RESET. *)
let liveness_check () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([ [ Packstream.Int 1L ] ], false);
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([ [ Packstream.Int 2L ] ], false);
         ] ))
    (fun net clock sw port ->
      let pool_config = { Config.default_pool_config with liveness_check_timeout = Some 0.5 } in
      let pool = pool net clock sw port ~pool_config () in
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 1";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      (match Pool.acquire pool with
      | Ok conn ->
          run_query conn "RETURN 2";
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire" [ 0x01; 0x6A; 0x10; 0x3F; 0x0F; 0x10; 0x3F ] (message_tags received))

(* A pool of size 1 with a short acquisition timeout: while the only connection
   is held, a second acquire fails with Connection_acquisition_timeout. *)
let acquisition_timeout () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let pool_config =
        {
          Config.default_pool_config with
          max_connection_pool_size = 1;
          connection_acquisition_timeout = 0.05;
        }
      in
      let pool = pool net clock sw port ~pool_config () in
      match Pool.acquire pool with
      | Error e -> fail (Errors.to_string e)
      | Ok _ -> (
          (* The first connection is still held, so the pool (size 1) is full. *)
          match Pool.acquire pool with
          | Error (Errors.Connection_acquisition_timeout _) -> ()
          | Ok _ -> fail "expected an acquisition timeout"
          | Error _ -> fail "expected Connection_acquisition_timeout"))

(* After the pool is closed, acquire fails and a released connection is closed
   (not returned to the idle queue, so no RESET is sent). *)
let closed_pool () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), received, [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let pool = pool net clock sw port () in
      let conn =
        match Pool.acquire pool with Ok conn -> conn | Error e -> fail (Errors.to_string e)
      in
      Pool.close pool;
      (match Pool.acquire pool with
      | Error (Errors.Connection_pool_error _) -> ()
      | Ok _ -> fail "acquire on a closed pool should fail"
      | Error _ -> fail "expected Connection_pool_error");
      Pool.release pool conn;
      check (list int) "wire" [ 0x01; 0x6A ] (message_tags received))

(* Session.close is idempotent: the connection is released once (the second
   close releases nothing, so no second RESET). *)
let session_close_once () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([ [ Packstream.Int 1L ] ], false);
         ] ))
    (fun net clock sw port ->
      let pool = pool net clock sw port () in
      let session =
        Session.create Session.default_config ~clock
          ~connect:(fun ~mode:_ ~database:_ ~bookmarks:_ ->
            match Pool.acquire pool with Ok conn -> Ok (conn, None) | Error error -> Error error)
          ~release:(fun conn -> Pool.release pool conn)
          ()
      in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.values result with Ok _ -> () | Error e -> fail (Errors.to_string e))
      | Error e -> fail (Errors.to_string e));
      Session.close session;
      Session.close session;
      check (list int) "wire" [ 0x01; 0x6A; 0x10; 0x3F ] (message_tags received))

(* The in-use count tracks checked-out connections: 0 when idle, 1 while held,
   back to 0 after release, and 1 again when the idle connection is reused. *)
let in_use_count () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ((5, 4), received, [ Test_mock.Success; Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let pool = pool net clock sw port () in
      check int "fresh pool" 0 (Pool.in_use_count pool);
      (match Pool.acquire pool with
      | Ok conn ->
          check int "held connection" 1 (Pool.in_use_count pool);
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check int "released" 0 (Pool.in_use_count pool);
      match Pool.acquire pool with
      | Ok conn ->
          check int "reused connection" 1 (Pool.in_use_count pool);
          Pool.release pool conn
      | Error e -> fail (Errors.to_string e))

(* A reused connection is re-authenticated when the manager's token changed
   (RESET liveness check, then LOGOFF + LOGON on the wire). *)
let re_auth_on_token_change () =
  let received = ref [] in
  let current = ref (Conn.basic_auth ~credentials:"pw1" ()) in
  (* A manager that always returns the current token (the cache of a [basic]
     manager would not observe the external change). *)
  let manager : Auth_manager.t =
    { get_auth = (fun () -> Ok !current); handle_security_exception = (fun _ _ -> Ok false) }
  in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let pool = pool_with_manager net clock sw port manager () in
      (match Pool.acquire pool with
      | Ok conn -> Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      current := Conn.basic_auth ~credentials:"pw2" ();
      (match Pool.acquire pool with
      | Ok conn -> Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire" [ 0x01; 0x6A; 0x0F; 0x6B; 0x6A ] (message_tags received))

(* An AuthorizationExpired marks every pooled connection unauthenticated: an
   idle connection not involved in the failure re-authenticates on its next
   acquire. Two mock servers stand in for the two pooled connections. *)
let authorization_expired_marks_all () =
  let received_a = ref [] in
  let received_b = ref [] in
  let manager =
    Auth_manager.basic ~provider:(fun () -> Ok (Conn.basic_auth ~credentials:"pw" ()))
  in
  Test_mock.with_servers 2
    (fun _ports ->
      [
        [
          ( (5, 4),
            received_a,
            [
              Test_mock.Success;
              Test_mock.Success;
              Test_mock.Success;
              Test_mock.Success;
              Test_mock.Success;
            ] );
        ];
        [
          ( (5, 4),
            received_b,
            [
              Test_mock.Success;
              Test_mock.Success;
              Test_mock.Failure ("Neo.ClientError.Security.AuthorizationExpired", "expired");
              Test_mock.Success;
              Test_mock.Success;
              Test_mock.Success;
              Test_mock.Success;
            ] );
        ];
      ])
    (fun net clock sw ports ->
      let server_a = List.nth ports 0 in
      let server_b = List.nth ports 1 in
      (* Connections alternate between the two servers: conn1 on A, conn2 on B. *)
      let counter = ref 0 in
      let connect () =
        let port = if !counter = 0 then server_a else server_b in
        incr counter;
        match manager.get_auth () with
        | Ok auth ->
            Conn.connect net clock sw { (config "127.0.0.1" port Addressing.Bolt) with auth }
        | Error _ -> fail "get_auth"
      in
      let pool =
        Pool.create ~pool_config:Config.default_pool_config ~connect ~auth_manager:(Some manager)
          clock
      in
      (* Both connections are held while conn2's query fails. *)
      let conn1 = match Pool.acquire pool with Ok c -> c | Error e -> fail (Errors.to_string e) in
      let conn2 = match Pool.acquire pool with Ok c -> c | Error e -> fail (Errors.to_string e) in
      let hydration = Conn.hydration conn2 in
      (match Conn.run conn2 ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> fail "expected an AuthorizationExpired"
      | Error _ -> ());
      (* The hook cleared the token of the idle-and-held conn1 too. *)
      check bool "other connection marked unauthenticated" true
        (Option.is_none (Conn.current_auth conn1));
      check bool "failing connection marked unauthenticated" true
        (Option.is_none (Conn.current_auth conn2));
      Pool.release pool conn1;
      Pool.release pool conn2;
      (* Re-acquiring both re-authenticates them (RESET, LOGOFF + LOGON each). *)
      (match Pool.acquire pool with
      | Ok conn -> Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      (match Pool.acquire pool with
      | Ok conn -> Pool.release pool conn
      | Error e -> fail (Errors.to_string e));
      check (list int) "conn1 wire" [ 0x01; 0x6A; 0x0F; 0x6B; 0x6A ] (message_tags received_a);
      check (list int) "conn2 wire"
        [ 0x01; 0x6A; 0x10; 0x0F; 0x0F; 0x6B; 0x6A ]
        (message_tags received_b))

(* A handled security error (basic manager + Unauthorized) is marked retryable
   and the manager refreshes its token. *)
let security_error_makes_retryable () =
  let count = ref 0 in
  let provider () =
    incr count;
    Ok (Conn.basic_auth ~credentials:(Printf.sprintf "pw%d" !count) ())
  in
  let manager = Auth_manager.basic ~provider in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         ref [],
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure ("Neo.ClientError.Security.Unauthorized", "bad creds");
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let pool = pool_with_manager net clock sw port manager () in
      let conn = match Pool.acquire pool with Ok c -> c | Error e -> fail (Errors.to_string e) in
      let hydration = Conn.hydration conn in
      (match Conn.run conn ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Error error -> check bool "error marked retryable" true (Errors.is_retryable error)
      | Ok _ -> fail "expected an Unauthorized failure");
      check int "provider refreshed on Unauthorized" 2 !count;
      Pool.release pool conn)

let tests =
  [
    ("[Pool] reuse", [ test_case "reuse idle" `Quick reuse ]);
    ("[Pool] defunct", [ test_case "failed conn not reused" `Quick defunct_not_reused ]);
    ("[Pool] lifetime", [ test_case "expired not reused" `Quick lifetime_expired ]);
    ("[Pool] liveness", [ test_case "reset on reuse" `Quick liveness_check ]);
    ("[Pool] in-use count", [ test_case "checked-out tracking" `Quick in_use_count ]);
    ("[Pool] acquisition timeout", [ test_case "timeout" `Quick acquisition_timeout ]);
    ("[Pool] closed", [ test_case "closed pool" `Quick closed_pool ]);
    ("[Pool] session close once", [ test_case "idempotent close" `Quick session_close_once ]);
    ( "[Pool] re-auth on token change",
      [ test_case "rotated token re-authenticates" `Quick re_auth_on_token_change ] );
    ( "[Pool] AuthorizationExpired",
      [ test_case "marks all connections unauthenticated" `Quick authorization_expired_marks_all ]
    );
    ( "[Pool] security error retryable",
      [ test_case "handled security error marked retryable" `Quick security_error_makes_retryable ]
    );
  ]
