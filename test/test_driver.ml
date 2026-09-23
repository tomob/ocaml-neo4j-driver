(* Unit tests for the user-facing Driver.connect entry point (phase C0). *)

open Neodriver
open Alcotest

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) ->
      (tag, match fields with [ Packstream.Map m ] -> m | _ -> [])
  | _ -> fail "expected a structure"

let message_tags received = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received)

(* An Eio environment without a mock server (the client never connects). *)
let with_env f =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw -> f net clock sw))

let basic_auth_defaults () =
  let a = Conn.basic_auth () in
  check string "scheme" "basic" a.scheme;
  check (option string) "principal" (Some "neo4j") a.principal;
  check (option string) "credentials" (Some "") a.credentials

let basic_auth_overrides () =
  let a = Conn.basic_auth ~principal:"bob" ~credentials:"secret" () in
  check string "scheme" "basic" a.scheme;
  check (option string) "principal" (Some "bob") a.principal;
  check (option string) "credentials" (Some "secret") a.credentials

(* An unparseable URI is rejected by Driver.connect itself. *)
let bad_uri () =
  with_env (fun net clock sw ->
      match Driver.connect ~uri:"garbage" ~auth:(Conn.basic_auth ()) net clock sw with
      | Error (Errors.Configuration_error _) -> ()
      | Ok _ -> fail "expected an error for a bad URI"
      | Error _ -> fail "expected a Configuration_error")

(* neo4j:// is accepted by Driver.connect (no eager rejection); connecting
   happens lazily on first use (here against a closed port, so the first use
   fails with a Service_unavailable). *)
let neo4j_uri_lazy () =
  with_env (fun net clock sw ->
      match Driver.connect ~uri:"neo4j://127.0.0.1:1" ~auth:(Conn.basic_auth ()) net clock sw with
      | Ok driver -> (
          let session = Driver.session driver in
          match Session.run session ~query:"RETURN 1" ~parameters:[] with
          | Error (Errors.Service_unavailable _) -> ()
          | Error _ -> fail "expected a Service_unavailable"
          | Ok _ -> fail "expected a failure on first use")
      | Error _ -> fail "connect should not reject neo4j:// eagerly")

(* An IPv6 literal in the URI is kept as an IPv6 address: the initial address
   handed to the resolver must not be mis-parsed as an IPv4 host. *)
let ipv6_uri () =
  let observed = ref None in
  with_env (fun net clock sw ->
      let resolver address =
        observed := Some address;
        Ok [ Addressing.IPv6 ("::1", 7687, 0, 0) ]
      in
      match
        Driver.connect ~resolver ~uri:"bolt://[::1]:7687" ~auth:(Conn.basic_auth ()) net clock sw
      with
      | Ok driver -> (
          let session = Driver.session driver in
          (match Session.run session ~query:"RETURN 1" ~parameters:[] with
          | Error _ -> ()
          | Ok _ -> fail "expected a connection failure");
          match !observed with
          | Some (Addressing.IPv6 (host, port, _, _)) ->
              check string "host" "::1" host;
              check int "port" 7687 port
          | Some _ -> fail "expected an IPv6 address"
          | None -> fail "resolver was not called")
      | Error e -> fail (Errors.to_string e))

(* Driver.connect wires a lazily connecting session: HELLO + LOGON on first
   use, then RUN/PULL for the query. *)
let connect_and_run () =
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
      let session =
        match
          Driver.connect
            ~uri:("bolt://127.0.0.1:" ^ string_of_int port)
            ~auth:(Conn.basic_auth ()) net clock sw
        with
        | Ok driver -> Driver.session driver
        | Error e -> fail (Errors.to_string e)
      in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok result -> (
          (match Neo4jResult.values result with
          | Ok [ [ Values.Int v ] ] -> check int64 "value" 1L v
          | Ok _ -> fail "expected one record with one value"
          | Error e -> fail (Errors.to_string e));
          match Neo4jResult.consume result with
          | Ok summary -> check int "nodes created" 0 summary.counters.nodes_created
          | Error e -> fail (Errors.to_string e))
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x10; 0x3F ] (message_tags received))

(* The session config (database, bookmarks) flows into the auto-commit RUN
   extra. *)
let custom_config () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Records ([], false) ]
       ))
    (fun net clock sw port ->
      let config =
        {
          Session.default_config with
          database = Some "mydb";
          bookmarks = Bookmarks.of_list [ "bm-1" ];
        }
      in
      let session =
        match
          Driver.connect
            ~uri:("bolt://127.0.0.1:" ^ string_of_int port)
            ~auth:(Conn.basic_auth ()) net clock sw
        with
        | Ok driver -> Driver.session ~config driver
        | Error e -> fail (Errors.to_string e)
      in
      (match Session.run session ~query:"RETURN 1" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.consume result with Ok _ -> () | Error e -> fail (Errors.to_string e))
      | Error e -> fail (Errors.to_string e));
      let messages = List.rev !received in
      let tag, fields =
        match Packstream.unpack (List.nth messages 2) with
        | Ok (Packstream.Structure (tag, fields)) -> (tag, fields)
        | _ -> fail "expected a structure"
      in
      check int "run tag" 0x10 tag;
      match fields with
      | [ _; _; Packstream.Map extra ] ->
          let db =
            match List.assoc_opt "db" extra with Some (Packstream.String s) -> Some s | _ -> None
          in
          let bookmarks =
            match List.assoc_opt "bookmarks" extra with
            | Some (Packstream.List items) ->
                List.map (function Packstream.String b -> b | _ -> "?") items
            | _ -> []
          in
          check (option string) "db" (Some "mydb") db;
          check (list string) "bookmarks" [ "bm-1" ] bookmarks
      | _ -> fail "expected RUN with query, parameters and extra")

