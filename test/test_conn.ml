(* Unit tests for Conn (no live Neo4j needed). *)

open Neodriver
open Neodriver_eio
open Alcotest

let auth ?(principal = "neo4j") ?(credentials = "password") () =
  Conn.{ scheme = "basic"; principal; credentials }

let config host port scheme =
  Conn.{ host; port; scheme; connection_timeout = 5.0; user_agent = "test-agent"; auth = auth () }

(* Routing schemes (neo4j://) are rejected until routing is implemented. *)
let routing_not_supported () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let config = config "localhost" 7687 Addressing.Neo4j in
          match Conn.connect net clock sw config with
          | Ok _ -> fail "routing should not be supported yet"
          | Error _ -> ()))

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) ->
      let map =
        match fields with
        | [ Packstream.Map map ] -> map
        | [] -> []
        | _ -> fail "expected a single map payload"
      in
      (tag, map)
  | _ -> fail "expected a structure"

let map_value fields key =
  match List.assoc_opt key fields with Some (Packstream.String value) -> value | _ -> ""

let show_state = function
  | State.Connected -> "Connected"
  | State.Ready -> "Ready"
  | State.Streaming -> "Streaming"
  | State.Tx_ready_or_tx_streaming -> "Tx_ready_or_tx_streaming"
  | State.Failed -> "Failed"
  | State.Authentication -> "Authentication"

let check_state conn expected =
  check string "server state" expected (show_state (Conn.server_state conn))

(* Conn.connect negotiates the version reported by the mock server (inline auth,
   Bolt 5.0). *)
let connect_via_mock () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 0), ref [], [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          check (pair int int) "conn version" (5, 0) (Conn.version conn);
          Conn.close conn
      | Error error -> fail (Errors.to_string error))

(* Conn.connect maps bolt+ssc to TLS without certificate validation. *)
let connect_via_mock_tls () =
  Test_tls_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt_self_signed in
      match Conn.connect net clock sw config with
      | Ok conn ->
          check (pair int int) "conn tls version" (5, 4) (Conn.version conn);
          Conn.close conn
      | Error error -> fail (Errors.to_string error))

(* For Bolt <= 5.0 the credentials go inline in the HELLO message. *)
let hello_inline_auth () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((5, 0), received, [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match List.rev !received with
          | [ hello ] ->
              let tag, fields = unpack_message hello in
              check int "hello tag" 0x01 tag;
              check string "user_agent" config.user_agent (map_value fields "user_agent");
              check string "scheme" "basic" (map_value fields "scheme");
              check string "principal" config.auth.principal (map_value fields "principal");
              check string "credentials" config.auth.credentials (map_value fields "credentials");
              check bool "no bolt_agent" true (not (List.mem_assoc "bolt_agent" fields))
          | _ -> fail "expected a single HELLO message");
          Conn.close conn)

(* For Bolt >= 5.1 the HELLO carries no credentials; a LOGON follows. *)
let hello_logon () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), received, [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match List.rev !received with
          | [ hello; logon ] ->
              let tag, hello_fields = unpack_message hello in
              check int "hello tag" 0x01 tag;
              check string "user_agent" config.user_agent (map_value hello_fields "user_agent");
              check bool "hello has bolt_agent" true (List.mem_assoc "bolt_agent" hello_fields);
              check bool "hello has no scheme" true (not (List.mem_assoc "scheme" hello_fields));
              let tag, logon_fields = unpack_message logon in
              check int "logon tag" 0x6A tag;
              check string "logon scheme" "basic" (map_value logon_fields "scheme");
              check string "logon principal" config.auth.principal
                (map_value logon_fields "principal");
              check string "logon credentials" config.auth.credentials
                (map_value logon_fields "credentials")
          | _ -> fail "expected HELLO followed by LOGON");
          Conn.close conn)

(* A server-side authentication failure is surfaced as a Neo4j error. *)
let hello_failure () =
  Test_mock.with_mock
    (Test_mock.Session
       ((5, 0), ref [], [ Test_mock.Failure ("Neo.ClientError.Security.Unauthorized", "bad creds") ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok _ -> fail "auth failure should fail"
      | Error (Errors.Neo4j server) ->
          check string "code" "Neo.ClientError.Security.Unauthorized" server.code
      | Error error -> fail (Errors.to_string error))

(* LOGOFF / LOGON round trip on a Bolt >= 5.1 connection. *)
let logoff_logon () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.logoff conn with
          | Error error -> fail (Errors.to_string error)
          | Ok () -> (
              match Conn.logon conn (auth ~credentials:"new-password" ()) with
              | Error error -> fail (Errors.to_string error)
              | Ok () ->
                  let tags =
                    List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received)
                  in
                  check (list int) "message sequence" [ 0x01; 0x6A; 0x6B; 0x6A ] tags));
          Conn.close conn)

(* LOGON is rejected for Bolt <= 5.0. *)
let logon_unsupported () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 0), ref [], [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.logoff conn with
          | Ok () -> fail "LOGOFF should be unsupported for Bolt 5.0"
          | Error _ -> ());
          Conn.close conn)

(* The server state is Ready after a successful connect. *)
let connect_ready () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          check_state conn "Ready";
          Conn.close conn)

(* logoff/logon move the server state between Ready and Authentication. *)
let state_logoff_logon () =
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         ref [],
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.logoff conn with
          | Ok () -> (
              check_state conn "Authentication";
              match Conn.logon conn (auth ()) with
              | Ok () -> check_state conn "Ready"
              | Error error -> fail (Errors.to_string error))
          | Error error -> fail (Errors.to_string error));
          Conn.close conn)

