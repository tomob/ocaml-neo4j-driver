(* Unit tests for Session (auto-commit run and managed transactions with retry)
   on a mock Bolt server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let auth ?(principal = "neo4j") ?(credentials = "password") () =
  Conn.basic_auth ~principal ~credentials ()

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
      encryption = Config.Default;
      trusted_certificates = None;
      client_certificate = None;
      telemetry_disabled = false;
      notifications_min_severity = None;
      notifications_disabled_categories = None;
    }

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) ->
      (tag, match fields with [ Packstream.Map m ] -> m | _ -> [])
  | _ -> fail "expected a structure"

let message_tags received = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received)

(* The [n] of every PULL message, in order. *)
let pull_sizes received =
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

(* The [bookmarks] list of the most recent RUN message. *)
let last_run_bookmarks received =
  let rec find = function
    | [] -> []
    | bytes :: rest -> (
        match Packstream.unpack bytes with
        | Ok (Packstream.Structure (0x10, [ _; _; Packstream.Map extra ])) -> (
            match List.assoc_opt "bookmarks" extra with
            | Some (Packstream.List items) ->
                List.map (function Packstream.String b -> b | _ -> "?") items
            | _ -> [])
        | _ -> find rest)
  in
  find (List.rev !received)

(* A session whose connection connects to the mock server at [port]. *)
let session net clock sw port =
  let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
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
      check (list string) "bookmarks" [ "b1" ] (Bookmarks.to_list (Session.last_bookmarks session));
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x12 ]
        (message_tags received))

(* A retryable failure retries the unit of work on a fresh transaction. Each
   attempt uses its own connection (acquired for the transaction's access
   mode): after the failed RUN the failed connection is reset and returned, and
   the retry reconnects. *)
let execute_retries () =
  let received = ref [] in
  Test_mock.with_mock_multi
    [
      (* First attempt: HELLO, LOGON, BEGIN, RUN -> transient failure, the
         pipelined PULL is drained, then the rollback's RESET. *)
      ( (5, 4),
        received,
        [
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Success;
          Test_mock.Failure ("Neo.TransientError.General.DatabaseUnavailable", "transient");
          Test_mock.Success;
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
      check (list string) "bookmarks" [ "b2" ] (Bookmarks.to_list (Session.last_bookmarks session));
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x0F; 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x12 ]
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
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x0F ]
        (message_tags received))

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
      check (list string) "bookmarks" [] (Bookmarks.to_list (Session.last_bookmarks session));
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
      check (list string) "bookmarks" [ "auto-b" ]
        (Bookmarks.to_list (Session.last_bookmarks session));
      (* consume() discards the rest of the stream instead of pulling it. *)
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x10; 0x3F ] (message_tags received))

(* A negative transaction/query timeout is rejected up front as a configuration
   error, without touching the connection. *)
let negative_timeout () =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ = fail "connect must not be called" in
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
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
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

(* [list] fetches all remaining records with a single PULL n = -1, unlike
   [values]/[next] which pull batch by batch with the fetch size (the TestKit
   ResultListFetchAll optimisation). *)
let run_list_fetches_all_at_once () =
  let received = ref [] in
  let session_config = { Session.default_config with fetch_size = Some 1 } in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records
             ( [
                 [ Packstream.Int (Int64.of_int 1) ];
                 [ Packstream.Int (Int64.of_int 2) ];
                 [ Packstream.Int (Int64.of_int 3) ];
               ],
               false );
         ] ))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, None)
        | Error error -> Error error
      in
      let session = Session.create session_config ~clock ~connect () in
      let result =
        match Session.run session ~query:"RETURN 1" ~parameters:[] with
        | Ok result -> result
        | Error error -> fail (Errors.to_string error)
      in
      let record_int = function
        | [ Values.Int n ] -> Int64.to_int n
        | _ -> fail "expected a single-Int record"
      in
      (match Neo4jResult.list result with
      | Ok records -> check (list int) "list" [ 1; 2; 3 ] (List.map record_int records)
      | Error error -> fail (Errors.to_string error));
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x10; 0x3F ] (message_tags received);
      check (list int) "pull sizes" [ 1 ] (pull_sizes received))

(* [list] keeps records already buffered by a prior [next] and fetches the rest
   at once. *)
let run_list_after_next_fetches_all_at_once () =
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
             ( [
                 [ Packstream.Int (Int64.of_int 3) ];
                 [ Packstream.Int (Int64.of_int 4) ];
                 [ Packstream.Int (Int64.of_int 5) ];
               ],
               false );
         ] ))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, None)
        | Error error -> Error error
      in
      let session = Session.create session_config ~clock ~connect () in
      let result =
        match Session.run session ~query:"RETURN 1" ~parameters:[] with
        | Ok result -> result
        | Error error -> fail (Errors.to_string error)
      in
      let record_int = function
        | [ Values.Int n ] -> Int64.to_int n
        | _ -> fail "expected a single-Int record"
      in
      (match Neo4jResult.next result with
      | Ok (Some record) -> check int "first next" 1 (record_int record)
      | _ -> fail "expected the first record");
      (match Neo4jResult.list result with
      | Ok records -> check (list int) "list" [ 2; 3; 4; 5 ] (List.map record_int records)
      | Error error -> fail (Errors.to_string error));
      check (list int) "pull sizes" [ 2; -1 ] (pull_sizes received))

