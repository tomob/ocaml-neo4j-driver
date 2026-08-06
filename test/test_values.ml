open Neodriver
open Alcotest

let values () =
  let node =
    Values.Node
      {
        element_id = "1";
        legacy_id = Some 42;
        labels = [ "Person" ];
        properties = [ ("name", Values.String "Alice") ];
      }
  in
  check string "node" "Node<1>{Person}{\"name\": \"Alice\"}" (Values.to_string node);
  let rel =
    Values.Relationship
      {
        element_id = "r1";
        legacy_id = None;
        rel_type = "KNOWS";
        start = "1";
        end_ = "2";
        start_legacy_id = None;
        end_legacy_id = None;
        properties = [];
      }
  in
  check string "rel" "Relationship<r1>{}" (Values.to_string rel);
  let pt = Values.Point { srid = 4326; x = 1.5; y = 2.5; z = None } in
  (match pt with
  | Values.Point p ->
      check bool "wgs84" true (Values.point_is_wgs84 p);
      check bool "not cartesian" false (Values.point_is_cartesian p)
  | _ -> fail "expected point");
  check string "point" "Point{4326:1.5, 2.5}" (Values.to_string pt);
  check bool "cartesian 3d" true
    (Values.point_is_cartesian { srid = 9157; x = 0.; y = 0.; z = Some 1. });
  let vec = Values.Vector { dtype = Values.I64; data = Bytes.create 16 } in
  (match vec with
  | Values.Vector v -> check int "vector len" 2 (Values.vector_length v)
  | _ -> fail "expected vector");
  let dt =
    match Temporal.DateTime.of_ymd_hms (1970, 1, 1) (0, 0, 0) 0 with
    | Some dt -> Values.DateTime dt
    | None -> fail "datetime"
  in
  check string "datetime" "1970-01-01T00:00:00" (Values.to_string dt);
  let br = Values.Broken { error = "bad"; raw = Packstream.Null } in
  check string "broken" "<broken: bad>" (Values.to_string br);
  let duration =
    Values.Duration (Temporal.Duration.of_fields ~months:1 ~days:0 ~seconds:0L ~nanoseconds:0)
  in
  check string "duration" "P1M" (Values.to_string duration)

let list_map () =
  let v = Values.List [ Values.Int 1L; Values.Map [ ("k", Values.String "v") ] ] in
  check string "list/map" "[1, {\"k\": \"v\"}]" (Values.to_string v)

let tests =
  [
    ("[Values] values", [ test_case "construct and print" `Quick values ]);
    ("[Values] list_map", [ test_case "containers" `Quick list_map ]);
  ]
