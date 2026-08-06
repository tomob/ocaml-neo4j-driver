(* Unit tests for the TestKit value encoding. *)

open Neodriver
open Alcotest

let check_yojson name expected actual =
  check string name (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let scalars () =
  check_yojson "null"
    (`Assoc [ ("name", `String "CypherNull") ])
    (Testkit_values.to_yojson Values.Null);
  check_yojson "bool"
    (`Assoc [ ("name", `String "CypherBool"); ("data", `Assoc [ ("value", `Bool true) ]) ])
    (Testkit_values.to_yojson (Values.Bool true));
  check_yojson "int"
    (`Assoc [ ("name", `String "CypherInt"); ("data", `Assoc [ ("value", `Intlit "42") ]) ])
    (Testkit_values.to_yojson (Values.Int 42L));
  check_yojson "float"
    (`Assoc [ ("name", `String "CypherFloat"); ("data", `Assoc [ ("value", `Float 1.5) ]) ])
    (Testkit_values.to_yojson (Values.Float 1.5));
  check_yojson "infinity"
    (`Assoc [ ("name", `String "CypherFloat"); ("data", `Assoc [ ("value", `String "+Infinity") ]) ])
    (Testkit_values.to_yojson (Values.Float infinity));
  check_yojson "nan"
    (`Assoc [ ("name", `String "CypherFloat"); ("data", `Assoc [ ("value", `String "NaN") ]) ])
    (Testkit_values.to_yojson (Values.Float nan));
  check_yojson "string"
    (`Assoc [ ("name", `String "CypherString"); ("data", `Assoc [ ("value", `String "hi") ]) ])
    (Testkit_values.to_yojson (Values.String "hi"))

let containers () =
  let list_value =
    `Assoc
      [
        ("name", `String "CypherList");
        ( "data",
          `Assoc
            [
              ( "value",
                `List
                  [
                    `Assoc
                      [ ("name", `String "CypherInt"); ("data", `Assoc [ ("value", `Intlit "1") ]) ];
                  ] );
            ] );
      ]
  in
  check_yojson "list" list_value (Testkit_values.to_yojson (Values.List [ Values.Int 1L ]));
  let map_value =
    `Assoc
      [
        ("name", `String "CypherMap");
        ( "data",
          `Assoc
            [
              ( "value",
                `Assoc
                  [
                    ( "a",
                      `Assoc
                        [
                          ("name", `String "CypherInt"); ("data", `Assoc [ ("value", `Intlit "2") ]);
                        ] );
                  ] );
            ] );
      ]
  in
  check_yojson "map" map_value (Testkit_values.to_yojson (Values.Map [ ("a", Values.Int 2L) ]))

