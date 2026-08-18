(* Unit tests for Session (auto-commit run and managed transactions with retry)
   on a mock Bolt server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let auth ?(principal = "neo4j") ?(credentials = "password") () =
  Conn.{ scheme = "basic"; principal; credentials }

let config host port scheme =
  Conn.
    {
      host;
      port;
      scheme;
      connection_timeout = 5.0;
      user_agent = "test-agent";
      auth = auth ();
      routing_context = None;
    }

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) ->
      (tag, match fields with [ Packstream.Map m ] -> m | _ -> [])
  | _ -> fail "expected a structure"

let message_tags received = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received)

(* A session whose connection connects to the mock server at [port]. *)
let session net clock sw port =
  let connect ~mode:_ ~database:_ ~bookmarks:_ =
    match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
    | Ok conn -> Ok (conn, None)
    | Error error -> Error error
  in
  Session.create Session.default_config ~clock ~connect ()

let transient_error () =
  Errors.of_neo4j_code ~code:"Neo.TransientError.General.DatabaseUnavailable" ~message:"transient"

let client_error () =
  Errors.of_neo4j_code ~code:"Neo.ClientError.Statement.SyntaxError" ~message:"bad"

(* A unit of work that runs one query inside the transaction and returns its
   outcome (a server failure surfaces as [Driver _]). *)
let run_work session attempts tx =
  incr attempts;
  let conn =
    match Session.conn session with Ok conn -> conn | Error e -> fail (Errors.to_string e)
  in
  match Tx.run tx ~hydration:(Conn.hydration conn) ~query:"RETURN 1" ~parameters:[] with
  | Ok _ -> Ok ()
  | Error error -> Error (Session.Driver error)

(* A successful managed transaction: work returns Ok, the transaction is
   committed and the session records the bookmark. *)
let execute_ok () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([], false);
           Test_mock.Success_meta [ ("bookmark", Packstream.String "b1") ];
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      let attempts = ref 0 in
      let work = run_work session attempts in
      (match Session.execute session ~mode:Config.Read work with
      | Ok () -> ()
      | Error _ -> fail "expected Ok");
      check int "one attempt" 1 !attempts;
      check (list string) "bookmarks" [ "b1" ] (Session.last_bookmarks session);
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x2F; 0x12 ]
        (message_tags received))

(* A retryable failure retries the unit of work on a fresh transaction. Each
   attempt uses its own connection (acquired for the transaction's access
   mode): after the failed RUN the failed connection is reset and returned, and
   the retry reconnects. *)
let execute_retries () =
  let received = ref [] in
  Test_mock.with_mock_multi
    [
      (* First attempt: HELLO, LOGON, BEGIN, RUN -> transient failure, then
         the rollback's RESET. *)
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Failure ("Neo.TransientError.General.DatabaseUnavailable", "transient");
          Test_mock.Success;
        ] );
      (* Second attempt on a fresh connection: HELLO, LOGON, BEGIN, RUN, PULL,
         COMMIT. *)
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Records ([], false);
          Test_mock.Success_meta [ ("bookmark", Packstream.String "b2") ];
        ] );
    ]
    (fun net clock sw port ->
      let session = session net clock sw port in
      let attempts = ref 0 in
      let work = run_work session attempts in
      (match Session.execute session ~mode:Config.Read work with
      | Ok () -> ()
      | Error _ -> fail "expected Ok after retry");
      check int "two attempts" 2 !attempts;
      check (list string) "bookmarks" [ "b2" ] (Session.last_bookmarks session);
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x0F; 0x01; 0x6A; 0x11; 0x10; 0x2F; 0x12 ]
        (message_tags received))

(* A non-retryable failure is not retried and surfaces the driver error. *)
let execute_no_retry () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure ("Neo.ClientError.Statement.SyntaxError", "bad");
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      let attempts = ref 0 in
      let work = run_work session attempts in
      (match Session.execute session ~mode:Config.Read work with
      | Ok () -> fail "expected an error"
      | Error (Session.Driver error) -> (
          match error with
          | Errors.Neo4j server ->
              check string "code" "Neo.ClientError.Statement.SyntaxError" server.code
          | _ -> fail "expected a Neo4j error")
      | Error Session.Client -> fail "expected a driver error");
      check int "one attempt" 1 !attempts;
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x11; 0x10; 0x0F ] (message_tags received))

(* An application (client) failure rolls back without retrying. *)
let execute_client_failure () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      let attempts = ref 0 in
      let work _tx =
        incr attempts;
        Error Session.Client
      in
      (match Session.execute session ~mode:Config.Read work with
      | Ok () -> fail "expected a client failure"
      | Error Session.Client -> ()
      | Error (Session.Driver _) -> fail "expected a client failure");
      check int "one attempt" 1 !attempts;
      check (list string) "bookmarks" [] (Session.last_bookmarks session);
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x11; 0x13 ] (message_tags received))

(* Auto-commit run captures the bookmark from the PULL summary. *)
let run_captures_bookmark () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success_meta [ ("bookmark", Packstream.String "auto-b") ];
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      (match Session.run session ~query:"CREATE (n) RETURN 1" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.consume result with
          | Ok _ -> ()
          | Error error -> fail (Errors.to_string error))
      | Error error -> fail (Errors.to_string error));
      check (list string) "bookmarks" [ "auto-b" ] (Session.last_bookmarks session);
      (* consume() discards the rest of the stream instead of pulling it. *)
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x10; 0x2F ] (message_tags received))

(* A negative transaction/query timeout is rejected up front as a configuration
   error, without touching the connection. *)
