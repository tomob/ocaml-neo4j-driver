(* Integration tests against a live Neo4j instance. These run only when the
   TEST_NEO4J_* environment variables are set; otherwise they are skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()

let config_of_env (env : Test_env.t) =
  Conn.{ host = env.host; port = env.port; scheme = Addressing.Bolt; connection_timeout = 10.0 }

(* Establish a TCP connection and negotiate the Bolt protocol version. *)
let handshake () =
  with_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.clock e in
          Eio.Switch.run (fun sw ->
              match Conn.connect net clock sw (config_of_env env) with
              | Error error -> fail (Errors.to_string error)
              | Ok conn ->
                  check bool "handshake negotiated a supported version" true (conn.major >= 3);
                  Conn.close conn)))

let tests =
  [
    ("[Integration > Handshake] handshake", [ test_case "TCP connect + handshake" `Quick handshake ]);
  ]
