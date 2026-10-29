(* Unit tests for Neo4jResult decoding (next_as / decode_all / check_keys / data). *)

open Neodriver
open Neodriver_eio
open Alcotest
module D = Decode

type person = { name : string; age : int }

let person_decoder : person D.t =
  let open D in
  let+ name = field "name" string and+ age = field "age" int in
  { name; age }

let ok = function Ok value -> value | Error error -> fail (Errors.to_string error)
let ok_unit = function Ok () -> () | Error error -> fail (Errors.to_string error)

let config host port =
  Conn.
    {
      host;
      port;
      scheme = Addressing.Bolt;
      connection_timeout = 5.0;
      connection_write_timeout = 30.0;
      user_agent = "test-agent";
      auth = Conn.basic_auth ~credentials:"password" ();
      routing_context = None;
      encryption = Config.Default;
      trusted_certificates = None;
      client_certificate = None;
      client_certificate_provider = None;
      telemetry_disabled = false;
      notifications_min_severity = None;
      notifications_disabled_categories = None;
      keep_alive = true;
    }

let connect net clock sw port =
  match Conn.connect net clock sw (config "127.0.0.1" port) with
  | Ok conn -> conn
  | Error error -> fail (Errors.to_string error)

let session responses =
  Test_mock.Session ((5, 4), ref [], Test_mock.Success :: Test_mock.Success :: responses)

let fields names =
  Test_mock.Success_meta
    [ ("fields", Packstream.List (List.map (fun name -> Packstream.String name) names)) ]

let with_result ?fetch_size responses f =
  Test_mock.with_mock (session responses) (fun net clock sw port ->
      let conn = connect net clock sw port in
      Fun.protect
        ~finally:(fun () -> Conn.close conn)
        (fun () ->
          let hydration = Conn.hydration conn in
          let run_metadata =
            match Conn.run conn ~hydration ~query:"q" ~parameters:[] with
            | Ok metadata -> metadata
            | Error error -> fail (Errors.to_string error)
          in
          let stream = Conn.stream conn ~hydration ~run_metadata in
          let result = Neo4jResult.make ?fetch_size ~query:"q" stream in
          f result))

let streaming () =
  let responses =
    [
      fields [ "name"; "age" ];
      Test_mock.Records ([ [ Packstream.String "Alice"; Packstream.Int 42L ] ], true);
      Test_mock.Records ([ [ Packstream.String "Bob"; Packstream.Int 7L ] ], false);
    ]
  in
  with_result ~fetch_size:1 responses (fun result ->
      check (list string) "keys" [ "name"; "age" ] (Neo4jResult.keys result);
      ok_unit (Neo4jResult.check_keys result person_decoder);
      (match Neo4jResult.next_as result person_decoder with
      | Ok (Some person) ->
          check string "first name" "Alice" person.name;
          check int "first age" 42 person.age
      | Ok None -> fail "expected the first record"
      | Error error -> fail (Errors.to_string error));
      (match Neo4jResult.next_as result person_decoder with
      | Ok (Some person) ->
          check string "second name" "Bob" person.name;
          check int "second age" 7 person.age
      | Ok None -> fail "expected the second record"
      | Error error -> fail (Errors.to_string error));
      (match Neo4jResult.next_as result person_decoder with
      | Ok None -> ()
      | Ok (Some _) -> fail "expected the end of the stream"
      | Error error -> fail (Errors.to_string error));
      ignore (ok (Neo4jResult.consume result)))

let check_keys () =
  let missing = [ fields [ "name" ]; Test_mock.Success ] in
  with_result missing (fun result ->
      (match Neo4jResult.check_keys result person_decoder with
      | Error (Errors.Decode_error message) ->
          check bool "missing field named" true
            (String.starts_with ~prefix:"decoder expects missing field(s): age" message)
      | Ok () -> fail "expected a missing field error"
      | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error));
      ignore (ok (Neo4jResult.consume result)));

  let extra = [ fields [ "name"; "age"; "extra" ]; Test_mock.Success ] in
  with_result extra (fun result ->
      ok_unit (Neo4jResult.check_keys result person_decoder);
      ignore (ok (Neo4jResult.consume result)));

  let duplicate = [ fields [ "name"; "name"; "age" ]; Test_mock.Success ] in
  with_result duplicate (fun result ->
      (match Neo4jResult.check_keys result person_decoder with
      | Error (Errors.Decode_error message) ->
          check bool "duplicate field named" true
            (String.starts_with ~prefix:"result has duplicate field name(s)" message)
      | Ok () -> fail "expected a duplicate field error"
      | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error));
      ignore (ok (Neo4jResult.consume result)))

