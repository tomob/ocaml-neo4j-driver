(* Unit tests for the Log module and the driver's log output on a mock Bolt
   server: connection/handshake/message log lines, credential redaction, the
   env-var parsing and the level/scope wiring. *)

open Neodriver
open Neodriver_eio
open Alcotest

(* Whether [needle] occurs in [haystack]. *)
let contains haystack needle =
  let needle = Bytes.of_string needle in
  let haystack = Bytes.of_string haystack in
  let nlen = Bytes.length needle in
  let hlen = Bytes.length haystack in
  let find_at i = i + nlen <= hlen && Bytes.sub haystack i nlen = needle in
  let rec search i =
    if i > hlen - nlen then false else if find_at i then true else search (i + 1)
  in
  if nlen = 0 then true else search 0

(* --- Alcotest testables --- *)

let log_level_testable =
  Alcotest.testable
    (fun ppf -> function
      | Log.Off -> Format.pp_print_string ppf "off"
      | Log.Error -> Format.pp_print_string ppf "error"
      | Log.Warn -> Format.pp_print_string ppf "warn"
      | Log.Info -> Format.pp_print_string ppf "info"
      | Log.Debug -> Format.pp_print_string ppf "debug")
    ( = )

let log_scope_testable =
  Alcotest.testable
    (fun ppf -> function
      | Log.Io -> Format.pp_print_string ppf "io"
      | Log.Pool -> Format.pp_print_string ppf "pool"
      | Log.Session -> Format.pp_print_string ppf "session"
      | Log.Notifications -> Format.pp_print_string ppf "notifications"
      | Log.Auth -> Format.pp_print_string ppf "auth")
    ( = )

let logs_level_testable =
  Alcotest.testable
    (fun ppf -> function
      | None -> Format.pp_print_string ppf "none"
      | Some Logs.Error -> Format.pp_print_string ppf "error"
      | Some Logs.Warning -> Format.pp_print_string ppf "warning"
      | Some Logs.Info -> Format.pp_print_string ppf "info"
      | Some Logs.Debug -> Format.pp_print_string ppf "debug"
      | Some Logs.App -> Format.pp_print_string ppf "app")
    ( = )

(* --- Capture helpers --- *)

(* Run [f], collecting every Logs message (at Debug on all driver sources) into
   a string. The previous reporter and levels are restored afterwards. *)
let with_capture f =
  (* Prevent the lazy env setup from re-triggering during the capture. *)
  Log.setup ~level:Off ();
  let buffer = Buffer.create 1024 in
  let ppf = Format.formatter_of_buffer buffer in
  let previous_reporter = Logs.reporter () in
  Logs.set_reporter (Logs_fmt.reporter ~dst:ppf ());
  Logs.Src.set_level Log.io (Some Logs.Debug);
  Logs.Src.set_level Log.pool (Some Logs.Debug);
  Logs.Src.set_level Log.session (Some Logs.Debug);
  Logs.Src.set_level Log.notifications (Some Logs.Debug);
  Fun.protect
    ~finally:(fun () ->
      Format.pp_print_flush ppf ();
      Logs.set_reporter previous_reporter;
      Logs.set_level ~all:true None)
    f;
  Buffer.contents buffer

(* Run [f] with only [level] on [src] enabled (all other sources off). *)
let with_capture_level src level f =
  Log.setup ~level:Off ();
  let buffer = Buffer.create 1024 in
  let ppf = Format.formatter_of_buffer buffer in
  let previous_reporter = Logs.reporter () in
  Logs.set_reporter (Logs_fmt.reporter ~dst:ppf ());
  Logs.set_level ~all:true None;
  Logs.Src.set_level src (Some level);
  Fun.protect
    ~finally:(fun () ->
      Format.pp_print_flush ppf ();
      Logs.set_reporter previous_reporter;
      Logs.set_level ~all:true None)
    f;
  Buffer.contents buffer

(* --- Mock scenarios --- *)

let config host port =
  Conn.
    {
      host;
      port;
      scheme = Addressing.Bolt;
      connection_timeout = 5.0;
      user_agent = "test-agent";
      auth = Conn.basic_auth ~credentials:"password" ();
      routing_context = None;
      telemetry_disabled = false;
    }

