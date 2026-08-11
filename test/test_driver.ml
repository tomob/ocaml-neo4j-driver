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
  check string "principal" "neo4j" a.principal;
  check string "credentials" "" a.credentials

let basic_auth_overrides () =
  let a = Conn.basic_auth ~principal:"bob" ~credentials:"secret" () in
  check string "scheme" "basic" a.scheme;
  check string "principal" "bob" a.principal;
  check string "credentials" "secret" a.credentials

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
      let config = { Session.default_config with database = Some "mydb"; bookmarks = [ "bm-1" ] } in
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

let tests =
  [
    ("[Driver] basic_auth defaults", [ test_case "defaults" `Quick basic_auth_defaults ]);
    ("[Driver] basic_auth overrides", [ test_case "overrides" `Quick basic_auth_overrides ]);
    ("[Driver] bad uri", [ test_case "rejected" `Quick bad_uri ]);
    ("[Driver] ipv6 uri", [ test_case "ipv6" `Quick ipv6_uri ]);
    ("[Driver] neo4j:// lazy", [ test_case "lazy reject" `Quick neo4j_uri_lazy ]);
    ("[Driver] connect and run", [ test_case "connect" `Quick connect_and_run ]);
    ("[Driver] custom config", [ test_case "config" `Quick custom_config ]);
  ]
