(* Integration tests for routing: a [neo4j://] URI against the local standalone
   server, whose routing table lists the single server in every role. These run
   only when the TEST_NEO4J_* environment variables are set; otherwise they are
   skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()
let auth_of env = Conn.basic_auth ~principal:env.Test_env.user ~credentials:env.Test_env.password ()

(* A routed driver (neo4j://) reads and writes through the routing table
   (ROUTE fetches the table; the reader/writer addresses are used for the
   queries). *)
let routed_read_write () =
  with_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.mono_clock e in
          Eio.Switch.run (fun sw ->
              let uri = Printf.sprintf "neo4j://%s:%d" env.Test_env.host env.Test_env.port in
              match Driver.connect ~uri ~auth:(auth_of env) net clock sw with
              | Error error -> fail (Errors.to_string error)
              | Ok driver ->
                  let session = Driver.session driver in
                  (match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
                  | Ok result -> (
                      match Neo4jResult.values result with
                      | Ok [ [ Values.Int 1L ] ] -> ()
                      | Ok _ -> fail "expected one record"
                      | Error e -> fail (Errors.to_string e))
                  | Error e -> fail (Errors.to_string e));
                  (* a write exercises the writer role of the routing table *)
                  (match
                     Session.run session ~query:"CREATE (n:RoutingTest) RETURN 1 AS n"
                       ~parameters:[]
                   with
                  | Ok result -> (
                      match Neo4jResult.values result with
                      | Ok [ [ Values.Int 1L ] ] -> ()
                      | Ok _ -> fail "expected one record"
                      | Error e -> fail (Errors.to_string e))
                  | Error e -> fail (Errors.to_string e));
                  Session.close session;
                  Driver.close driver)))

let tests =
  [
    ( "[Integration > Routing] neo4j:// read + write",
      [ test_case "routed driver" `Quick routed_read_write ] );
  ]