(* The effective database the connect callback reports is used for the
   auto-commit RUN: a default-database session whose connection resolves the
   home database sends it in the RUN extra. *)
let run_uses_effective_database () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ((5, 4), received, [ Test_mock.Success; Test_mock.Success; Test_mock.Records ([], false) ]))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
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

(* A session with a bookmark manager sends the manager's bookmarks merged with
   its own initial (config) bookmarks, and hands the commit's bookmark back to
   the manager (which supersedes what was sent). *)
let manager_seeds_run_and_updates () =
  let manager = Bookmark_manager.neo4j_bookmark_manager () in
  manager.update_bookmarks ~previous:Bookmarks.empty ~new_bookmarks:(Bookmarks.of_list [ "bm1" ]);
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success_meta [ ("bookmark", Packstream.String "bm2") ];
         ] ))
    (fun net clock sw port ->
      let session_config =
        {
          Session.default_config with
          bookmarks = Bookmarks.of_list [ "unmanaged" ];
          bookmark_manager = Some manager;
        }
      in
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, None)
        | Error error -> Error error
      in
      let session = Session.create session_config ~clock ~connect () in
      (match Session.run session ~query:"CREATE (n) RETURN 1" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.consume result with
          | Ok _ -> ()
          | Error error -> fail (Errors.to_string error))
      | Error error -> fail (Errors.to_string error));
      check (list string) "RUN sends manager ∪ initial" [ "bm1"; "unmanaged" ]
        (last_run_bookmarks received);
      check (list string) "session records its commit bookmark" [ "bm2" ]
        (Bookmarks.to_list (Session.last_bookmarks session));
      check (list string) "manager superseded by the commit bookmark" [ "bm2" ]
        (Bookmarks.to_list (manager.get_bookmarks ())))

(* Two sessions sharing a manager are causally chained: the second session's
   transaction is seeded with the first session's committed bookmark. *)
let manager_chains_across_sessions () =
  let manager = Bookmark_manager.neo4j_bookmark_manager () in
  let first_received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         first_received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success_meta [ ("bookmark", Packstream.String "bm1") ];
         ] ))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, None)
        | Error error -> Error error
      in
      let session =
        Session.create
          { Session.default_config with bookmark_manager = Some manager }
          ~clock ~connect ()
      in
      (match Session.run session ~query:"CREATE (n) RETURN 1" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.consume result with
          | Ok _ -> ()
          | Error error -> fail (Errors.to_string error))
      | Error error -> fail (Errors.to_string error));
      check (list string) "manager holds the first commit" [ "bm1" ]
        (Bookmarks.to_list (manager.get_bookmarks ()));
      Session.close session;
      let second_received = ref [] in
      Test_mock.with_mock
        (Test_mock.Session
           ( (5, 4),
             second_received,
             [
               Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Records ([], false);
             ] ))
        (fun net clock sw port ->
          let session =
            Session.create
              { Session.default_config with bookmark_manager = Some manager }
              ~clock
              ~connect:(fun ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ ->
                match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
                | Ok conn -> Ok (conn, None)
                | Error error -> Error error)
              ()
          in
          (match Session.run session ~query:"RETURN 1" ~parameters:[] with
          | Ok result -> (
              match Neo4jResult.consume result with
              | Ok _ -> ()
              | Error error -> fail (Errors.to_string error))
          | Error error -> fail (Errors.to_string error));
          check (list string) "second session seeded by the manager" [ "bm1" ]
            (last_run_bookmarks second_received)))

(* The session-level notification filtering settings go into every RUN and
   BEGIN extra on Bolt >= 5.2 (renamed to [_classifications] from Bolt 5.5);
   [None] omits them. *)