(* --- Explicit security config (phase A10/T1) --- *)

let contains text substring =
  let n = String.length text and m = String.length substring in
  let rec go i = i + m <= n && (String.equal (String.sub text i m) substring || go (i + 1)) in
  m = 0 || go 0

(* Driver.is_encrypted resolved from the scheme and the explicit config. The
   driver is lazy, so no connection is made (the URI host is never resolved). *)
let is_encrypted ?encryption ?trusted_certificates ?client_certificate uri =
  with_env (fun net clock sw ->
      match
        Driver.connect ~uri ~auth:(Conn.basic_auth ()) ?encryption ?trusted_certificates
          ?client_certificate net clock sw
      with
      | Ok driver -> Ok (Driver.is_encrypted driver)
      | Error error -> Error error)

let encryption_scheme_defaults () =
  let expect uri expected =
    match is_encrypted uri with
    | Ok actual -> check bool uri expected actual
    | Error error -> fail (Errors.to_string error)
  in
  expect "bolt://localhost:7687" false;
  expect "bolt+s://localhost:7687" true;
  expect "bolt+ssc://localhost:7687" true;
  expect "neo4j://localhost:7687" false;
  expect "neo4j+s://localhost:7687" true;
  expect "neo4j+ssc://localhost:7687" true

let encryption_explicit_config () =
  let expect ?encryption ?trusted_certificates uri expected =
    match is_encrypted ?encryption ?trusted_certificates uri with
    | Ok actual -> check bool uri expected actual
    | Error error -> fail (Errors.to_string error)
  in
  expect ~encryption:Config.Enabled "bolt://localhost:7687" true;
  expect ~encryption:Config.Disabled "bolt://localhost:7687" false;
  expect ~trusted_certificates:Config.Trust_all "bolt://localhost:7687" true;
  expect ~encryption:Config.Enabled ~trusted_certificates:Config.Trust_all "neo4j://localhost:7687"
    true

(* An explicit security config is rejected with a secure scheme (like the Python
   driver), and trust anchors without encryption are rejected too. *)
let encryption_conflicts () =
  let expect_error uri result =
    match result with
    | Error (Errors.Configuration_error message) ->
        let message = String.lowercase_ascii message in
        check bool (uri ^ " mentions encryption") true (contains message "encryption");
        check bool (uri ^ " mentions trust") true (contains message "trust")
    | Error error -> fail (Errors.to_string error)
    | Ok _ -> fail (uri ^ ": expected a Configuration_error")
  in
  expect_error "bolt+s://localhost:7687"
    (is_encrypted ~encryption:Config.Enabled "bolt+s://localhost:7687");
  expect_error "bolt+s://localhost:7687"
    (is_encrypted ~encryption:Config.Disabled "bolt+s://localhost:7687");
  expect_error "neo4j+ssc://localhost:7687"
    (is_encrypted ~encryption:Config.Enabled ~trusted_certificates:Config.Trust_all
       "neo4j+ssc://localhost:7687");
  expect_error "bolt://localhost:7687"
    (is_encrypted ~encryption:Config.Disabled ~trusted_certificates:Config.Trust_all
       "bolt://localhost:7687")

(* The [Custom] trust anchors are every certificate of every configured PEM
   file, concatenated in file order; an unparseable file is a configuration
   error. *)
let custom_trust_anchor_files () =
  let write contents =
    let path = Filename.temp_file "neodriver-trust" ".pem" in
    let oc = open_out_bin path in
    output_string oc contents;
    close_out oc;
    path
  in
  let one = write Test_fixtures.cert in
  let two = write (Test_fixtures.cert ^ Test_fixtures.cert) in
  let invalid = write "not a certificate\n" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [ one; two; invalid ])
    (fun () ->
      let count files =
        match
          Conn.tls_of_config ~host:"thehost" Addressing.Bolt ~encryption:Config.Enabled
            ~trusted_certificates:(Some (Config.Custom files)) ~client_certificate:None
            ~client_certificate_provider:None
        with
        | Ok (Transport.Secure { Tls_client.trust = Tls_client.Custom certificates; _ }) ->
            Ok (List.length certificates)
        | Ok _ -> Error "expected a Custom trust"
        | Error error -> Error (Errors.to_string error)
      in
      (match count [ one ] with Ok n -> check int "one file" 1 n | Error message -> fail message);
      (match count [ one; two ] with
      | Ok n -> check int "two files" 3 n
      | Error message -> fail message);
      match
        Conn.tls_of_config ~host:"thehost" Addressing.Bolt ~encryption:Config.Enabled
          ~trusted_certificates:(Some (Config.Custom [ invalid ])) ~client_certificate:None
          ~client_certificate_provider:None
      with
      | Error (Errors.Certificate_configuration_error _) -> ()
      | Error error -> fail (Errors.to_string error)
      | Ok _ -> fail "an invalid certificate file should be a Certificate_configuration_error")