(* A FAILURE moves the server to Failed; the next request issues a RESET first
   (the wire order is HELLO, LOGON, LOGON, RESET, LOGOFF). *)
let auto_reset_after_failure () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure ("Neo.ClientError.Security.Unauthorized", "bad");
           Test_mock.Success;
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.logon conn (auth ~credentials:"wrong" ()) with
          | Ok () -> fail "bad re-auth should fail"
          | Error _ -> check_state conn "Failed");
          (match Conn.logoff conn with
          | Error error -> fail (Errors.to_string error)
          | Ok () ->
              let tags = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received) in
              check (list int) "wire sequence" [ 0x01; 0x6A; 0x6A; 0x0F; 0x6B ] tags);
          Conn.close conn)

(* An IGNORED response also moves the server to Failed. *)
let ignored_fails () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success; Test_mock.Ignored ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.logoff conn with
          | Ok () -> fail "IGNORED should fail"
          | Error _ -> check_state conn "Failed");
          Conn.close conn)

(* A reset returns the server to Ready. *)
let reset_round_trip () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.reset conn with
          | Ok () -> check_state conn "Ready"
          | Error error -> fail (Errors.to_string error));
          Conn.close conn)

(* A custom resolver supplies addresses to try; the first (closed) address is
   skipped and the second (the mock server) connects. *)
let connect_with_resolver () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), ref [], [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      Eio.Switch.run (fun sw2 ->
          let listening =
            Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw:sw2 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let closed_port =
            match Eio.Net.listening_addr listening with `Tcp (_, p) -> p | _ -> assert false
          in
          Eio.Resource.close listening;
          let resolver _address =
            Ok [ Addressing.IPv4 ("127.0.0.1", closed_port); Addressing.IPv4 ("127.0.0.1", port) ]
          in
          let config = config "127.0.0.1" port Addressing.Bolt in
          match Conn.connect ~resolver net clock sw config with
          | Error error -> fail (Errors.to_string error)
          | Ok conn ->
              check string "resolved address"
                (Printf.sprintf "127.0.0.1:%d" port)
                (Addressing.to_string (Conn.address conn));
              Conn.close conn))

(* Re-authenticating with the same token is a no-op. *)
let re_auth_same_token () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((5, 4), received, [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.re_auth conn (auth ()) with
          | Ok false -> ()
          | Ok true -> fail "same token should not re-authenticate"
          | Error error -> fail (Errors.to_string error));
          check int "no extra messages" 2 (List.length !received);
          Conn.close conn)

(* A changed token performs LOGOFF + LOGON. *)
let re_auth_changed_token () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match Conn.re_auth conn (auth ~credentials:"new-password" ()) with
          | Ok true -> check_state conn "Ready"
          | Ok false -> fail "changed token should re-authenticate"
          | Error error -> fail (Errors.to_string error));
          let tags = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received) in
          check (list int) "wire order" [ 0x01; 0x6A; 0x6B; 0x6A ] tags;
          Conn.close conn)

(* mark_unauthenticated forces a LOGON on the next re_auth. *)
let re_auth_after_mark () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          Conn.mark_unauthenticated conn;
          (match Conn.re_auth conn (auth ()) with
          | Ok true -> ()
          | Ok false -> fail "should re-authenticate after mark_unauthenticated"
          | Error error -> fail (Errors.to_string error));
          let tags = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received) in
          check (list int) "wire order" [ 0x01; 0x6A; 0x6B; 0x6A ] tags;
          Conn.close conn)

let tests =
  [
    ( "[Conn] routing_not_supported",
      [ test_case "routing scheme rejected" `Quick routing_not_supported ] );
    ("[Conn] connect_via_mock", [ test_case "connect negotiates" `Quick connect_via_mock ]);
    ("[Conn] connect_via_mock_tls", [ test_case "bolt+ssc connects" `Quick connect_via_mock_tls ]);
    ( "[Conn] hello_inline_auth",
      [ test_case "HELLO carries inline auth for 5.0" `Quick hello_inline_auth ] );
    ("[Conn] hello_logon", [ test_case "HELLO + LOGON for 5.1+" `Quick hello_logon ]);
    ("[Conn] hello_failure", [ test_case "auth failure maps to Neo4j error" `Quick hello_failure ]);
    ("[Conn] logoff_logon", [ test_case "LOGOFF/LOGON round trip" `Quick logoff_logon ]);
    ("[Conn] logon_unsupported", [ test_case "LOGON unsupported for 5.0" `Quick logon_unsupported ]);
    ("[Conn] connect_ready", [ test_case "state Ready after connect" `Quick connect_ready ]);
    ( "[Conn] connect_with_resolver",
      [ test_case "custom resolver addresses tried in order" `Quick connect_with_resolver ] );
    ( "[Conn] state_logoff_logon",
      [ test_case "state across logoff/logon" `Quick state_logoff_logon ] );
    ( "[Conn] auto_reset_after_failure",
      [ test_case "FAILURE triggers auto RESET" `Quick auto_reset_after_failure ] );
    ("[Conn] ignored_fails", [ test_case "IGNORED moves to Failed" `Quick ignored_fails ]);
    ("[Conn] reset_round_trip", [ test_case "reset returns to Ready" `Quick reset_round_trip ]);
    ("[Conn] re_auth_same_token", [ test_case "same token is a no-op" `Quick re_auth_same_token ]);
    ( "[Conn] re_auth_changed_token",
      [ test_case "changed token does LOGOFF + LOGON" `Quick re_auth_changed_token ] );
    ( "[Conn] re_auth_after_mark",
      [ test_case "mark_unauthenticated forces LOGON" `Quick re_auth_after_mark ] );
  ]
