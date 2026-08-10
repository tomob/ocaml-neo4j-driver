(* Integration tests for Session, Tx and Neo4jResult against a live Neo4j
   instance: result streaming, bookmarks (read-your-writes), explicit and
   managed transactions, auto-commit draining and error recovery. These run
   only when the TEST_NEO4J_* environment variables are set; otherwise they are
   skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()
let uri_of env = Printf.sprintf "%s://%s:%d" env.Test_env.scheme env.Test_env.host env.Test_env.port
let auth_of env = Conn.basic_auth ~principal:env.Test_env.user ~credentials:env.Test_env.password ()

(* Connect a driver and run [f] on it (closed afterwards). *)
let with_driver env f =
  Eio_main.run (fun e ->
      let net = Eio.Stdenv.net e in
      let clock = Eio.Stdenv.mono_clock e in
      Eio.Switch.run (fun sw ->
          match Driver.connect ~uri:(uri_of env) ~auth:(auth_of env) net clock sw with
          | Error error -> fail (Errors.to_string error)
          | Ok driver -> Fun.protect ~finally:(fun () -> Driver.close driver) (fun () -> f driver)))

(* A unique node id for this run, so repeated test runs do not collide. *)
let unique_id () = Printf.sprintf "it_%d_%d" (Unix.getpid ()) (Random.bits ())

let run_values session ~query ~parameters =
  match Session.run session ~query ~parameters with
  | Ok result -> (
      match Neo4jResult.values result with Ok rs -> rs | Error e -> fail (Errors.to_string e))
  | Error e -> fail (Errors.to_string e)

(* How many ITest nodes with [id] exist (0 when none). *)
let node_count session id =
  match
    run_values session ~query:"MATCH (n:ITest {id: $id}) RETURN count(n) AS c"
      ~parameters:[ ("id", Values.String id) ]
  with
  | [ [ Values.Int c ] ] -> Int64.to_int c
  | _ -> fail "expected a count"

let record_int = function
  | [ Values.Int n ] -> Int64.to_int n
  | _ -> fail "expected a single-Int record"

(* Streaming a result through Neo4jResult with a small fetch size: next/peek/
   fetch/values cross real PULL batch boundaries. *)
let stream_through_session () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let config = { Session.default_config with fetch_size = Some 2 } in
          let session = Driver.session ~config driver in
          let result =
            match Session.run session ~query:"UNWIND RANGE(0, 6) AS n RETURN n" ~parameters:[] with
            | Ok result -> result
            | Error e -> fail (Errors.to_string e)
          in
          check (list string) "keys" [ "n" ] (Neo4jResult.keys result);
          (match Neo4jResult.next result with
          | Ok (Some r) -> check int "next" 0 (record_int r)
          | _ -> fail "expected record 0");
          (match Neo4jResult.peek result with
          | Ok (Some r) -> check int "peek" 1 (record_int r)
          | _ -> fail "expected peek 1");
          (match Neo4jResult.fetch ~n:1 result with
          | Ok rs -> check (list int) "fetch ~n:1" [ 1 ] (List.map record_int rs)
          | _ -> fail "fetch ~n:1 failed");
          (match Neo4jResult.values result with
          | Ok rs -> check (list int) "values rest" [ 2; 3; 4; 5; 6 ] (List.map record_int rs)
          | _ -> fail "values failed");
          (match Neo4jResult.next result with Ok None -> () | _ -> fail "expected end of stream");
          (* data/keys: a fresh query. *)
          let data_strings records =
            List.map
              (fun map ->
                "["
                ^ String.concat ","
                    (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (Values.to_string v)) map)
                ^ "]")
              records
          in
          let data =
            match Session.run session ~query:"UNWIND [1,2] AS n RETURN n AS n" ~parameters:[] with
            | Ok result -> (
                match Neo4jResult.data result with
                | Ok d -> d
                | Error e -> fail (Errors.to_string e))
            | Error e -> fail (Errors.to_string e)
          in
          check (list string) "data" [ "[n=1]"; "[n=2]" ] (data_strings data);
          (* single / single_optional: a one-record query. *)
          let result =
            match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
            | Ok result -> result
            | Error e -> fail (Errors.to_string e)
          in
          (match Neo4jResult.single_optional result with
          | Ok (Some r) -> check int "single_optional" 1 (record_int r)
          | _ -> fail "expected single_optional 1");
          let result =
            match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
            | Ok result -> result
            | Error e -> fail (Errors.to_string e)
          in
          (match Neo4jResult.single result with
          | Ok r -> check int "single" 1 (record_int r)
          | _ -> fail "expected single 1");
          (* consume: drains and returns the summary. *)
          let result =
            match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
            | Ok result -> result
            | Error e -> fail (Errors.to_string e)
          in
          (match Neo4jResult.consume result with
          | Ok _ -> ()
          | Error e -> fail (Errors.to_string e));
          Session.close session))