let negative_timeout () =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let connect ~mode:_ ~database:_ ~bookmarks:_ = fail "connect must not be called" in
      let session = Session.create Session.default_config ~clock ~connect () in
      (match Session.begin_transaction ~timeout:(-1.0) session with
      | Error (Errors.Configuration_error _) -> ()
      | _ -> fail "expected a configuration error");
      match Session.run session ~query:"q" ~parameters:[] ~timeout:(-1.0) with
      | Error (Errors.Configuration_error _) -> ()
      | _ -> fail "expected a configuration error")

(* A session cannot hold two explicit transactions at once. *)
let already_open () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let session = session net clock sw port in
      (match Session.begin_transaction session with
      | Ok _ -> ()
      | Error error -> fail (Errors.to_string error));
      match Session.begin_transaction session with
      | Ok _ -> fail "second begin should fail"
      | Error error -> (
          match error with
          | Errors.Transaction_error message ->
              check string "message" "Explicit transaction already open" message
          | _ -> fail "expected Transaction_error"))

(* The Result cursor pulls records in batches (config fetch_size) and
   fetch/next/peek/values stream the remaining records lazily. *)
let run_fetch_streams () =
  let received = ref [] in
  let session_config = { Session.default_config with fetch_size = Some 2 } in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records
             ([ [ Packstream.Int (Int64.of_int 1) ]; [ Packstream.Int (Int64.of_int 2) ] ], true);
           Test_mock.Records
             ([ [ Packstream.Int (Int64.of_int 3) ]; [ Packstream.Int (Int64.of_int 4) ] ], true);
           Test_mock.Records ([ [ Packstream.Int (Int64.of_int 5) ] ], false);
         ] ))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, None)
        | Error error -> Error error
      in
      let session = Session.create session_config ~clock ~connect () in
      let result =
        match Session.run session ~query:"UNWIND [1..5] AS n RETURN n" ~parameters:[] with
        | Ok result -> result
        | Error error -> fail (Errors.to_string error)
      in
      let record_int = function
        | [ Values.Int n ] -> Int64.to_int n
        | _ -> fail "expected a single-Int record"
      in
      (match Neo4jResult.fetch ~n:2 result with
      | Ok records -> check (list int) "fetch ~n:2" [ 1; 2 ] (List.map record_int records)
      | Error error -> fail (Errors.to_string error));
      (match Neo4jResult.next result with
      | Ok (Some record) -> check int "next" 3 (record_int record)
      | _ -> fail "expected the next record");
      (match Neo4jResult.peek result with
      | Ok (Some record) -> check int "peek" 4 (record_int record)
      | _ -> fail "expected a peeked record");
      (match Neo4jResult.next result with
      | Ok (Some record) -> check int "next after peek" 4 (record_int record)
      | _ -> fail "expected the peeked record");
      (match Neo4jResult.fetch result with
      | Ok records -> check (list int) "fetch remaining" [ 5 ] (List.map record_int records)
      | Error error -> fail (Errors.to_string error));
      (match Neo4jResult.next result with Ok None -> () | _ -> fail "expected end of stream");
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x10; 0x3F; 0x3F; 0x3F ]
        (message_tags received);
      let pull_sizes =
        List.filter_map
          (fun bytes ->
            let tag, fields = unpack_message bytes in
            if tag = 0x3F then
              Some
                (match List.assoc_opt "n" fields with
                | Some (Packstream.Int n) -> Int64.to_int n
                | _ -> 0)
            else None)
          (List.rev !received)
      in
      check (list int) "pull batch sizes" [ 2; 2; 2 ] pull_sizes)

(* The effective database the connect callback reports is used for the
   auto-commit RUN: a default-database session whose connection resolves the
   home database sends it in the RUN extra. *)
let run_uses_effective_database () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ((5, 4), received, [ Test_mock.Success; Test_mock.Success; Test_mock.Records ([], false) ]))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, Some "homedb")
        | Error error -> Error error
      in
      let session = Session.create Session.default_config ~clock ~connect () in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> ()
      | Error error -> fail (Errors.to_string error));
      Session.close session;
      let run_extra =
        List.rev !received
        |> List.find_map (fun bytes ->
            match Packstream.unpack bytes with
            | Ok
                (Packstream.Structure
                   (0x10, [ Packstream.String _; Packstream.Map _; Packstream.Map extra ])) ->
                Some extra
            | _ -> None)
      in
      check string "db in the RUN extra" "homedb"
        (match run_extra with
        | Some extra -> (
            match List.assoc_opt "db" extra with Some (Packstream.String db) -> db | _ -> "")
        | None -> fail "expected a RUN message"))

let tests =
  [
    ("[Session] execute_ok", [ test_case "commit + bookmark" `Quick execute_ok ]);
    ("[Session] execute_retries", [ test_case "retry on transient" `Quick execute_retries ]);
    ("[Session] execute_no_retry", [ test_case "no retry on client error" `Quick execute_no_retry ]);
    ( "[Session] execute_client_failure",
      [ test_case "rollback client failure" `Quick execute_client_failure ] );
    ("[Session] run_captures_bookmark", [ test_case "auto-commit run" `Quick run_captures_bookmark ]);
    ( "[Session] run_uses_effective_database",
      [ test_case "resolved home db in RUN" `Quick run_uses_effective_database ] );
    ("[Session] run_fetch_streams", [ test_case "batched fetch stream" `Quick run_fetch_streams ]);
    ("[Session] already_open", [ test_case "explicit tx guard" `Quick already_open ]);
    ("[Session] negative_timeout", [ test_case "negative tx/query timeout" `Quick negative_timeout ]);
  ]
