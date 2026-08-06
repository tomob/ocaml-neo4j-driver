(* Integration tests against a live Neo4j instance. These run only when the
   TEST_NEO4J_* environment variables are set; otherwise they are skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()

(* Establish a connection (scheme from the env), authenticate and negotiate the Bolt version. *)
let handshake () =
  with_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.mono_clock e in
          Eio.Switch.run (fun sw ->
              match Conn.connect net clock sw (Test_env.conn_config env) with
              | Error error -> fail (Errors.to_string error)
              | Ok conn ->
                  check bool "handshake negotiated a supported version" true (conn.major >= 3);
                  Conn.close conn)))

(* A wrong password is rejected by the server as a Neo4j error. *)
let auth_failure () =
  with_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.mono_clock e in
          Eio.Switch.run (fun sw ->
              let config = Test_env.conn_config ~password:"wrong-password" env in
              match Conn.connect net clock sw config with
              | Ok conn ->
                  Conn.close conn;
                  fail "wrong password should fail"
              | Error (Errors.Neo4j _) -> ()
              | Error error -> fail (Errors.to_string error))))

let tests =
  [
    ( "[Integration > Handshake] handshake",
      [ test_case "connect + auth + handshake" `Quick handshake ] );
    ( "[Integration > Handshake] auth_failure",
      [ test_case "wrong password rejected" `Quick auth_failure ] );
  ]
