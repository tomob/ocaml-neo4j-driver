(* Unit tests for Conn (no live Neo4j needed for the non-TLS paths). *)

open Neodriver
open Neodriver_eio
open Alcotest

(* bolt+s / bolt+ssc are rejected until TLS is implemented. *)
let tls_error () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
          let config =
            Conn.
              {
                host = "localhost";
                port = 7687;
                scheme = Addressing.Bolt_secure;
                connection_timeout = 5.0;
              }
          in
          match Conn.connect net clock sw config with
          | Ok _ -> fail "TLS should not be supported yet"
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

let tests =
  [
    ("[Conn] tls_error", [ test_case "TLS scheme rejected" `Quick tls_error ]);
    ("[Conn] connect_via_mock", [ test_case "connect negotiates" `Quick connect_via_mock ]);
  ]
