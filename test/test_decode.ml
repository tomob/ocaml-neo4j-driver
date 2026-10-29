(* Unit tests for the typed result decoders (Neodriver.Decode). *)

open Neodriver
open Alcotest
module D = Decode

type person = { name : string; age : int }

let person_decoder : person D.t =
  let open D in
  let+ name = field "name" string and+ age = field "age" int in
  { name; age }

let ok = function Ok value -> value | Error error -> fail (Errors.to_string error)
let ok_unit = function Ok () -> () | Error error -> fail (Errors.to_string error)

let expect_decode_error = function
  | Ok _ -> fail "expected a decode error"
  | Error (Errors.Decode_error _) -> ()
  | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error)

let person_node properties =
  Values.Node { element_id = "1"; legacy_id = Some 1; labels = [ "Person" ]; properties }

let person_properties = [ ("name", Values.String "Alice"); ("age", Values.Int 42L) ]

let primitives () =
  check string "string" "x" (ok (D.decode_value D.string (Values.String "x")));
  check bool "bool" true (ok (D.decode_value D.bool (Values.Bool true)));
  check int64 "int64" 42L (ok (D.decode_value D.int64 (Values.Int 42L)));
  check int "int" 42 (ok (D.decode_value D.int (Values.Int 42L)));
  check (float 0.0) "float" 1.5 (ok (D.decode_value D.float (Values.Float 1.5)));
  check string "bytes" "abc"
    (Bytes.to_string (ok (D.decode_value D.bytes (Values.Bytes (Bytes.of_string "abc")))));
  check string "uuid" "01020304-0506-0708-090a-0b0c0d0e0f12"
    (ok (D.decode_value D.uuid (Values.Uuid "01020304-0506-0708-090a-0b0c0d0e0f12")));

  let date = Option.get (Temporal.Date.of_ymd (2020, 1, 2)) in
  check bool "date" true (Temporal.Date.equal (ok (D.decode_value D.date (Values.Date date))) date);

  let time = Option.get (Temporal.Time.of_hms_ns 3 4 5 6) in
  check bool "time" true (Temporal.Time.equal (ok (D.decode_value D.time (Values.Time time))) time);

  let datetime = Option.get (Temporal.DateTime.of_ymd_hms (2020, 1, 2) (3, 4, 5) 6) in
  check bool "datetime" true
    (Temporal.DateTime.equal (ok (D.decode_value D.datetime (Values.DateTime datetime))) datetime);

  let duration = Temporal.Duration.of_fields ~months:1 ~days:2 ~seconds:3L ~nanoseconds:4 in
  check bool "duration" true
    (Temporal.Duration.equal (ok (D.decode_value D.duration (Values.Duration duration))) duration);

  let point = { Values.srid = 4326; x = 1.5; y = 2.5; z = None } in
  let decoded_point = ok (D.decode_value D.point (Values.Point point)) in
  check int "point srid" 4326 decoded_point.Values.srid;
  check (float 0.0) "point x" 1.5 decoded_point.Values.x;

  let vector = { Values.dtype = Values.I64; data = Bytes.of_string "12345678" } in
  let decoded_vector = ok (D.decode_value D.vector (Values.Vector vector)) in
  check bool "vector dtype" true (decoded_vector.Values.dtype = Values.I64);
  check string "vector data" "12345678" (Bytes.to_string decoded_vector.Values.data)

let strict_types () =
  expect_decode_error (D.decode_value D.string (Values.Int 1L));
  expect_decode_error (D.decode_value D.float (Values.Int 1L));
  expect_decode_error (D.decode_value D.bytes (Values.String "x"));
  expect_decode_error (D.decode_value D.int64 (Values.String "x"))

let int_range () =
  check int "max int" max_int (ok (D.decode_value D.int (Values.Int (Int64.of_int max_int))));
  check int "min int" min_int (ok (D.decode_value D.int (Values.Int (Int64.of_int min_int))));
  expect_decode_error (D.decode_value D.int (Values.Int Int64.max_int));
  expect_decode_error (D.decode_value D.int (Values.Int Int64.min_int))

let null_and_missing () =
  let row = [ ("name", Values.String "Alice"); ("age", Values.Null) ] in
  check (option int) "field + option on Null" None
    (ok (D.decode_row (D.field "age" (D.option D.int)) row));
  check (option int) "field_opt on Null" None (ok (D.decode_row (D.field_opt "age" D.int) row));
  check (option int) "field_opt on missing" None
    (ok (D.decode_row (D.field_opt "missing" D.int) row));
  check int "field_or on Null" 0 (ok (D.decode_row (D.field_or "age" ~default:0 D.int) row));
  check int "field_or on missing" 0 (ok (D.decode_row (D.field_or "missing" ~default:0 D.int) row));
  expect_decode_error (D.decode_row (D.field "age" D.int) row);
  expect_decode_error (D.decode_row (D.field "missing" (D.option D.int)) row);
  check string "plain field" "Alice" (ok (D.decode_row (D.field "name" D.string) row))