(* Custom trust anchors are loaded from the configured PEM files (and a missing
   file is a configuration error). *)
let custom_trust_anchors () =
  let path = Filename.temp_file "neodriver-trust" ".pem" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let oc = open_out path in
      output_string oc Test_fixtures.cert;
      close_out oc;
      (match
         is_encrypted ~encryption:Config.Enabled ~trusted_certificates:(Config.Custom [ path ])
           "bolt://localhost:7687"
       with
      | Ok true -> ()
      | Ok false -> fail "custom trust anchors should enable encryption"
      | Error error -> fail (Errors.to_string error));
      match
        is_encrypted ~encryption:Config.Enabled
          ~trusted_certificates:(Config.Custom [ "/nonexistent/neodriver.pem" ])
          "bolt://localhost:7687"
      with
      | Error (Errors.Certificate_configuration_error _) -> ()
      | Error error -> fail (Errors.to_string error)
      | Ok _ -> fail "a missing trust anchor file should be a Certificate_configuration_error")

(* The client certificate (mTLS) is loaded from its PEM files: it requires
   encryption, and encrypted private keys are not supported yet. *)
let client_certificate_config () =
  let write contents suffix =
    let path = Filename.temp_file "neodriver-client" suffix in
    let oc = open_out_bin path in
    output_string oc contents;
    close_out oc;
    path
  in
  let certfile = write Test_fixtures.cert ".pem" in
  let keyfile = write Test_fixtures.key ".pem" in
  let spec ?password certfile keyfile = Config.{ certfile; keyfile; password } in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [ certfile; keyfile ])
    (fun () ->
      (match is_encrypted ~client_certificate:(spec certfile keyfile) "bolt+s://localhost:7687" with
      | Ok true -> ()
      | Ok false -> fail "a client certificate should keep encryption on"
      | Error error -> fail (Errors.to_string error));
      (* requires encryption *)
      (match is_encrypted ~client_certificate:(spec certfile keyfile) "bolt://localhost:7687" with
      | Error (Errors.Configuration_error message) ->
          check bool "mentions encryption" true
            (contains (String.lowercase_ascii message) "encryption")
      | Error error -> fail (Errors.to_string error)
      | Ok _ -> fail "a client certificate without encryption should be rejected");
      (* a password on an unencrypted key is ignored *)
      (match
         is_encrypted
           ~client_certificate:(spec ~password:"secret" certfile keyfile)
           "bolt+s://localhost:7687"
       with
      | Ok true -> ()
      | Ok false -> fail "a password should not disable encryption"
      | Error error -> fail (Errors.to_string error));
      (* a missing file is a configuration error *)
      match
        is_encrypted
          ~client_certificate:(spec "/nonexistent/neodriver-client.pem" keyfile)
          "bolt+s://localhost:7687"
      with
      | Error (Errors.Certificate_configuration_error _) -> ()
      | Error error -> fail (Errors.to_string error)
      | Ok _ -> fail "a missing client certificate should be a Certificate_configuration_error")

let tests =
  [
    ("[Driver] basic_auth defaults", [ test_case "defaults" `Quick basic_auth_defaults ]);
    ("[Driver] basic_auth overrides", [ test_case "overrides" `Quick basic_auth_overrides ]);
    ("[Driver] bad uri", [ test_case "rejected" `Quick bad_uri ]);
    ("[Driver] ipv6 uri", [ test_case "ipv6" `Quick ipv6_uri ]);
    ("[Driver] neo4j:// lazy", [ test_case "lazy reject" `Quick neo4j_uri_lazy ]);
    ("[Driver] connect and run", [ test_case "connect" `Quick connect_and_run ]);
    ("[Driver] custom config", [ test_case "config" `Quick custom_config ]);
    ( "[Driver] encryption scheme defaults",
      [ test_case "scheme selects TLS" `Quick encryption_scheme_defaults ] );
    ( "[Driver] encryption explicit config",
      [ test_case "explicit config overrides the scheme" `Quick encryption_explicit_config ] );
    ( "[Driver] encryption conflicts",
      [ test_case "conflicting config is rejected" `Quick encryption_conflicts ] );
    ( "[Driver] custom trust anchors",
      [ test_case "custom CA files are loaded" `Quick custom_trust_anchors ] );
    ( "[Driver] custom trust anchor files",
      [ test_case "PEM bundles are concatenated" `Quick custom_trust_anchor_files ] );
    ( "[Driver] client certificate",
      [ test_case "mTLS certificate is loaded" `Quick client_certificate_config ] );
  ]