(* A write on session A records a bookmark; session B seeded with it sees the
   write (read-your-writes). *)
let bookmark_read_your_writes () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let s1 = Driver.session driver in
          let id = unique_id () in
          (match
             Session.run s1 ~query:"CREATE (n:ITest {id: $id}) RETURN n.id AS id"
               ~parameters:[ ("id", Values.String id) ]
           with
          | Ok result -> (
              match Neo4jResult.consume result with
              | Ok _ -> ()
              | Error e -> fail (Errors.to_string e))
          | Error e -> fail (Errors.to_string e));
          let bookmark =
            match Session.last_bookmarks s1 with
            | [ b ] when b <> "" -> b
            | _ -> fail "expected one non-empty bookmark"
          in
          let s2 =
            Driver.session ~config:{ Session.default_config with bookmarks = [ bookmark ] } driver
          in
          check int "s2 sees the write" 1 (node_count s2 id);
          Session.close s1;
          Session.close s2))

(* An explicit transaction commits its writes and returns a bookmark. *)
let explicit_tx_commit () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let id = unique_id () in
          let hydration =
            match Session.conn session with
            | Ok conn -> Conn.hydration conn
            | Error e -> fail (Errors.to_string e)
          in
          let tx =
            match Session.begin_transaction session with
            | Ok tx -> tx
            | Error e -> fail (Errors.to_string e)
          in
          (match
             Tx.run tx ~hydration ~query:"CREATE (n:ITest {id: $id}) RETURN n"
               ~parameters:[ ("id", Values.String id) ]
           with
          | Ok _ -> ()
          | Error e -> fail (Errors.to_string e));
          (match Tx.commit tx with
          | Ok (Some b) when b <> "" -> ()
          | Ok _ -> fail "expected a bookmark"
          | Error e -> fail (Errors.to_string e));
          check int "visible after commit" 1 (node_count session id);
          Session.close session))

(* An explicit transaction rolled back discards its writes. *)
let explicit_tx_rollback () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let id = unique_id () in
          let hydration =
            match Session.conn session with
            | Ok conn -> Conn.hydration conn
            | Error e -> fail (Errors.to_string e)
          in
          let tx =
            match Session.begin_transaction session with
            | Ok tx -> tx
            | Error e -> fail (Errors.to_string e)
          in
          (match
             Tx.run tx ~hydration ~query:"CREATE (n:ITest {id: $id}) RETURN n"
               ~parameters:[ ("id", Values.String id) ]
           with
          | Ok _ -> ()
          | Error e -> fail (Errors.to_string e));
          (match Tx.rollback tx with Ok () -> () | Error e -> fail (Errors.to_string e));
          check int "not visible after rollback" 0 (node_count session id);
          Session.close session))

