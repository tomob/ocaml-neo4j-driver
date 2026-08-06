(* Unit tests for Conn (no live Neo4j needed). *)

open Neodriver
open Neodriver_eio
open Alcotest

(* Routing schemes (neo4j://) are rejected until routing is implemented. *)
let routing_not_supported () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let config =
            Conn.
              {
                host = "localhost";
                port = 7687;
                scheme = Addressing.Neo4j;
                connection_timeout = 5.0;
              }
          in
          match Conn.connect net clock sw config with
          | Ok _ -> fail "routing should not be supported yet"
          | Error _ -> ()))

(* Conn.connect negotiates the version reported by the mock server. *)
let connect_via_mock () =
  Test_mock.with_mock
    (Test_mock.V1 (5, 0))
    (fun net clock sw port ->
      let config =
        Conn.{ host = "127.0.0.1"; port; scheme = Addressing.Bolt; connection_timeout = 5.0 }
      in
      match Conn.connect net clock sw config with
      | Ok conn ->
          check (pair int int) "conn version" (5, 0) (conn.major, conn.minor);
          Conn.close conn
      | Error error -> fail (Errors.to_string error))

(* Conn.connect maps bolt+ssc to TLS without certificate validation. *)
let connect_via_mock_tls () =
  Test_tls_mock.with_mock
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      let config =
        Conn.
          {
            host = "127.0.0.1";
            port;
            scheme = Addressing.Bolt_self_signed;
            connection_timeout = 5.0;
          }
      in
      match Conn.connect net clock sw config with
      | Ok conn ->
          check (pair int int) "conn tls version" (5, 8) (conn.major, conn.minor);
          Conn.close conn
      | Error error -> fail (Errors.to_string error))

let tests =
  [
    ( "[Conn] routing_not_supported",
      [ test_case "routing scheme rejected" `Quick routing_not_supported ] );
    ("[Conn] connect_via_mock", [ test_case "connect negotiates" `Quick connect_via_mock ]);
    ("[Conn] connect_via_mock_tls", [ test_case "bolt+ssc connects" `Quick connect_via_mock_tls ]);
  ]