(* The connection id prefix format. *)
let conn_format () =
  check string "no_conn" "[#0000]" (Log.conn Log.no_conn);
  check string "first" "[#0001]" (Log.conn 1);
  check string "hex" "[#ABCD]" (Log.conn 0xABCD);
  check string "wide" "[#10000]" (Log.conn 0x10000)

(* Credential redaction is recursive and never leaks the secret. *)
let value_masked () =
  let value =
    Packstream.Map
      [
        ("user_agent", Packstream.String "agent");
        ("credentials", Packstream.String "hunter2");
        ( "nested",
          Packstream.Map [ ("credentials", Packstream.String "secret"); ("x", Packstream.Int 1L) ]
        );
      ]
  in
  let rendered = Log.value_masked [ "credentials" ] value in
  check bool "no plaintext" false (contains rendered "hunter2");
  check bool "no nested plaintext" false (contains rendered "secret");
  check bool "masks top-level" true (contains rendered "credentials\": \"*******\"");
  let stars = String.fold_left (fun acc c -> if c = '*' then acc + 1 else acc) 0 rendered in
  check bool "masks nested" true (stars >= 12)

(* Env parsing: levels and scopes. *)
let env_parsing () =
  check (Alcotest.option log_level_testable) "off" (Some Log.Off) (Log.level_of_string "off");
  check (Alcotest.option log_level_testable) "debug" (Some Log.Debug) (Log.level_of_string "debug");
  check (Alcotest.option log_level_testable) "garbage" None (Log.level_of_string "bogus");
  check (Alcotest.option log_scope_testable) "io" (Some Log.Io) (Log.scope_of_string "io");
  check (Alcotest.option log_scope_testable) "auth" (Some Log.Auth) (Log.scope_of_string "auth");
  check (Alcotest.option log_scope_testable) "garbage" None (Log.scope_of_string "bogus");
  let absent_level, absent_scopes = Log.parse_env ~level:None ~scopes:None in
  check log_level_testable "absent level = Off" Log.Off absent_level;
  check (Alcotest.list log_scope_testable) "absent scopes = all" Log.all_scopes absent_scopes;
  let info_level, info_scopes = Log.parse_env ~level:(Some "info") ~scopes:None in
  check log_level_testable "info" Log.Info info_level;
  check (Alcotest.list log_scope_testable) "info scopes all" Log.all_scopes info_scopes;
  let debug_level, debug_scopes = Log.parse_env ~level:(Some "debug") ~scopes:(Some "io,pool") in
  check log_level_testable "debug" Log.Debug debug_level;
  check (Alcotest.list log_scope_testable) "scoped" [ Log.Io; Log.Pool ] debug_scopes;
  let bad_level, bad_scopes = Log.parse_env ~level:(Some "bogus") ~scopes:(Some "io,wat") in
  check log_level_testable "bad level = Off" Log.Off bad_level;
  check (Alcotest.list log_scope_testable) "bad scopes dropped" [ Log.Io ] bad_scopes

(* setup/disable wire the per-src levels. *)
let setup_levels () =
  Log.setup ~level:Debug ~scopes:[ Io; Pool ] ();
  check logs_level_testable "global off" None (Logs.level ());
  check logs_level_testable "io on" (Some Logs.Debug) (Logs.Src.level Log.io);
  check logs_level_testable "pool on" (Some Logs.Debug) (Logs.Src.level Log.pool);
  check logs_level_testable "session off" None (Logs.Src.level Log.session);
  Log.setup ~level:Info ~scopes:Log.all_scopes ();
  (* With [all_scopes] the level is set on every source (global + per-src). *)
  check logs_level_testable "global info" (Some Logs.Info) (Logs.level ());
  check logs_level_testable "session info" (Some Logs.Info) (Logs.Src.level Log.session);
  Log.disable ();
  check logs_level_testable "disabled global" None (Logs.level ());
  check logs_level_testable "disabled io" None (Logs.Src.level Log.io);
  check logs_level_testable "disabled session" None (Logs.Src.level Log.session);
  Log.setup ~level:Off ()

