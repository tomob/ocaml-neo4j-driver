(* Unit tests for explicit transactions (Tx) on a mock Bolt server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let auth ?(principal = "neo4j") ?(credentials = "password") () =
  Conn.{ scheme = "basic"; principal; credentials }

let config host port scheme =
  Conn.{ host; port; scheme; connection_timeout = 5.0; user_agent = "test-agent"; auth = auth () }

let unpack_message bytes =
  match Packstream.unpack bytes with
  | Ok (Packstream.Structure (tag, fields)) ->
      let map = match fields with [ Packstream.Map map ] -> map | _ -> [] in
      (tag, map)
  | _ -> fail "expected a structure"

let message_tags received = List.map (fun bytes -> fst (unpack_message bytes)) (List.rev !received)

let map_value fields key =
  match List.assoc_opt key fields with Some (Packstream.String value) -> value | _ -> ""

let int_value fields key =
  match List.assoc_opt key fields with Some (Packstream.Int value) -> Int64.to_int value | _ -> 0

let list_value fields key =
  match List.assoc_opt key fields with
  | Some (Packstream.List values) ->
      List.fold_right
        (fun v acc -> match v with Packstream.String s -> s :: acc | _ -> acc)
        values []
  | _ -> []

let connect net clock sw port =
  let config = config "127.0.0.1" port Addressing.Bolt in
  match Conn.connect net clock sw config with
  | Ok conn -> conn
  | Error error -> fail (Errors.to_string error)

let begin_tx conn =
  match Tx.begin_transaction conn ~extra:(Conn.build_extra ()) with
  | Ok tx -> tx
  | Error error -> fail (Errors.to_string error)

(* begin -> run -> commit: the wire sequence and the captured bookmark. *)
let commit_round_trip () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([ [ Packstream.Int (Int64.of_int 1) ] ], false);
           Test_mock.Success_meta [ ("bookmark", Packstream.String "bookmark-1") ];
         ] ))
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let tx = begin_tx conn in
      let hydration = Conn.hydration conn in
      let run_metadata, records, _summary =
        match Tx.run tx ~hydration ~query:"RETURN 1" ~parameters:[] with
        | Ok result -> result
        | Error e -> fail (Errors.to_string e)
      in
      check (list string) "run fields" [] run_metadata.fields;
      check int "one record" 1 (List.length records);
      let bookmark = match Tx.commit tx with Ok b -> b | Error e -> fail (Errors.to_string e) in
      check (option string) "commit bookmark" (Some "bookmark-1") bookmark;
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x12 ]
        (message_tags received);
      check bool "committed" true (Tx.closed tx);
      Conn.close conn)

(* begin -> run -> rollback. *)
let rollback_round_trip () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([], false);
           Test_mock.Success;
         ] ))
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let tx = begin_tx conn in
      let hydration = Conn.hydration conn in
      (match Tx.run tx ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> ()
      | Error e -> fail (Errors.to_string e));
      (match Tx.rollback tx with Ok () -> () | Error e -> fail (Errors.to_string e));
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x3F; 0x13 ]
        (message_tags received);
      check bool "closed" true (Tx.closed tx);
      Conn.close conn)

(* BEGIN carries the session's mode, bookmarks and timeout in its extra map. *)
let build_extra_fields () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ((5, 4), received, [ Test_mock.Success; Test_mock.Success; Test_mock.Success ]))
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let extra = Conn.build_extra ~mode:Config.Read ~bookmarks:[ "bookmark-0" ] ~timeout:2.5 () in
      (match Tx.begin_transaction conn ~extra with
      | Ok _ -> ()
      | Error e -> fail (Errors.to_string e));
      let tag, fields = unpack_message (List.hd !received) in
      check int "message tag" 0x11 tag;
      check string "mode" "r" (map_value fields "mode");
      check int "tx_timeout" 2500 (int_value fields "tx_timeout");
      check (list string) "bookmarks" [ "bookmark-0" ] (list_value fields "bookmarks");
      Conn.close conn)

(* A failed RUN breaks the transaction: run/commit fail fast, rollback recovers
   with a RESET, and a new transaction can begin on the same connection. *)
let failure_recovers () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Failure ("Neo.ClientError.Statement.SyntaxError", "bad");
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Success;
           Test_mock.Records ([], false);
           Test_mock.Success_meta [ ("bookmark", Packstream.String "bookmark-2") ];
         ] ))
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      let tx = begin_tx conn in
      (match Tx.run tx ~hydration ~query:"NOT CYPHER" ~parameters:[] with
      | Ok _ -> fail "bad query should fail"
      | Error _ -> check bool "failed" true (Tx.failed tx));
      (match Tx.run tx ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> fail "run on failed tx should fail"
      | Error _ -> ());
      (match Tx.commit tx with Ok _ -> fail "commit on failed tx should fail" | Error _ -> ());
      (match Tx.rollback tx with Ok () -> () | Error e -> fail (Errors.to_string e));
      let tx2 = begin_tx conn in
      (match Tx.run tx2 ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> ()
      | Error e -> fail (Errors.to_string e));
      (match Tx.commit tx2 with
      | Ok b -> check (option string) "bookmark" (Some "bookmark-2") b
      | Error e -> fail (Errors.to_string e));
      check (list int) "wire sequence"
        [ 0x01; 0x6A; 0x11; 0x10; 0x0F; 0x11; 0x10; 0x3F; 0x12 ]
        (message_tags received);
      Conn.close conn)

(* Operations on a committed or rolled-back transaction fail with a driver
   error, without touching the server. *)
let closed_tx_operations () =
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         ref [],
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let hydration = Conn.hydration conn in
      let tx = begin_tx conn in
      (match Tx.rollback tx with Ok () -> () | Error e -> fail (Errors.to_string e));
      (match Tx.run tx ~hydration ~query:"RETURN 1" ~parameters:[] with
      | Ok _ -> fail "run on closed tx should fail"
      | Error _ -> ());
      (match Tx.commit tx with Ok _ -> fail "commit on closed tx should fail" | Error _ -> ());
      (match Tx.rollback tx with Ok _ -> fail "rollback on closed tx should fail" | Error _ -> ());
      Conn.close conn)

(* close on an open transaction sends a ROLLBACK. *)
let close_rolls_back () =
  let received = ref [] in
  Test_mock.with_mock
    (Test_mock.Session
       ( (5, 4),
         received,
         [ Test_mock.Success; Test_mock.Success; Test_mock.Success; Test_mock.Success ] ))
    (fun net clock sw port ->
      let conn = connect net clock sw port in
      let tx = begin_tx conn in
      (match Tx.close tx with Ok () -> () | Error e -> fail (Errors.to_string e));
      check (list int) "wire sequence" [ 0x01; 0x6A; 0x11; 0x13 ] (message_tags received);
      Conn.close conn)

let tests =
  List.map
    (fun (name, speed, fn) -> ("[Tx] " ^ name, [ test_case name speed fn ]))
    [
      ("commit_round_trip", `Quick, commit_round_trip);
      ("rollback_round_trip", `Quick, rollback_round_trip);
      ("build_extra_fields", `Quick, build_extra_fields);
      ("failure_recovers", `Quick, failure_recovers);
      ("closed_tx_operations", `Quick, closed_tx_operations);
      ("close_rolls_back", `Quick, close_rolls_back);
    ]