let session_notification_extras () =
  let extra_of received tag =
    match
      List.rev !received
      |> List.find_map (fun bytes ->
          match Packstream.unpack bytes with
          | Ok (Packstream.Structure (t, fields)) when t = tag -> (
              match List.rev fields with Packstream.Map extra :: _ -> Some extra | _ -> None)
          | _ -> None)
    with
    | Some extra -> extra
    | None -> []
  in
  let string_of extra key =
    match List.assoc_opt key extra with Some (Packstream.String s) -> s | _ -> ""
  in
  let cats_of extra key =
    match List.assoc_opt key extra with
    | Some (Packstream.List values) ->
        List.map (function Packstream.String s -> s | _ -> "") values
    | _ -> []
  in
  let connect net clock sw port ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
    match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
    | Ok conn -> Ok (conn, None)
    | Error error -> Error error
  in
  let check_run version min_severity categories severity_key categories_key =
    let received = ref [] in
    Test_mock.with_mock
      (Test_mock.Session
         (version, received, [ Test_mock.Success; Test_mock.Success; Test_mock.Records ([], false) ]))
      (fun net clock sw port ->
        let session_config =
          {
            Session.default_config with
            notifications_min_severity = min_severity;
            notifications_disabled_categories = categories;
          }
        in
        let session =
          Session.create session_config ~clock ~connect:(connect net clock sw port) ()
        in
        (match Session.run session ~query:"RETURN 1" ~parameters:[] with
        | Ok _ -> ()
        | Error error -> fail (Errors.to_string error));
        Session.close session;
        let extra = extra_of received 0x10 in
        check string "RUN min severity"
          (Option.value ~default:"" min_severity)
          (string_of extra severity_key);
        check (list string) "RUN categories"
          (Option.value ~default:[] categories)
          (cats_of extra categories_key))
  in
  let check_begin version min_severity categories severity_key categories_key =
    let received = ref [] in
    Test_mock.with_mock
      (Test_mock.Session
         ( version,
           received,
           [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
      (fun net clock sw port ->
        let session_config =
          {
            Session.default_config with
            notifications_min_severity = min_severity;
            notifications_disabled_categories = categories;
          }
        in
        let session =
          Session.create session_config ~clock ~connect:(connect net clock sw port) ()
        in
        let tx =
          match Session.begin_transaction session with
          | Ok tx -> tx
          | Error error -> fail (Errors.to_string error)
        in
        (match Tx.rollback tx with Ok () -> () | Error error -> fail (Errors.to_string error));
        Session.close session;
        let extra = extra_of received 0x11 in
        check string "BEGIN min severity"
          (Option.value ~default:"" min_severity)
          (string_of extra severity_key);
        check (list string) "BEGIN categories"
          (Option.value ~default:[] categories)
          (cats_of extra categories_key))
  in
  check_run (5, 2) (Some "WARNING") (Some [ "SCHEMA" ]) "notifications_minimum_severity"
    "notifications_disabled_categories";
  check_run (5, 2) None None "notifications_minimum_severity" "notifications_disabled_categories";
  check_begin (5, 2) (Some "WARNING") (Some [ "SCHEMA" ]) "notifications_minimum_severity"
    "notifications_disabled_categories";
  check_run (5, 5) (Some "OFF") (Some [ "SCHEMA" ]) "notifications_minimum_severity"
    "notifications_disabled_classifications"

(* Impersonation is not supported before Bolt 4.4: a session configured with an
   impersonated user errors before the RUN/BEGIN is sent. *)
let impersonation_rejected_before_4_4 () =
  let received = ref [] in
  let session_config = { Session.default_config with impersonated_user = Some "user" } in
  Test_mock.with_mock
    (Test_mock.Session ((4, 3), received, [ Test_mock.Success ]))
    (fun net clock sw port ->
      let connect ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ =
        match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
        | Ok conn -> Ok (conn, None)
        | Error error -> Error error
      in
      let session = Session.create session_config ~clock ~connect () in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Error (Errors.Configuration_error _) -> ()
      | _ -> fail "expected a configuration error");
      match Session.begin_transaction session with
      | Error (Errors.Configuration_error _) -> ()
      | _ -> fail "expected a configuration error")

(* With [pipeline_begin] the managed transaction sends BEGIN with the first RUN
   and PULL (the execute_query BEGIN pipelining) instead of waiting for the
   BEGIN's response first (the stub would otherwise deadlock). *)
let execute_pipelined_begin () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 3),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([], false);
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      let attempts = ref 0 in
      (match
         Session.execute session ~mode:Config.Write ~pipeline_begin:true (run_work session attempts)
       with
      | Ok () -> ()
      | Error (Session.Driver error) -> fail (Errors.to_string error)
      | Error Session.Client -> fail "unexpected client error");
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x12 ]
        (message_tags received))

(* An auto-commit RUN that fails with an idempotent (Bolt 6) server failure is
   retried once on the same connection; the retry does not re-send TELEMETRY
   (none was sent here: the mock HELLO advertises no telemetry). *)
let run_retries_idempotent () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure_idempotent ("Neo.ClientError.MadeUp.Idempotent", "idem");
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.consume result with
          | Ok _ -> ()
          | Error error -> fail (Errors.to_string error))
      | Error error -> fail (Errors.to_string error));
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x10; 0x3F; 0x0F; 0x10; 0x3F ]
        (message_tags received))