(* Handshake logs (magic, proposal, agreed version). *)
let handshake_logs () =
  let logs =
    with_capture (fun () ->
        Test_mock.with_mock
          (Test_mock.V1 (6, 1))
          (fun net _clock sw port ->
            match Transport.connect net sw (Addressing.IPv4 ("127.0.0.1", port)) with
            | Ok transport -> ignore (Handshake.negotiate transport)
            | Error error -> fail (Errors.to_string error)))
  in
  check bool "open" true (contains logs "C: <OPEN>");
  check bool "magic" true (contains logs "C: <MAGIC> 0x6060B017");
  check bool "proposal" true
    (contains logs "C: <HANDSHAKE> 0x000001FF 0x00080805 0x00020404 0x00000003");
  check bool "agreed" true (contains logs "S: <HANDSHAKE> 0x00000106")

(* HELLO logs redact the credentials. *)
let hello_masked () =
  let logs =
    with_capture (fun () ->
        Test_mock.with_mock
          (Test_mock.Session ((5, 0), ref [], [ Test_mock.Success ]))
          (fun net clock sw port ->
            match Conn.connect net clock sw (config "127.0.0.1" port) with
            | Ok conn -> Conn.close conn
            | Error error -> fail (Errors.to_string error)))
  in
  check bool "hello logged" true (contains logs "C: HELLO");
  check bool "credentials masked" true (contains logs "credentials\": \"*******\"");
  check bool "no plaintext" false (contains logs "password")

(* RUN / PULL logs: the outgoing message and the server's SUCCESS / RECORD
   count (never the record data). *)
let run_pull_logs () =
  let logs =
    with_capture (fun () ->
        Test_mock.with_mock
          (Test_mock.Session
             ( (5, 4),
               ref [],
               [
                 Test_mock.Success;
                 Test_mock.Success;
                 Test_mock.Success_meta [ ("fields", Packstream.List [ Packstream.String "x" ]) ];
                 Test_mock.Records ([ [ Packstream.String "sensitive-value" ] ], false);
               ] ))
          (fun net clock sw port ->
            match Conn.connect net clock sw (config "127.0.0.1" port) with
            | Error error -> fail (Errors.to_string error)
            | Ok conn ->
                let hydration = Conn.hydration conn in
                (match Conn.run conn ~hydration ~query:"RETURN 1" ~parameters:[] with
                | Ok _ -> ()
                | Error error -> fail (Errors.to_string error));
                (match Conn.pull conn ~hydration with
                | Ok (_, Ok _) -> ()
                | Ok (_, Error error) -> fail (Errors.to_string error)
                | Error error -> fail (Errors.to_string error));
                Conn.close conn))
  in
  check bool "run logged" true (contains logs "C: RUN");
  check bool "success logged" true (contains logs "S: SUCCESS");
  check bool "record count" true (contains logs "S: RECORD * 1");
  check bool "no record data" false (contains logs "sensitive-value")

(* Pool logs on acquire / release / close. *)
let pool_logs () =
  let logs =
    with_capture (fun () ->
        Test_mock.with_mock
          (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success ]))
          (fun net clock sw port ->
            let connect _session_auth = Conn.connect net clock sw (config "127.0.0.1" port) in
            let pool = Pool.create ~pool_config:Config.default_pool_config ~connect clock in
            (match Pool.acquire ~session_auth:None ~force_liveness:false pool with
            | Ok conn -> Pool.release pool conn
            | Error error -> fail (Errors.to_string error));
            Pool.close pool))
  in
  check bool "hand out" true (contains logs "<POOL> trying to hand out new connection");
  check bool "released" true (contains logs "<POOL> released");
  check bool "close" true (contains logs "<POOL> close")

(* At Info level the DEBUG lines are filtered out. *)
let level_filtering () =
  let logs =
    with_capture_level Log.io Logs.Info (fun () ->
        Log.debug Log.io (fun m -> m "[#0000]  a debug line");
        Log.info Log.io (fun m -> m "[#0000]  an info line"))
  in
  check bool "info shown" true (contains logs "an info line");
  check bool "debug hidden" false (contains logs "a debug line")

let tests =
  [
    ( "[Log]",
      [
        test_case "conn id format" `Quick conn_format;
        test_case "value_masked redacts credentials" `Quick value_masked;
        test_case "env parsing" `Quick env_parsing;
        test_case "setup/disable levels" `Quick setup_levels;
        test_case "handshake logs" `Quick handshake_logs;
        test_case "HELLO logs mask credentials" `Quick hello_masked;
        test_case "RUN/PULL logs" `Quick run_pull_logs;
        test_case "pool logs" `Quick pool_logs;
        test_case "level filtering" `Quick level_filtering;
      ] );
  ]
