(* Unit tests for Session (auto-commit run and managed transactions with retry)
   on a mock Bolt server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let auth ?(principal = "neo4j") ?(credentials = "password") () =
  Conn.{ scheme = "basic"; principal; credentials }

let config host port scheme =
  Conn.{ host; port; scheme; connection_timeout = 5.0; user_agent = "test-agent"; auth = auth () }

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) ->
      (tag, match fields with [ Packstream.Map m ] -> m | _ -> [])
  | _ -> fail "expected a structure"

let message_tags received = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received)

(* A session whose connection connects to the mock server at [port]. *)
let session net clock sw port =
  let connect () = Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) in
  Session.create Session.default_config ~clock ~connect

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
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x12 ]
        (message_tags received))

(* A retryable failure retries the unit of work on a fresh transaction; the
   failed connection is recovered with a RESET before the retry. *)
let execute_retries () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure ("Neo.TransientError.General.DatabaseUnavailable", "transient");
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([], false);
           Test_mock.Success_meta [ ("bookmark", Packstream.String "b2") ];
         ] ))
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
        [ 0x01; 0x6A; 0x11; 0x10; 0x0F; 0x11; 0x10; 0x3F; 0x12 ]
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
      | Ok stream -> (
          match Session.pull stream with Ok _ -> () | Error error -> fail (Errors.to_string error))
      | Error error -> fail (Errors.to_string error));
      check (list string) "bookmarks" [ "auto-b" ] (Session.last_bookmarks session);
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x10; 0x3F ] (message_tags received))

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

let tests =
  [
    ("[Session] execute_ok", [ test_case "commit + bookmark" `Quick execute_ok ]);
    ("[Session] execute_retries", [ test_case "retry on transient" `Quick execute_retries ]);
    ("[Session] execute_no_retry", [ test_case "no retry on client error" `Quick execute_no_retry ]);
    ( "[Session] execute_client_failure",
      [ test_case "rollback client failure" `Quick execute_client_failure ] );
    ("[Session] run_captures_bookmark", [ test_case "auto-commit run" `Quick run_captures_bookmark ]);
    ("[Session] already_open", [ test_case "explicit tx guard" `Quick already_open ]);
  ]