let nested_values () =
  let node = person_node person_properties in
  let expected = { name = "Alice"; age = 42 } in
  check bool "node properties" true (ok (D.decode_value person_decoder node) = expected);
  check bool "map properties" true
    (ok (D.decode_value person_decoder (Values.Map person_properties)) = expected);
  let relationship =
    Values.Relationship
      {
        element_id = "r1";
        legacy_id = None;
        rel_type = "KNOWS";
        start = "1";
        end_ = "2";
        start_legacy_id = None;
        end_legacy_id = None;
        properties = person_properties;
      }
  in
  check bool "relationship properties" true
    (ok (D.decode_value person_decoder relationship) = expected);
  let row = [ ("person", node); ("company", Values.String "Acme") ] in
  let decoded =
    ok (D.decode_row (D.both (D.field "person" person_decoder) (D.field "company" D.string)) row)
  in
  check bool "nested node field" true (fst decoded = expected);
  check string "sibling field" "Acme" (snd decoded)

let collections () =
  check (list int) "list" [ 1; 2; 3 ]
    (ok
       (D.decode_value (D.list D.int) (Values.List [ Values.Int 1L; Values.Int 2L; Values.Int 3L ])));
  check (array string) "array" [| "a"; "b" |]
    (ok (D.decode_value (D.array D.string) (Values.List [ Values.String "a"; Values.String "b" ])));
  check
    (list (option int))
    "list of options" [ Some 1; None ]
    (ok (D.decode_value (D.list (D.option D.int)) (Values.List [ Values.Int 1L; Values.Null ])))

let aliases () =
  check (list string) "field aliases" [ "name" ] (D.aliases (D.field "name" D.string));
  check (list string) "nested field aliases only its own key" [ "person" ]
    (D.aliases (D.field "person" person_decoder));
  check (list string) "both unions" [ "a"; "b" ]
    (D.aliases (D.both (D.field "a" D.string) (D.field "b" D.int)));
  check (list string) "map propagates" [ "a" ]
    (D.aliases (D.map String.length (D.field "a" D.string)));
  check (list string) "list contributes no row keys" [] (D.aliases (D.list D.int));
  check (list string) "field_opt is optional" [] (D.aliases (D.field_opt "a" D.string));
  check (list string) "field_or is optional" [] (D.aliases (D.field_or "a" ~default:0 D.int))

let check_keys () =
  let decoder = D.field "name" D.string in
  ok_unit (D.check_keys ~keys:[ "name"; "extra" ] decoder);
  expect_decode_error (D.check_keys ~keys:[ "other" ] decoder);
  expect_decode_error (D.check_keys ~keys:[ "name"; "name" ] decoder);
  ok_unit (D.check_keys ~keys:[] (D.field_opt "name" D.string));
  ok_unit (D.check_keys ~keys:[] (D.field_or "name" ~default:"" D.string))

let row_of_values () =
  let row = ok (D.row_of_values ~keys:[ "a"; "b" ] [ Values.Int 1L; Values.String "x" ]) in
  check (pair string string) "zipped" ("a", "1") ("a", Values.to_string (List.assoc "a" row));
  check bool "zipped b" true (List.assoc_opt "b" row = Some (Values.String "x"));
  match D.row_of_values ~keys:[ "a"; "b" ] [ Values.Int 1L ] with
  | Error (Errors.Broken_record_error _) -> ()
  | Ok _ -> fail "expected a broken record error"
  | Error error -> fail ("expected Broken_record_error, got " ^ Errors.to_string error)

let error_paths () =
  let node = person_node [ ("name", Values.String "Alice") ] in
  match D.decode_row (D.field "person" person_decoder) [ ("person", node) ] with
  | Error (Errors.Decode_error message) ->
      check bool "nested field path" true
        (String.starts_with ~prefix:"field \"person\": missing field \"age\"" message)
  | Ok _ -> fail "expected a decode error"
  | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error)

let broken_and_combinators () =
  let broken = Values.Broken { error = "bad structure"; raw = Packstream.Null } in
  (match D.decode_value D.string broken with
  | Error (Errors.Decode_error message) ->
      check bool "broken message" true
        (String.starts_with ~prefix:"broken value: bad structure" message)
  | Ok _ -> fail "expected a decode error"
  | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error));
  check int "succeed" 7 (ok (D.decode_row (D.succeed 7) []));
  expect_decode_error (D.decode_row (D.fail "nope") []);
  check (option string) "option" (Some "x")
    (ok (D.decode_value (D.option D.string) (Values.String "x")))

let tests =
  [
    ("[Decode] primitives", [ test_case "all primitives" `Quick primitives ]);
    ("[Decode] strict_types", [ test_case "strict value types" `Quick strict_types ]);
    ("[Decode] int_range", [ test_case "int range check" `Quick int_range ]);
    ("[Decode] null/missing", [ test_case "null and missing keys" `Quick null_and_missing ]);
    ("[Decode] nested", [ test_case "node/map/relationship properties" `Quick nested_values ]);
    ("[Decode] collections", [ test_case "list/array/option" `Quick collections ]);
    ("[Decode] aliases", [ test_case "decoder aliases" `Quick aliases ]);
    ("[Decode] check_keys", [ test_case "result key check" `Quick check_keys ]);
    ("[Decode] row_of_values", [ test_case "positional record zip" `Quick row_of_values ]);
    ("[Decode] error_paths", [ test_case "nested error paths" `Quick error_paths ]);
    ("[Decode] broken", [ test_case "broken values and combinators" `Quick broken_and_combinators ]);
  ]
