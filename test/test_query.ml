(* Unit tests for Conn.run / Conn.pull / Conn.discard using a mock Bolt server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let config host port =
  Conn.
    {
      host;
      port;
      scheme = Addressing.Bolt;
      connection_timeout = 5.0;
      user_agent = "test-agent";
      auth = { scheme = "basic"; principal = "neo4j"; credentials = "password" };
      routing_context = None;
      telemetry_disabled = false;
    }

let connect net clock sw port =
  match Conn.connect net clock sw (config "127.0.0.1" port) with
  | Ok conn -> conn
  | Error error -> fail (Errors.to_string error)

(* A Bolt 5.4 session: HELLO and LOGON succeed, then the given responses. *)
let session received responses =
  Test_mock.Session ((5, 4), received, Test_mock.Success :: Test_mock.Success :: responses)

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) -> (tag, fields)
  | _ -> fail "expected a structure"

let map_of_fields = function
  | [ Packstream.Map map ] -> map
  | [] -> []
  | _ -> fail "expected a single map payload"

let int_of_map map key =
  match List.assoc_opt key map with
  | Some (Packstream.Int value) -> Some (Int64.to_int value)
  | _ -> None

let show_state = function
  | State.Connected -> "Connected"
  | State.Ready -> "Ready"
  | State.Streaming -> "Streaming"
  | State.Tx_ready_or_tx_streaming -> "Tx_ready_or_tx_streaming"
  | State.Failed -> "Failed"
  | State.Authentication -> "Authentication"

let check_state conn expected =
  check string "server state" expected (show_state (Conn.server_state conn))

let record_to_string values = "[" ^ String.concat "," (List.map Values.to_string values) ^ "]"
let records_to_string records = "[" ^ String.concat ";" (List.map record_to_string records) ^ "]"

(* Unwrap a successful PULL outcome (the summary metadata). *)
let summary_of_outcome = function
  | Ok summary -> summary
  | Error error -> fail (Errors.to_string error)

(* run + pull of a single record. *)
let run_pull_single () =
  let responses =
    [
      Test_mock.Success_meta [ ("fields", Packstream.List [ Packstream.String "x" ]) ];
      Test_mock.Records ([ [ Packstream.Int 1L ] ], false);
    ]
  in
  Test_mock.with_mock
    (session (ref []) responses)
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      (match Conn.run conn ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Ok metadata -> check (list string) "fields" [ "x" ] metadata.fields
      | Error error -> fail (Errors.to_string error));
      (match Conn.pull conn ~hydration with
      | Ok (records, outcome) ->
          let summary = summary_of_outcome outcome in
          check string "records" "[[1]]" (records_to_string records);
          check bool "has_more" false (Bolt.metadata_has_more summary);
          check_state conn "Ready"
      | Error error -> fail (Errors.to_string error));
      Conn.close conn)

(* Streaming: PULL with a finite fetch size and has_more between batches. *)
let streaming_has_more () =
  let responses =
    [
      Test_mock.Success_meta [];
      Test_mock.Records ([ [ Packstream.Int 1L ]; [ Packstream.Int 2L ] ], true);
      Test_mock.Records ([ [ Packstream.Int 3L ]; [ Packstream.Int 4L ] ], true);
      Test_mock.Records ([ [ Packstream.Int 5L ] ], false);
    ]
  in
  Test_mock.with_mock
    (session (ref []) responses)
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      (match Conn.run conn ~hydration ~query:"q" ~parameters:[] with
      | Ok _ -> ()
      | Error error -> fail (Errors.to_string error));
      (match Conn.pull conn ~hydration ~n:2 with
      | Ok (records, outcome) ->
          let summary = summary_of_outcome outcome in
          check string "batch1" "[[1];[2]]" (records_to_string records);
          check bool "more1" true (Bolt.metadata_has_more summary);
          check_state conn "Streaming"
      | Error error -> fail (Errors.to_string error));
      (match Conn.pull conn ~hydration ~n:2 with
      | Ok (records, outcome) ->
          let summary = summary_of_outcome outcome in
          check string "batch2" "[[3];[4]]" (records_to_string records);
          check bool "more2" true (Bolt.metadata_has_more summary)
      | Error error -> fail (Errors.to_string error));
      (match Conn.pull conn ~hydration ~n:2 with
      | Ok (records, outcome) ->
          let summary = summary_of_outcome outcome in
          check string "batch3" "[[5]]" (records_to_string records);
          check bool "more3" false (Bolt.metadata_has_more summary);
          check_state conn "Ready"
      | Error error -> fail (Errors.to_string error));
      Conn.close conn)

(* run then discard the remainder. *)
let discard_round_trip () =
  let responses = [ Test_mock.Success_meta []; Test_mock.Success ] in
  Test_mock.with_mock
    (session (ref []) responses)
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      (match Conn.run conn ~hydration ~query:"q" ~parameters:[] with
      | Ok _ -> ()
      | Error error -> fail (Errors.to_string error));
      (match Conn.discard conn with
      | Ok _ -> check_state conn "Ready"
      | Error error -> fail (Errors.to_string error));
      Conn.close conn)

(* PULL with a qid puts it into the extra map on the wire. *)
let qid_in_extra () =
  let received = ref [] in
  let responses =
    [ Test_mock.Success_meta []; Test_mock.Records ([ [ Packstream.Int 1L ] ], false) ]
  in
  Test_mock.with_mock (session received responses) (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      (match Conn.run conn ~hydration ~query:"q" ~parameters:[] with
      | Ok _ -> ()
      | Error error -> fail (Errors.to_string error));
      (match Conn.pull conn ~hydration ~qid:7 with
      | Ok _ -> ()
      | Error error -> fail (Errors.to_string error));
      let tags = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received) in
      check (list int) "sequence" [ 0x01; 0x6A; 0x10; 0x3F ] tags;
      let pull =
        match List.rev !received with
        | _ :: _ :: _ :: pull :: _ -> pull
        | _ -> fail "missing PULL message"
      in
      let _, fields = unpack_message pull in
      let map = map_of_fields fields in
      check (option int) "qid" (Some 7) (int_of_map map "qid");
      check (option int) "n" (Some (-1)) (int_of_map map "n");
      Conn.close conn)

(* A failing RUN enters Failed; the next request auto-resets first. *)
let run_failure_reset () =
  let received = ref [] in
  let responses =
    [
      Test_mock.Failure ("Neo.ClientError.Statement.SyntaxError", "bad query");
      Test_mock.Success;
      Test_mock.Success;
    ]
  in
  Test_mock.with_mock (session received responses) (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      (match Conn.run conn ~hydration ~query:"BAD" ~parameters:[] with
      | Ok _ -> fail "bad query should fail"
      | Error _ -> check_state conn "Failed");
      (match Conn.discard conn with
      | Ok _ -> check_state conn "Ready"
      | Error error -> fail (Errors.to_string error));
      let tags = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received) in
      check (list int) "wire order" [ 0x01; 0x6A; 0x10; 0x0F; 0x2F ] tags;
      Conn.close conn)

let tests =
  [
    ("[Query] run_pull_single", [ test_case "run + single record pull" `Quick run_pull_single ]);
    ( "[Query] streaming_has_more",
      [ test_case "streaming with fetch size" `Quick streaming_has_more ] );
    ("[Query] discard_round_trip", [ test_case "discard the remainder" `Quick discard_round_trip ]);
    ("[Query] qid_in_extra", [ test_case "qid in PULL extra" `Quick qid_in_extra ]);
    ("[Query] run_failure_reset", [ test_case "FAILURE then auto RESET" `Quick run_failure_reset ]);
  ]
