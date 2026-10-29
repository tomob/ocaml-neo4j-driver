(* Tests for the [@@deriving neo4j] and [@@deriving neo4j_params] derivers. *)

open Neodriver_core
open Alcotest

type address = { city : string; country : string option } [@@deriving neo4j, neo4j_params]

type person = {
  name : string; [@neo4j.alias "full_name"]
  age : int;
  nickname : string option; [@neo4j.missing_none]
  address : address option; [@neo4j.nested]
  id : string; [@neo4j.uuid]
  hired_at : Temporal.Date.t option;
  tags : string list;
}
[@@deriving neo4j, neo4j_params]

type team = { members : address list [@neo4j.nested] } [@@deriving neo4j, neo4j_params]
type write = { login : string; secret : string [@neo4j.skip] } [@@deriving neo4j_params]
type combined = { login : string; secret : string [@neo4j.skip] } [@@deriving neo4j, neo4j_params]
type nothing = { ignored : string [@neo4j.skip] } [@@deriving neo4j_params]
type raw = { payload : Values.t } [@@deriving neo4j, neo4j_params]

let ok = function Ok value -> value | Error error -> fail (Errors.to_string error)

let check_value name expected params =
  match List.assoc_opt name params with
  | Some actual when actual = expected -> ()
  | Some actual ->
      fail
        (Printf.sprintf "%s: expected %s, got %s" name (Values.to_string expected)
           (Values.to_string actual))
  | None -> fail ("missing parameter " ^ name)

let date = Option.get (Temporal.Date.of_ymd (2020, 1, 2))
let uuid = "01020304-0506-0708-090a-0b0c0d0e0f12"

let person_map =
  Values.Map
    [
      ("full_name", Values.String "Alice");
      ("age", Values.Int 42L);
      ("address", Values.Map [ ("city", Values.String "Krakow"); ("country", Values.Null) ]);
      ("id", Values.Uuid uuid);
      ("hired_at", Values.Date date);
      ("tags", Values.List [ Values.String "a"; Values.String "b" ]);
    ]

let decode () =
  let person = ok (Decode.decode_value person_decoder person_map) in
  check string "alias" "Alice" person.name;
  check int "int" 42 person.age;
  check (option string) "missing_none with a missing key" None person.nickname;
  check bool "nested option" true
    (match person.address with
    | Some address -> address.city = "Krakow" && address.country = None
    | None -> false);
  check string "uuid" uuid person.id;
  check bool "date" true
    (match person.hired_at with
    | Some hired_at -> Temporal.Date.equal hired_at date
    | None -> false);
  check (list string) "list" [ "a"; "b" ] person.tags;
  check (list string) "required aliases"
    [ "full_name"; "age"; "address"; "id"; "hired_at"; "tags" ]
    person_aliases

let missing_none_null () =
  let map =
    Values.Map
      [
        ("full_name", Values.String "Bob");
        ("age", Values.Int 7L);
        ("nickname", Values.Null);
        ("address", Values.Null);
        ("id", Values.Uuid uuid);
        ("hired_at", Values.Null);
        ("tags", Values.List []);
      ]
  in
  let person = ok (Decode.decode_value person_decoder map) in
  check (option string) "missing_none with Null" None person.nickname;
  check bool "option nested Null" true (person.address = None);
  check bool "option temporal Null" true (person.hired_at = None)

let params () =
  let value =
    {
      name = "Alice";
      age = 42;
      nickname = Some "Al";
      address = Some { city = "Krakow"; country = None };
      id = uuid;
      hired_at = Some date;
      tags = [ "a"; "b" ];
    }
  in
  let parameters = person_params value in
  check int "parameter count" 7 (List.length parameters);
  check_value "full_name" (Values.String "Alice") parameters;
  check_value "age" (Values.Int 42L) parameters;
  check_value "nickname" (Values.String "Al") parameters;
  check_value "address"
    (Values.Map [ ("city", Values.String "Krakow"); ("country", Values.Null) ])
    parameters;
  check_value "id" (Values.Uuid uuid) parameters;
  check_value "hired_at" (Values.Date date) parameters;
  check_value "tags" (Values.List [ Values.String "a"; Values.String "b" ]) parameters