(* [disable_auto_commit_retries] turns the idempotent retry off: the failure
   surfaces without a second RUN. *)
let run_disabled_no_idempotent_retry () =
  let received = ref [] in
  let session_config = { Session.default_config with disable_auto_commit_retries = true } in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure_idempotent ("Neo.ClientError.MadeUp.Idempotent", "idem");
           Test_mock.Success;
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let session =
        Session.create session_config ~clock
          ~connect:(fun ~mode:_ ~database:_ ~bookmarks:_ ~auth:_ ->
            match Conn.connect net clock sw (config "127.0.0.1" port Addressing.Bolt) with
            | Ok conn -> Ok (conn, None)
            | Error error -> Error error)
          ()
      in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> fail "query should fail"
      | Error error -> (
          match error with
          | Errors.Neo4j server ->
              check string "code" "Neo.ClientError.MadeUp.Idempotent" server.code
          | _ -> fail "expected a server error"));
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x10; 0x3F; 0x0F ] (message_tags received))

(* A second failure after the idempotent retry surfaces as-is (no further
   retry), whatever its idempotency. *)
let run_second_error_surfaced () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure_idempotent ("Neo.ClientError.MadeUp.Idempotent", "idem");
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure ("Neo.ClientError.MadeUp.Code", "boom");
           Test_mock.Success;
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> fail "query should fail"
      | Error error -> (
          match error with
          | Errors.Neo4j server -> check string "code" "Neo.ClientError.MadeUp.Code" server.code
          | _ -> fail "expected a server error"));
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x10; 0x3F; 0x0F; 0x10; 0x3F; 0x0F ]
        (message_tags received))

(* A managed transaction reports its own TELEMETRY feature code: execute_query
   (backend) passes 3, while execute_read/execute_write keep the default 0. *)
let execute_telemetry_code () =
  let received = ref [] in
  let telemetry_feature bytes =
    match Packstream.unpack bytes with
    | Ok (Packstream.Structure (0x54, [ Packstream.Int n ])) -> Int64.to_int n
    | _ -> fail "expected a TELEMETRY message"
  in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success_meta
             [
               ("server", Packstream.String "Neo4j/5.14.0");
               ("hints", Packstream.Map [ ("telemetry.enabled", Packstream.Bool true) ]);
             ];
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let session = session net clock sw port in
      (match Session.execute session ~mode:Config.Read ~telemetry:3 (fun _tx -> Ok ()) with
      | Ok () -> ()
      | Error (Session.Driver error) -> fail (Errors.to_string error)
      | Error Session.Client -> fail "unexpected client error");
      let messages = List.rev !received in
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x54; 0x11; 0x12 ]
        (List.map (fun b -> fst (unpack_message b)) messages);
      match List.filter (fun b -> fst (unpack_message b) = 0x54) messages with
      | [ telemetry ] -> check int "telemetry feature" 3 (telemetry_feature telemetry)
      | _ -> fail "expected exactly one TELEMETRY message")

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
    ( "[Session] session_notification_extras",
      [ test_case "session notification config in RUN/BEGIN" `Quick session_notification_extras ] );
    ( "[Session] run_list_fetches_all_at_once",
      [ test_case "list pulls all in one PULL" `Quick run_list_fetches_all_at_once ] );
    ( "[Session] run_list_after_next_fetches_all_at_once",
      [ test_case "list after next pulls all" `Quick run_list_after_next_fetches_all_at_once ] );
    ( "[Session] run_retries_idempotent",
      [ test_case "idempotent RUN failure retried once" `Quick run_retries_idempotent ] );
    ( "[Session] run_disabled_no_idempotent_retry",
      [ test_case "disable_auto_commit_retries" `Quick run_disabled_no_idempotent_retry ] );
    ( "[Session] run_second_error_surfaced",
      [ test_case "second failure surfaces" `Quick run_second_error_surfaced ] );
    ( "[Session] execute_telemetry_code",
      [ test_case "managed tx telemetry feature code" `Quick execute_telemetry_code ] );
    ( "[Session] execute_pipelined_begin",
      [ test_case "pipelined BEGIN with the first RUN" `Quick execute_pipelined_begin ] );
    ("[Session] already_open", [ test_case "explicit tx guard" `Quick already_open ]);
    ( "[Session] impersonation_rejected_before_4_4",
      [ test_case "impersonation on Bolt < 4.4" `Quick impersonation_rejected_before_4_4 ] );
    ("[Session] negative_timeout", [ test_case "negative tx/query timeout" `Quick negative_timeout ]);
    ( "[Session] manager_seeds_run_and_updates",
      [ test_case "manager + initial + commit" `Quick manager_seeds_run_and_updates ] );
    ( "[Session] manager_chains_across_sessions",
      [ test_case "shared manager chains sessions" `Quick manager_chains_across_sessions ] );
  ]
