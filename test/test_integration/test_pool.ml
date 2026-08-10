(* Integration tests for the connection pool against a live Neo4j instance:
   multiple sessions sharing the pool, connection reuse, a pool-size bound with
   concurrent sessions and pool close. These run only when the TEST_NEO4J_*
   environment variables are set; otherwise they are skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()
let uri_of env = Printf.sprintf "%s://%s:%d" env.Test_env.scheme env.Test_env.host env.Test_env.port
let auth_of env = Conn.basic_auth ~principal:env.Test_env.user ~credentials:env.Test_env.password ()

(* Run [query] on a session and drain it (bulk, discarding records). *)
let run_drain session query =
  match Session.run session ~query ~parameters:[] with
  | Ok result ->
      let stream = Neo4jResult.stream result in
      let rec go () =
        if Conn.has_more stream then
          match Conn.pull_stream stream with Ok _ -> go () | Error e -> fail (Errors.to_string e)
        else match Conn.error stream with Some e -> fail (Errors.to_string e) | None -> ()
      in
      go ()
  | Error e -> fail (Errors.to_string e)

(* Connect a driver for [env] and run [f] on it. *)
let with_driver ?pool_config env f =
  Eio_main.run (fun e ->
      let net = Eio.Stdenv.net e in
      let clock = Eio.Stdenv.mono_clock e in
      Eio.Switch.run (fun sw ->
          match Driver.connect ~uri:(uri_of env) ~auth:(auth_of env) ?pool_config net clock sw with
          | Error error -> fail (Errors.to_string error)
          | Ok driver -> f driver))

(* One driver, two sessions; each borrows a connection and runs a long query
   concurrently on its own fiber. *)
let sessions_share_pool () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let s1 = Driver.session driver in
          let s2 = Driver.session driver in
          let work session = run_drain session "UNWIND RANGE(0, 100000) AS n RETURN n" in
          Eio.Fiber.all [ (fun () -> work s1); (fun () -> work s2) ];
          Session.close s1;
          Session.close s2;
          Driver.close driver))

(* With a pool of one, closing a session returns its connection to the pool and
   the next session reuses it. *)
let connection_reuse () =
  with_env (fun env ->
      let pool_config = { Config.default_pool_config with max_connection_pool_size = 1 } in
      with_driver env ~pool_config (fun driver ->
          let s1 = Driver.session driver in
          run_drain s1 "RETURN 1 AS x";
          Session.close s1;
          let s2 = Driver.session driver in
          run_drain s2 "RETURN 2 AS x";
          Session.close s2;
          Driver.close driver))

(* Two sessions run concurrently on a pool of one: the second waits for the
   first to return its connection and both queries succeed. *)
let pool_size_bound () =
  with_env (fun env ->
      let pool_config = { Config.default_pool_config with max_connection_pool_size = 1 } in
      with_driver env ~pool_config (fun driver ->
          let s1 = Driver.session driver in
          let s2 = Driver.session driver in
          let run session =
            run_drain session "RETURN 1 AS x";
            Session.close session
          in
          Eio.Fiber.all [ (fun () -> run s1); (fun () -> run s2) ];
          Driver.close driver))

(* Driver.close closes the pool's idle connections without error; a session on
   a closed driver fails on first use. *)
let pool_close () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          run_drain session "RETURN 1 AS x";
          Session.close session;
          Driver.close driver;
          let session = Driver.session driver in
          match Session.run session ~query:"RETURN 1 AS x" ~parameters:[] with
          | Error (Errors.Connection_pool_error _) -> ()
          | Error _ -> fail "expected Connection_pool_error"
          | Ok _ -> fail "run on a closed driver should fail"))

let tests =
  [
    ( "[Integration > Pool] sessions share the pool",
      [ test_case "share" `Quick sessions_share_pool ] );
    ("[Integration > Pool] connection reuse", [ test_case "reuse" `Quick connection_reuse ]);
    ("[Integration > Pool] pool size bound", [ test_case "bound" `Quick pool_size_bound ]);
    ("[Integration > Pool] pool close", [ test_case "close" `Quick pool_close ]);
  ]