let params_null () =
  let value =
    {
      name = "Bob";
      age = 7;
      nickname = None;
      address = None;
      id = uuid;
      hired_at = None;
      tags = [];
    }
  in
  let parameters = person_params value in
  check_value "nickname" Values.Null parameters;
  check_value "address" Values.Null parameters;
  check_value "hired_at" Values.Null parameters;
  check_value "tags" (Values.List []) parameters

let nested_list () =
  let value =
    { members = [ { city = "Krakow"; country = Some "PL" }; { city = "Berlin"; country = None } ] }
  in
  let parameters = team_params value in
  (match List.assoc_opt "members" parameters with
  | Some
      (Values.List
         [
           Values.Map [ ("city", Values.String "Krakow"); ("country", Values.String "PL") ];
           Values.Map [ ("city", Values.String "Berlin"); ("country", Values.Null) ];
         ]) ->
      ()
  | _ -> fail "unexpected nested list encoding");
  let map = Values.Map [ ("members", List.assoc "members" parameters) ] in
  let decoded = ok (Decode.decode_value team_decoder map) in
  check int "nested list length" 2 (List.length decoded.members);
  check string "nested list city" "Berlin" (List.nth decoded.members 1).city

let skip () =
  let value : write = { login = "alice"; secret = "hunter2" } in
  check string "secret stays in the record" "hunter2" value.secret;
  let parameters = write_params value in
  check int "skipped parameter count" 1 (List.length parameters);
  check_value "login" (Values.String "alice") parameters;
  check bool "secret omitted" false (List.mem_assoc "secret" parameters)

let skip_with_decoder () =
  let value : combined = { login = "alice"; secret = "hunter2" } in
  let parameters = combined_params value in
  check int "skipped parameter count" 1 (List.length parameters);
  check bool "secret omitted from params" false (List.mem_assoc "secret" parameters);
  let decoded =
    ok
      (Decode.decode_value combined_decoder
         (Values.Map [ ("login", Values.String "alice"); ("secret", Values.String "hunter2") ]))
  in
  check string "secret is still decoded" "hunter2" decoded.secret;
  check (list string) "secret is still a required column" [ "login"; "secret" ] combined_aliases

let all_skipped () =
  let value : nothing = { ignored = "x" } in
  check string "field stays in the record" "x" value.ignored;
  check int "no parameters" 0 (List.length (nothing_params value))

let raw () =
  let value = Values.Map [ ("nested", Values.Int 1L) ] in
  let decoded = ok (Decode.decode_value raw_decoder (Values.Map [ ("payload", value) ])) in
  check bool "raw decoder" true (decoded.payload = value);
  check_value "payload" value (raw_params { payload = value })

let check_keys () =
  (match Decode.check_keys ~keys:person_aliases person_decoder with
  | Ok () -> ()
  | Error error -> fail (Errors.to_string error));
  match Decode.check_keys ~keys:[ "full_name"; "age" ] person_decoder with
  | Error (Errors.Decode_error _) -> ()
  | Ok () -> fail "expected missing fields"
  | Error error -> fail ("expected Decode_error, got " ^ Errors.to_string error)

let tests =
  [
    ("[Ppx] decode", [ test_case "aliases/options/nested" `Quick decode ]);
    ("[Ppx] missing_none", [ test_case "missing and Null" `Quick missing_none_null ]);
    ("[Ppx] params", [ test_case "record to parameters" `Quick params ]);
    ("[Ppx] params_null", [ test_case "None to Null" `Quick params_null ]);
    ("[Ppx] nested_list", [ test_case "list of nested records" `Quick nested_list ]);
    ("[Ppx] skip", [ test_case "skip is params-only" `Quick skip ]);
    ("[Ppx] skip_with_decoder", [ test_case "skip leaves decoding intact" `Quick skip_with_decoder ]);
    ("[Ppx] all_skipped", [ test_case "all fields skipped" `Quick all_skipped ]);
    ("[Ppx] raw", [ test_case "Values.t passthrough" `Quick raw ]);
    ("[Ppx] check_keys", [ test_case "generated aliases" `Quick check_keys ]);
  ]

let () = Alcotest.run "neodriver_ppx" tests
