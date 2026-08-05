(* Integration tests for TLS against a live Neo4j instance with a self-signed
   certificate (scripts/integration.sh mounts test/fixtures/neo4j-ssl and enables
   the Bolt SSL policy). These run only when TEST_NEO4J_SCHEME is "bolt+ssc"
   (set by the script's TLS pass); otherwise they are skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_tls_env f =
  match Test_env.of_env () with
  | Some env when env.scheme = "bolt+ssc" -> f env
  | Some _ -> Alcotest.skip ()
  | None -> Alcotest.skip ()

(* bolt+ssc: TLS without certificate validation succeeds. *)
let bolt_ssc () =
  with_tls_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.clock e in
          Eio.Switch.run (fun sw ->
              match Conn.connect net clock sw (Test_env.conn_config env) with
              | Error error -> fail (Errors.to_string error)
              | Ok conn ->
                  check bool "handshake negotiated a supported version" true (conn.major >= 3);
                  Conn.close conn)))

(* bolt+s: the self-signed certificate is rejected against the system trust store. *)
let bolt_s_rejects_self_signed () =
  with_tls_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.clock e in
          Eio.Switch.run (fun sw ->
              let config = Test_env.conn_config ~scheme:Addressing.Bolt_secure env in
              match Conn.connect net clock sw config with
              | Ok _ -> fail "bolt+s should reject the self-signed certificate"
              | Error _ -> ())))

let tests =
  [
    ( "[Integration > TLS] bolt+ssc",
      [ test_case "handshake over TLS (no cert check)" `Quick bolt_ssc ] );
    ( "[Integration > TLS] bolt+s",
      [ test_case "rejects self-signed certificate" `Quick bolt_s_rejects_self_signed ] );
  ]