let node () =
  let n =
    Values.Node
      {
        element_id = "4:abc:1";
        legacy_id = Some 1;
        labels = [ "Person" ];
        properties = [ ("name", Values.String "Alice") ];
      }
  in
  let expected =
    `Assoc
      [
        ("name", `String "Node");
        ( "data",
          `Assoc
            [
              ( "id",
                `Assoc
                  [ ("name", `String "CypherInt"); ("data", `Assoc [ ("value", `Intlit "1") ]) ] );
              ( "labels",
                `Assoc
                  [
                    ("name", `String "CypherList");
                    ( "data",
                      `Assoc
                        [
                          ( "value",
                            `List
                              [
                                `Assoc
                                  [
                                    ("name", `String "CypherString");
                                    ("data", `Assoc [ ("value", `String "Person") ]);
                                  ];
                              ] );
                        ] );
                  ] );
              ( "props",
                `Assoc
                  [
                    ("name", `String "CypherMap");
                    ( "data",
                      `Assoc
                        [
                          ( "value",
                            `Assoc
                              [
                                ( "name",
                                  `Assoc
                                    [
                                      ("name", `String "CypherString");
                                      ("data", `Assoc [ ("value", `String "Alice") ]);
                                    ] );
                              ] );
                        ] );
                  ] );
              ( "elementId",
                `Assoc
                  [
                    ("name", `String "CypherString");
                    ("data", `Assoc [ ("value", `String "4:abc:1") ]);
                  ] );
            ] );
      ]
  in
  check_yojson "node" expected (Testkit_values.to_yojson n)

let temporal () =
  let date =
    match Temporal.Date.of_ymd (2026, 8, 6) with Some d -> Values.Date d | None -> fail "bad date"
  in
  let date_json =
    `Assoc
      [
        ("name", `String "CypherDate");
        ("data", `Assoc [ ("year", `Int 2026); ("month", `Int 8); ("day", `Int 6) ]);
      ]
  in
  check_yojson "date" date_json (Testkit_values.to_yojson date);
  let time =
    match Temporal.Time.of_hms_ns 10 20 30 40 with
    | Some t -> Values.Time t
    | None -> fail "bad time"
  in
  let time_json =
    `Assoc
      [
        ("name", `String "CypherTime");
        ( "data",
          `Assoc
            [ ("hour", `Int 10); ("minute", `Int 20); ("second", `Int 30); ("nanosecond", `Int 40) ]
        );
      ]
  in
  check_yojson "time" time_json (Testkit_values.to_yojson time);
  let duration =
    Values.Duration (Temporal.Duration.of_fields ~months:1 ~days:2 ~seconds:3L ~nanoseconds:4)
  in
  let duration_json =
    `Assoc
      [
        ("name", `String "CypherDuration");
        ( "data",
          `Assoc
            [
              ("months", `Int 1); ("days", `Int 2); ("seconds", `Intlit "3"); ("nanoseconds", `Int 4);
            ] );
      ]
  in
  check_yojson "duration" duration_json (Testkit_values.to_yojson duration)

let point () =
  let p = Values.Point { srid = 4326; x = 1.0; y = 2.0; z = None } in
  let json =
    `Assoc
      [
        ("name", `String "CypherPoint");
        ( "data",
          `Assoc [ ("system", `String "wgs84"); ("x", `Float 1.0); ("y", `Float 2.0); ("z", `Null) ]
        );
      ]
  in
  check_yojson "point" json (Testkit_values.to_yojson p)

(* Decode TestKit JSON back to Values.t. *)
let decoding () =
  let decode name value expected =
    match
      Testkit_values.of_yojson
        (`Assoc [ ("name", `String name); ("data", `Assoc [ ("value", value) ]) ])
    with
    | v
      when match (v, expected) with
           | Values.Float a, Values.Float b -> (Float.is_nan a && Float.is_nan b) || a = b
           | _ -> v = expected ->
        ()
    | v -> fail (name ^ ": got " ^ Values.to_string v)
  in
  decode "CypherNull" `Null Values.Null;
  decode "CypherBool" (`Bool true) (Values.Bool true);
  decode "CypherInt" (`Intlit "42") (Values.Int 42L);
  decode "CypherFloat" (`Float 1.5) (Values.Float 1.5);
  decode "CypherFloat" (`String "NaN") (Values.Float nan);
  decode "CypherString" (`String "hi") (Values.String "hi");
  decode "CypherList"
    (`List [ `Assoc [ ("name", `String "CypherInt"); ("data", `Assoc [ ("value", `Intlit "1") ]) ] ])
    (Values.List [ Values.Int 1L ]);
  decode "CypherMap"
    (`Assoc
       [
         ("a", `Assoc [ ("name", `String "CypherInt"); ("data", `Assoc [ ("value", `Intlit "2") ]) ]);
       ])
    (Values.Map [ ("a", Values.Int 2L) ]);
  let date =
    `Assoc
      [
        ("name", `String "CypherDate");
        ("data", `Assoc [ ("year", `Int 2026); ("month", `Int 8); ("day", `Int 6) ]);
      ]
  in
  match Testkit_values.of_yojson date with
  | Values.Date d ->
      let y, m, day = Temporal.Date.to_ymd d in
      check (pair (pair int int) int) "date decoded" ((2026, 8), 6) ((y, m), day)
  | v -> fail (Values.to_string v)

(* Encoding then decoding round-trips. *)
let round_trip () =
  let check_rt v =
    check bool (Values.to_string v) true (Testkit_values.of_yojson (Testkit_values.to_yojson v) = v)
  in
  check_rt Values.Null;
  check_rt (Values.Bool false);
  check_rt (Values.Int (-7L));
  check_rt (Values.Float 3.25);
  check_rt (Values.String "text");
  check_rt (Values.List [ Values.Int 1L; Values.String "x" ]);
  check_rt (Values.Map [ ("k", Values.Bool true) ]);
  let date = Values.Date (Temporal.Date.of_ymd (2020, 2, 29) |> Option.get) in
  check_rt date;
  let time = Values.Time (Temporal.Time.of_hms_ns 1 2 3 4 |> Option.get) in
  check_rt time;
  let duration =
    Values.Duration (Temporal.Duration.of_fields ~months:1 ~days:2 ~seconds:3L ~nanoseconds:4)
  in
  check_rt duration;
  let point = Values.Point { srid = 9157; x = 1.0; y = 2.0; z = Some 3.0 } in
  check_rt point

let tests =
  [
    ("[Testkit > Values] scalars", [ test_case "scalar encoding" `Quick scalars ]);
    ("[Testkit > Values] containers", [ test_case "list/map encoding" `Quick containers ]);
    ("[Testkit > Values] node", [ test_case "node encoding" `Quick node ]);
    ("[Testkit > Values] temporal", [ test_case "temporal encoding" `Quick temporal ]);
    ("[Testkit > Values] point", [ test_case "point encoding" `Quick point ]);
    ("[Testkit > Values] decoding", [ test_case "decode TestKit JSON" `Quick decoding ]);
    ("[Testkit > Values] round_trip", [ test_case "encode then decode" `Quick round_trip ]);
  ]

let () = Alcotest.run "testkit-values" tests