(* A managed transaction commits on success and records the bookmark. *)
let managed_execute_commit () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let id = unique_id () in
          let hydration =
            match Session.conn session with
            | Ok conn -> Conn.hydration conn
            | Error e -> fail (Errors.to_string e)
          in
          let work tx =
            match
              Tx.run tx ~hydration ~query:"CREATE (n:ITest {id: $id}) RETURN n"
                ~parameters:[ ("id", Values.String id) ]
            with
            | Ok _ -> Ok ()
            | Error e -> Error (Session.Driver e)
          in
          (match Session.execute session ~mode:Config.Write work with
          | Ok () -> ()
          | Error _ -> fail "expected Ok");
          check int "visible after managed commit" 1 (node_count session id);
          (match Session.last_bookmarks session with
          | [ b ] when b <> "" -> ()
          | _ -> fail "expected a bookmark");
          Session.close session))

(* A client failure in a managed transaction rolls back without retrying. *)
let managed_execute_client_failure () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let id = unique_id () in
          let work tx =
            ignore tx;
            Error Session.Client
          in
          (match Session.execute session ~mode:Config.Write work with
          | Ok () -> fail "expected a client failure"
          | Error Session.Client -> ()
          | Error (Session.Driver _) -> fail "expected a client failure");
          check int "nothing committed" 0 (node_count session id);
          Session.close session))

(* Running a new auto-commit query while a previous result is unconsumed drains
   the previous stream and both queries succeed. *)
let auto_commit_drains_previous () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let first =
            match
              Session.run session ~query:"UNWIND RANGE(0, 10000) AS n RETURN n" ~parameters:[]
            with
            | Ok result -> result
            | Error e -> fail (Errors.to_string e)
          in
          (* The first result is never read; the second run must drain it. *)
          (match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
          | Ok result -> (
              match Neo4jResult.values result with
              | Ok rs -> check (list int) "second query" [ 1 ] (List.map record_int rs)
              | Error e -> fail (Errors.to_string e))
          | Error e -> fail (Errors.to_string e));
          (* The drained result is still fully readable. *)
          (match Neo4jResult.values first with
          | Ok rs -> check int "first result count" 10001 (List.length rs)
          | Error e -> fail (Errors.to_string e));
          Session.close session))

(* A query error surfaces as a Neo4j error; the next query on the same session
   succeeds (the connection is recovered). *)
let error_recovery () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          (match Session.run session ~query:"NOT CYPHER" ~parameters:[] with
          | Ok _ -> fail "bad query should fail"
          | Error (Errors.Neo4j server) ->
              check string "error code" "Neo.ClientError.Statement.SyntaxError" server.code
          | Error _ -> fail "expected a Neo4j error");
          (match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
          | Ok result -> (
              match Neo4jResult.values result with
              | Ok rs -> check (list int) "recovered" [ 1 ] (List.map record_int rs)
              | Error e -> fail (Errors.to_string e))
          | Error e -> fail (Errors.to_string e));
          Session.close session))

let tests =
  [
    ( "[Integration > Session] streaming",
      [ test_case "Neo4jResult over real batches" `Quick stream_through_session ] );
    ( "[Integration > Session] bookmark read-your-writes",
      [ test_case "bookmark" `Quick bookmark_read_your_writes ] );
    ("[Integration > Session] explicit tx commit", [ test_case "commit" `Quick explicit_tx_commit ]);
    ( "[Integration > Session] explicit tx rollback",
      [ test_case "rollback" `Quick explicit_tx_rollback ] );
    ( "[Integration > Session] managed tx commit",
      [ test_case "execute commit" `Quick managed_execute_commit ] );
    ( "[Integration > Session] managed tx client failure",
      [ test_case "execute client failure" `Quick managed_execute_client_failure ] );
    ( "[Integration > Session] auto-commit drains previous",
      [ test_case "drain" `Quick auto_commit_drains_previous ] );
    ("[Integration > Session] error recovery", [ test_case "recovery" `Quick error_recovery ]);
  ]
