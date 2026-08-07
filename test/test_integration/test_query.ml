(* Integration tests for RUN/PULL/DISCARD against a live Neo4j instance. These
   run only when the TEST_NEO4J_* environment variables are set; otherwise they
   are skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()
let record_to_string values = "[" ^ String.concat "," (List.map Values.to_string values) ^ "]"
let records_to_string records = "[" ^ String.concat ";" (List.map record_to_string records) ^ "]"

(* Connect, run [query], pull everything and close. *)
let run_and_pull ?n env query =
  Eio_main.run (fun e ->
      let net = Eio.Stdenv.net e in
      let clock = Eio.Stdenv.mono_clock e in
      Eio.Switch.run (fun sw ->
          match Conn.connect net clock sw (Test_env.conn_config env) with
          | Error error -> Error error
          | Ok conn ->
              let hydration = Conn.hydration conn in
              let result =
                match Conn.run conn ~hydration ~query ~parameters:[] with
                | Error error -> Error error
                | Ok metadata -> (
                    match Conn.pull conn ~hydration ?n with
                    | Error error -> Error error
                    | Ok (records, outcome) -> (
                        match outcome with
                        | Ok summary -> Ok (metadata, records, Bolt.metadata_has_more summary)
                        | Error error -> Error error))
              in
              Conn.close conn;
              result))

(* A scalar query: one field and one record. *)
let return_1 () =
  with_env (fun env ->
      match run_and_pull env "RETURN 1 AS x" with
      | Error error -> fail (Errors.to_string error)
      | Ok (metadata, records, has_more) -> (
          check (list string) "fields" [ "x" ] metadata.fields;
          check bool "has_more" false has_more;
          match records with
          | [ [ Values.Int value ] ] -> check int64 "value" 1L value
          | _ -> fail (records_to_string records)))

(* Streaming: a finite PULL fetch size, with has_more between batches. *)
let streaming () =
  with_env (fun env ->
      let results =
        Eio_main.run (fun e ->
            let net = Eio.Stdenv.net e in
            let clock = Eio.Stdenv.mono_clock e in
            Eio.Switch.run (fun sw ->
                match Conn.connect net clock sw (Test_env.conn_config env) with
                | Error error -> Error error
                | Ok conn ->
                    let hydration = Conn.hydration conn in
                    let outcome =
                      match
                        Conn.run conn ~hydration ~query:"UNWIND [1,2,3,4,5] AS n RETURN n"
                          ~parameters:[]
                      with
                      | Error error -> Error error
                      | Ok _ -> (
                          match Conn.pull conn ~hydration ~n:2 with
                          | Error error -> Error error
                          | Ok batch1 -> (
                              match Conn.pull conn ~hydration ~n:2 with
                              | Error error -> Error error
                              | Ok batch2 -> (
                                  match Conn.pull conn ~hydration ~n:2 with
                                  | Error error -> Error error
                                  | Ok batch3 -> Ok (batch1, batch2, batch3))))
                    in
                    Conn.close conn;
                    outcome))
      in
      match results with
      | Error error -> fail (Errors.to_string error)
      | Ok (batch1, batch2, batch3) ->
          let show (records, outcome) =
            let summary = match outcome with Ok s -> s | Error e -> fail (Errors.to_string e) in
            (records_to_string records, Bolt.metadata_has_more summary)
          in
          let b1, m1 = show batch1 in
          let b2, m2 = show batch2 in
          let b3, m3 = show batch3 in
          check string "batch1" "[[1];[2]]" b1;
          check bool "more1" true m1;
          check string "batch2" "[[3];[4]]" b2;
          check bool "more2" true m2;
          check string "batch3" "[[5]]" b3;
          check bool "more3" false m3)

(* Discarding the remainder of a large result succeeds and leaves the
   connection ready. *)
let discard () =
  with_env (fun env ->
      Eio_main.run (fun e ->
          let net = Eio.Stdenv.net e in
          let clock = Eio.Stdenv.mono_clock e in
          Eio.Switch.run (fun sw ->
              match Conn.connect net clock sw (Test_env.conn_config env) with
              | Error error -> fail (Errors.to_string error)
              | Ok conn ->
                  let hydration = Conn.hydration conn in
                  (match
                     Conn.run conn ~hydration ~query:"UNWIND range(1, 1000) AS n RETURN n"
                       ~parameters:[]
                   with
                  | Ok _ -> ()
                  | Error error -> fail (Errors.to_string error));
                  (match Conn.discard conn with
                  | Ok () -> check bool "state ready" true (State.ready (Conn.server_state conn))
                  | Error error -> fail (Errors.to_string error));
                  Conn.close conn)))

let tests =
  [
    ("[Integration > Query] return_1", [ test_case "RETURN 1" `Quick return_1 ]);
    ("[Integration > Query] streaming", [ test_case "streaming PULL" `Quick streaming ]);
    ("[Integration > Query] discard", [ test_case "DISCARD remainder" `Quick discard ]);
  ]
