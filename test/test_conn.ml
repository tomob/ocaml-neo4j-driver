(* Unit tests for Conn (no live Neo4j needed). *)

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

let message_tag bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, _)) -> tag
  | _ -> fail "expected a structure"

let show_state = function
  | State.Connected -> "Connected"
  | State.Ready -> "Ready"
  | State.Streaming -> "Streaming"
  | State.Tx_ready_or_tx_streaming -> "Tx_ready_or_tx_streaming"
  | State.Failed -> "Failed"
  | State.Authentication -> "Authentication"

let check_state conn expected =
  check string "server state" expected (show_state (Conn.server_state conn))

(* ROUTE (Bolt 4.3+): the wire message and the returned routing table. *)
let route_via_mock () =
  let received = ref [] in
  let rt =
    Packstream.Map
      [
        ("ttl", Packstream.Int 300L);
        ( "servers",
          Packstream.List
            [
              Packstream.Map
                [
                  ("addresses", Packstream.List [ Packstream.String "127.0.0.1:7687" ]);
                  ("role", Packstream.String "ROUTE");
                ];
              Packstream.Map
                [
                  ("addresses", Packstream.List [ Packstream.String "127.0.0.1:7687" ]);
                  ("role", Packstream.String "READ");
                ];
              Packstream.Map
                [
                  ("addresses", Packstream.List [ Packstream.String "127.0.0.1:7687" ]);
                  ("role", Packstream.String "WRITE");
                ];
            ] );
      ]
  in
  Test_mock.with_mock
    (Test_mock.Session
       ((5, 0), received, [ Test_mock.Success; Test_mock.Success_meta [ ("rt", rt) ] ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn -> (
          (match Conn.route conn ~routing_context:[ ("policy", "eu") ] ~bookmarks:[ "b1" ] with
          | Error e -> fail (Errors.to_string e)
          | Ok value -> (
              match Routing_table.parse value with
              | Some table ->
                  check int "ttl" 300 (Routing_table.ttl_seconds table);
                  check int "routers" 1 (List.length (Routing_table.routers table));
                  check int "readers" 1 (List.length (Routing_table.readers table));
                  check int "writers" 1 (List.length (Routing_table.writers table))
              | None -> fail "expected a parseable routing table"));
          let tag, fields =
            match Packstream.unpack (List.hd !received) with
            | Ok (Packstream.Structure (tag, fields)) -> (tag, fields)
            | _ -> fail "expected a structure"
          in
          check int "route tag" 0x66 tag;
          match fields with
          | [ Packstream.Map ctx; Packstream.List bm; Packstream.Map extra ] ->
              check string "routing context" "eu" (map_value ctx "policy");
              (match bm with
              | [ Packstream.String b ] -> check string "bookmark" "b1" b
              | _ -> fail "expected one bookmark");
              check string "no db in extra" "" (map_value extra "db")
          | _ -> fail "expected [routing_context; bookmarks; extra] fields")
      | Error e -> fail (Errors.to_string e))

(* The servers list of the routing procedure's record (the same shape as the
   ROUTE message's [rt] servers). *)
let procedure_servers =
  Packstream.List
    [
      Packstream.Map
        [
          ("addresses", Packstream.List [ Packstream.String "127.0.0.1:7687" ]);
          ("role", Packstream.String "ROUTE");
        ];
      Packstream.Map
        [
          ("addresses", Packstream.List [ Packstream.String "127.0.0.1:7687" ]);
          ("role", Packstream.String "READ");
        ];
      Packstream.Map
        [
          ("addresses", Packstream.List [ Packstream.String "127.0.0.1:7687" ]);
          ("role", Packstream.String "WRITE");
        ];
    ]

let procedure_fields_meta =
  [ ("fields", Packstream.List [ Packstream.String "ttl"; Packstream.String "servers" ]) ]

(* The string value of [key] inside a nested map (e.g. the [context] parameter
   of the routing procedure). *)
let nested_map_value fields key inner_key =
  match List.assoc_opt key fields with
  | Some (Packstream.Map inner) -> map_value inner inner_key
  | _ -> ""

(* The RUN message of a procedure route: [query; parameters; extra]. *)
let unpack_run bytes =
  match Packstream.unpack bytes with
  | Ok
      (Packstream.Structure
         (0x10, [ Packstream.String query; Packstream.Map parameters; Packstream.Map extra ])) ->
      (query, parameters, extra)
  | _ -> fail "expected a RUN message"

(* The routing procedure fallback (Bolt 4.0-4.2, default database): RUN/PULL of
   [dbms.routing.getRoutingTable] on the [system] database, the record zipped
   into the [rt] shape. *)
let route_procedure_bolt42 () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (4, 2),
         received,
         [
           Test_mock.Success;
           Test_mock.Success_meta procedure_fields_meta;
           Test_mock.Records ([ [ Packstream.Int 300L; procedure_servers ] ], false);
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          (match Conn.route conn ~routing_context:[ ("policy", "eu") ] ~bookmarks:[ "b1" ] with
          | Error e -> fail (Errors.to_string e)
          | Ok value -> (
              match Routing_table.parse value with
              | Some table ->
                  check int "ttl" 300 (Routing_table.ttl_seconds table);
                  check int "routers" 1 (List.length (Routing_table.routers table));
                  check int "readers" 1 (List.length (Routing_table.readers table));
                  check int "writers" 1 (List.length (Routing_table.writers table))
              | None -> fail "expected a parseable routing table"));
          let tags = List.map message_tag (List.rev !received) in
          check (list int) "wire order" [ 0x01; 0x10; 0x3F ] tags;
          check int "no ROUTE message" 0 (List.length (List.filter (fun tag -> tag = 0x66) tags));
          let query, parameters, extra = unpack_run (List.nth (List.rev !received) 1) in
          check string "procedure query" "CALL dbms.routing.getRoutingTable($context)" query;
          check string "routing context" "eu" (nested_map_value parameters "context" "policy");
          check string "system db" "system" (map_value extra "db");
          check string "read mode" "r" (map_value extra "mode");
          Conn.close conn
      | Error e -> fail (Errors.to_string e))

(* The Bolt 4.0-4.2 procedure with an explicit database: the query takes a
   [$database] parameter. *)
let route_procedure_bolt42_with_db () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (4, 2),
         received,
         [
           Test_mock.Success;
           Test_mock.Success_meta procedure_fields_meta;
           Test_mock.Records ([ [ Packstream.Int 300L; procedure_servers ] ], false);
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          (match Conn.route ~db:"neo4j" conn ~routing_context:[] ~bookmarks:[] with
          | Error e -> fail (Errors.to_string e)
          | Ok _ -> ());
          let query, parameters, extra = unpack_run (List.nth (List.rev !received) 1) in
          check string "procedure query" "CALL dbms.routing.getRoutingTable($context, $database)"
            query;
          check string "database parameter" "neo4j" (map_value parameters "database");
          check string "system db" "system" (map_value extra "db");
          Conn.close conn
      | Error e -> fail (Errors.to_string e))

(* The Bolt 3 procedure: [dbms.cluster.routing.getRoutingTable], a RUN without
   [db] and without [bookmarks]. *)
let route_procedure_bolt3 () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (3, 0),
         received,
         [
           Test_mock.Success;
           Test_mock.Success_meta procedure_fields_meta;
           Test_mock.Records ([ [ Packstream.Int 300L; procedure_servers ] ], false);
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          (match Conn.route conn ~routing_context:[ ("policy", "eu") ] ~bookmarks:[ "b1" ] with
          | Error e -> fail (Errors.to_string e)
          | Ok value -> (
              match Routing_table.parse value with
              | Some table -> check int "ttl" 300 (Routing_table.ttl_seconds table)
              | None -> fail "expected a parseable routing table"));
          let query, parameters, extra = unpack_run (List.nth (List.rev !received) 1) in
          check string "procedure query" "CALL dbms.cluster.routing.getRoutingTable($context)" query;
          check string "routing context" "eu" (nested_map_value parameters "context" "policy");
          check string "no db in extra" "" (map_value extra "db");
          check bool "no bookmarks in extra" true (not (List.mem_assoc "bookmarks" extra));
          check string "read mode" "r" (map_value extra "mode");
          Conn.close conn
      | Error e -> fail (Errors.to_string e))

(* Impersonation is rejected below Bolt 4.3 before anything is sent. *)
let route_procedure_rejects_impersonation () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((4, 2), received, [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          (match Conn.route ~imp_user:"alice" conn ~routing_context:[] ~bookmarks:[] with
          | Ok _ -> fail "imp_user should be rejected below Bolt 4.3"
          | Error (Errors.Configuration_error _) -> ()
          | Error e -> fail (Errors.to_string e));
          check int "only the HELLO on the wire" 1 (List.length !received);
          Conn.close conn
      | Error e -> fail (Errors.to_string e))

(* A database is rejected on Bolt 3 (no multi-db). *)
let route_procedure_rejects_db_on_bolt3 () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((3, 0), received, [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          (match Conn.route ~db:"neo4j" conn ~routing_context:[] ~bookmarks:[] with
          | Ok _ -> fail "a database should be rejected on Bolt 3"
          | Error (Errors.Configuration_error _) -> ()
          | Error e -> fail (Errors.to_string e));
          check int "only the HELLO on the wire" 1 (List.length !received);
          Conn.close conn
      | Error e -> fail (Errors.to_string e))

(* A procedure that returns no records fails with a descriptive error. *)
let route_procedure_empty_records () =
  Test_mock.with_mock
    (Test_mock.Session
       ( (4, 2),
         ref [],
         [
           Test_mock.Success;
           Test_mock.Success_meta procedure_fields_meta;
           Test_mock.Records ([], false);
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Ok conn ->
          (match Conn.route conn ~routing_context:[] ~bookmarks:[] with
          | Ok _ -> fail "empty records should fail"
          | Error (Errors.Service_unavailable message) ->
              check bool "no records message" true
                (String.starts_with ~prefix:"routing procedure returned no records" message)
          | Error e -> fail (Errors.to_string e));
          Conn.close conn
      | Error e -> fail (Errors.to_string e))

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

(* A Bolt 6 FAILURE carries its code under neo4j_code. *)
let failure_gql_code () =
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         ref [],
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure_gql ("Neo.ClientError.Statement.SyntaxError", "bad");
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          let hydration = Conn.hydration conn in
          (match Conn.run conn ~hydration ~query:"BAD" ~parameters:[] with
          | Ok _ -> fail "bad query should fail"
          | Error (Errors.Neo4j server) ->
              check string "code" "Neo.ClientError.Statement.SyntaxError" server.code
          | Error error -> fail (Errors.to_string error));
          Conn.close conn)

(* Conn.run records the database it last ran on. *)
let last_database_recorded () =
  Test_mock.with_mock
    (Test_mock.Session ((5, 0), ref [], [ Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          check bool "no database initially" true (Option.is_none (Conn.last_database conn));
          (match
             Conn.run ~db:"mydb" conn ~hydration:(Conn.hydration conn) ~query:"RETURN 1"
               ~parameters:[]
           with
          | Ok _ ->
              check (option string) "database recorded" (Some "mydb") (Conn.last_database conn)
          | Error error -> fail (Errors.to_string error));
          Conn.close conn)

(* The [routing] field of the HELLO message, if any. *)
let hello_routing fields =
  match List.assoc_opt "routing" fields with Some (Packstream.Map ctx) -> Some ctx | _ -> None

(* A routed driver sends [routing] in HELLO (with the routing context) from
   Bolt 4.1, gated on supports_connection_context; a direct driver
   (routing_context = None) never sends it. *)
let hello_sends_routing_context () =
  let check_gate version expected =
    let received = ref [] in
    Test_mock.with_mock
      (Test_mock.Session (version, received, [ Test_mock.Success ]))
      (fun net clock sw port ->
        let config =
          {
            (config "127.0.0.1" port Addressing.Bolt) with
            routing_context = Some [ ("policy", "eu") ];
          }
        in
        match Conn.connect net clock sw config with
        | Error error -> fail (Errors.to_string error)
        | Ok conn ->
            let _, fields = unpack_message (List.hd !received) in
            (match hello_routing fields with
            | Some ctx -> check string "routing policy" "eu" (map_value ctx "policy")
            | None -> check bool "routing field absent" true (not expected));
            Conn.close conn)
  in
  check_gate (4, 1) true;
  check_gate (4, 4) true;
  check_gate (4, 0) false;
  check_gate (3, 0) false;
  (* A direct driver (routing_context = None) never sends the field. *)
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session ((4, 4), received, [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          let _, fields = unpack_message (List.hd !received) in
          check bool "no routing field for None" true (Option.is_none (hello_routing fields));
          Conn.close conn)

(* The server's [ssr.enabled] hint in HELLO turns on server-side routing. The
   mock answers with a [server] entry too (like a real server), so the hints
   parsing is exercised even when the agent is present. *)
let ssr_enabled_hint () =
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 0),
         ref [],
         [
           Test_mock.Success_meta
             [
               ("server", Packstream.String "Neo4j/5.0.0");
               ("hints", Packstream.Map [ ("ssr.enabled", Packstream.Bool true) ]);
             ];
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          check bool "ssr enabled from hint" true (Conn.ssr_enabled conn);
          Conn.close conn);
  Test_mock.with_mock
    (Test_mock.Session ((5, 0), ref [], [ Test_mock.Success ]))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          check bool "ssr disabled without hint" false (Conn.ssr_enabled conn);
          Conn.close conn)

(* The [rt] routing table of a RUN response is captured in the run metadata. *)
let run_captures_rt () =
  let rt = Packstream.Map [ ("ttl", Packstream.Int 300L); ("servers", Packstream.List []) ] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 0),
         ref [],
         [
           Test_mock.Success;
           Test_mock.Success_meta
             [ ("fields", Packstream.List [ Packstream.String "n" ]); ("rt", rt) ];
         ] ))
    (fun net clock sw port ->
      let config = config "127.0.0.1" port Addressing.Bolt in
      match Conn.connect net clock sw config with
      | Error error -> fail (Errors.to_string error)
      | Ok conn ->
          (match
             Conn.run conn ~hydration:(Conn.hydration conn) ~query:"RETURN 1" ~parameters:[]
           with
          | Error error -> fail (Errors.to_string error)
          | Ok metadata -> (
              match metadata.rt with
              | Some value -> (
                  match Routing_table.parse value with
                  | Some table -> check int "rt ttl" 300 (Routing_table.ttl_seconds table)
                  | None -> fail "expected a parseable rt")
              | None -> fail "expected the rt metadata"));
          Conn.close conn)

let tests =
  [
    ("[Conn] route_via_mock", [ test_case "ROUTE message + routing table" `Quick route_via_mock ]);
    ( "[Conn] route_procedure_bolt42",
      [ test_case "procedure fallback on 4.2" `Quick route_procedure_bolt42 ] );
    ( "[Conn] route_procedure_bolt42_with_db",
      [ test_case "procedure fallback with database" `Quick route_procedure_bolt42_with_db ] );
    ( "[Conn] route_procedure_bolt3",
      [ test_case "procedure fallback on 3.0" `Quick route_procedure_bolt3 ] );
    ( "[Conn] route_procedure_rejects_impersonation",
      [ test_case "imp_user rejected below 4.3" `Quick route_procedure_rejects_impersonation ] );
    ( "[Conn] route_procedure_rejects_db_on_bolt3",
      [ test_case "database rejected on 3.0" `Quick route_procedure_rejects_db_on_bolt3 ] );
    ( "[Conn] route_procedure_empty_records",
      [ test_case "empty procedure result" `Quick route_procedure_empty_records ] );
    ("[Conn] connect_via_mock", [ test_case "connect negotiates" `Quick connect_via_mock ]);
    ("[Conn] connect_via_mock_tls", [ test_case "bolt+ssc connects" `Quick connect_via_mock_tls ]);
    ( "[Conn] hello_inline_auth",
      [ test_case "HELLO carries inline auth for 5.0" `Quick hello_inline_auth ] );
    ("[Conn] hello_logon", [ test_case "HELLO + LOGON for 5.1+" `Quick hello_logon ]);
    ("[Conn] hello_failure", [ test_case "auth failure maps to Neo4j error" `Quick hello_failure ]);
    ( "[Conn] hello_sends_routing_context",
      [ test_case "routing field gated on Bolt 4.1+" `Quick hello_sends_routing_context ] );
    ("[Conn] ssr_enabled_hint", [ test_case "ssr.enabled hint parsed" `Quick ssr_enabled_hint ]);
    ("[Conn] run_captures_rt", [ test_case "rt metadata captured" `Quick run_captures_rt ]);
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
    ("[Conn] failure_gql_code", [ test_case "FAILURE neo4j_code extracted" `Quick failure_gql_code ]);
    ( "[Conn] last_database_recorded",
      [ test_case "run records the database" `Quick last_database_recorded ] );
  ]