let decode_error () =
  let responses =
    [
      fields [ "name"; "age" ];
      Test_mock.Records ([ [ Packstream.String "Alice"; Packstream.String "nope" ] ], false);
    ]
  in
  with_result responses (fun result ->
      match Neo4jResult.decode_all result person_decoder with
      | Error (Errors.Decode_error message) ->
          check bool "record number and field path" true
            (String.starts_with ~prefix:"record 1: field \"age\"" message)
      | Ok _ -> fail "expected a decode error"
      | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error))

let next_as_keeps_streaming () =
  let responses =
    [
      fields [ "name" ];
      Test_mock.Records ([ [ Packstream.Int 1L ] ], true);
      Test_mock.Records ([ [ Packstream.String "Alice" ] ], false);
    ]
  in
  with_result ~fetch_size:1 responses (fun result ->
      (match Neo4jResult.next_as result (D.field "name" D.string) with
      | Error (Errors.Decode_error _) -> ()
      | Ok _ -> fail "expected a decode error"
      | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error));
      (match Neo4jResult.next_as result (D.field "name" D.string) with
      | Ok (Some name) -> check string "next record after a bad one" "Alice" name
      | Ok None -> fail "expected the second record"
      | Error error -> fail (Errors.to_string error));
      check bool "end of stream" true
        (ok (Neo4jResult.next_as result (D.field "name" D.string)) = None);
      ignore (ok (Neo4jResult.consume result)))

let deferred_failure () =
  let responses =
    [
      fields [ "name" ];
      Test_mock.Records ([ [ Packstream.String "Alice" ] ], true);
      Test_mock.Failure ("Neo.TransientError.General.DatabaseUnavailable", "boom");
    ]
  in
  with_result responses (fun result ->
      (match Neo4jResult.next_as result (D.field "name" D.string) with
      | Ok (Some name) -> check string "record before failure" "Alice" name
      | Ok None -> fail "expected a record"
      | Error error -> fail (Errors.to_string error));
      match Neo4jResult.next_as result (D.field "name" D.string) with
      | Error _ -> ()
      | Ok _ -> fail "expected the deferred server failure")

let consumed () =
  let responses = [ fields [ "name" ]; Test_mock.Success ] in
  with_result responses (fun result ->
      ignore (ok (Neo4jResult.consume result));
      match Neo4jResult.next_as result person_decoder with
      | Error (Errors.Result_consumed_error _) -> ()
      | Ok _ -> fail "expected a consumed-result error"
      | Error error -> fail ("expected Result_consumed_error, got " ^ Errors.to_string error))

let data_mismatch () =
  let responses = [ fields [ "a"; "b" ]; Test_mock.Records ([ [ Packstream.Int 1L ] ], false) ] in
  with_result responses (fun result ->
      match Neo4jResult.data result with
      | Error (Errors.Broken_record_error _) -> ()
      | Ok _ -> fail "expected a broken record error"
      | Error error -> fail ("expected Broken_record_error, got " ^ Errors.to_string error))

let single_and_optional () =
  let one = [ fields [ "name" ]; Test_mock.Records ([ [ Packstream.String "Alice" ] ], false) ] in
  with_result one (fun result ->
      check string "single" "Alice"
        (ok (Neo4jResult.decode_single result (D.field "name" D.string))));

  let none = [ fields [ "name" ]; Test_mock.Records ([], false) ] in
  with_result none (fun result ->
      check (option string) "single optional empty" None
        (ok (Neo4jResult.decode_single_optional result (D.field "name" D.string)) |> fst))

let eager () =
  let responses =
    [
      fields [ "name"; "age" ];
      Test_mock.Records ([ [ Packstream.String "Alice"; Packstream.Int 42L ] ], false);
    ]
  in
  with_result responses (fun result ->
      let eager = ok (EagerResult.of_result result) in
      ok_unit (EagerResult.check_keys eager person_decoder);
      match EagerResult.decode_all eager person_decoder with
      | Ok [ person ] ->
          check string "eager name" "Alice" person.name;
          check int "eager age" 42 person.age
      | Ok _ -> fail "expected exactly one decoded record"
      | Error error -> fail (Errors.to_string error))

let tests =
  [
    ("[Result] streaming", [ test_case "next_as streams" `Quick streaming ]);
    ("[Result] check_keys", [ test_case "missing/extra/duplicate keys" `Quick check_keys ]);
    ("[Result] decode_error", [ test_case "decode_all record number" `Quick decode_error ]);
    ( "[Result] next_as_error",
      [ test_case "next_as consumes only the bad record" `Quick next_as_keeps_streaming ] );
    ("[Result] deferred_failure", [ test_case "failure after records" `Quick deferred_failure ]);
    ("[Result] consumed", [ test_case "next_as after consume" `Quick consumed ]);
    ("[Result] data", [ test_case "data length mismatch" `Quick data_mismatch ]);
    ("[Result] single", [ test_case "decode single/optional" `Quick single_and_optional ]);
    ("[Result] eager", [ test_case "eager decode_all" `Quick eager ]);
  ]
