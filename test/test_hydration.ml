open Neodriver
open Packstream
open Alcotest

let scalar () =
  let h = Hydration.create Hydration.V2 in
  (match Hydration.hydrate h Null with Values.Null -> () | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Int 42L) with
  | Values.Int n -> check int64 "int" 42L n
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (String "hi") with
  | Values.String s -> check string "string" "hi" s
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (List [ Int 1L; Bool true ]) with
  | Values.List l -> check string "list" "[1, true]" (Values.to_string (Values.List l))
  | v -> fail (Values.to_string v));
  match Hydration.hydrate h (Map [ ("a", Int 1L) ]) with
  | Values.Map m -> check string "map" "{\"a\": 1}" (Values.to_string (Values.Map m))
  | v -> fail (Values.to_string v)

let node () =
  let h = Hydration.create Hydration.V2 in
  let struct_ =
    Structure
      ( 0x4E,
        [
          String "n1";
          List [ String "Person"; String "Employee" ];
          Map [ ("name", String "Alice"); ("age", Int 30L) ];
        ] )
  in
  match Hydration.hydrate h struct_ with
  | Values.Node n ->
      check string "element_id" "n1" n.element_id;
      check (list string) "labels" [ "Person"; "Employee" ] n.labels;
      check string "name prop" "Alice"
        (match List.assoc_opt "name" n.properties with Some (Values.String s) -> s | _ -> "?");
      check int "graph nodes" 1 (List.length (Hydration.nodes h))
  | v -> fail (Values.to_string v)

let node_legacy_id () =
  (* Bolt 3/4 style: integer id *)
  let h = Hydration.create Hydration.V1 in
  let struct_ = Structure (0x4E, [ Int 7L; List []; Map [] ]) in
  match Hydration.hydrate h struct_ with
  | Values.Node n ->
      check string "element_id fallback" "7" n.element_id;
      check (option int) "legacy_id" (Some 7) n.legacy_id
  | v -> fail (Values.to_string v)

let relationship () =
  let h = Hydration.create Hydration.V2 in
  let struct_ =
    Structure
      (0x52, [ String "r1"; String "n1"; String "n2"; String "KNOWS"; Map [ ("since", Int 2000L) ] ])
  in
  match Hydration.hydrate h struct_ with
  | Values.Relationship r ->
      check string "start" "n1" r.start;
      check string "end" "n2" r.end_;
      check string "type" "KNOWS" r.rel_type;
      check int "graph nodes" 2 (List.length (Hydration.nodes h));
      check int "graph rels" 1 (List.length (Hydration.relationships h))
  | v -> fail (Values.to_string v)

let node_dedup () =
  (* A relationship endpoint node first, then a full node with the same
     element_id: labels/properties must be merged. *)
  let h = Hydration.create Hydration.V2 in
  let rel = Structure (0x52, [ String "r1"; String "n1"; String "n2"; String "X"; Map [] ]) in
  ignore (Hydration.hydrate h rel);
  let node_struct =
    Structure (0x4E, [ String "n1"; List [ String "Person" ]; Map [ ("name", String "Bob") ] ])
  in
  match Hydration.hydrate h node_struct with
  | Values.Node n ->
      check (list string) "merged labels" [ "Person" ] n.labels;
      check string "merged props" "{\"name\": \"Bob\"}" (Values.to_string (Values.Map n.properties));
      check int "graph nodes" 2 (List.length (Hydration.nodes h))
  | v -> fail (Values.to_string v)

let path () =
  let h = Hydration.create Hydration.V2 in
  let nodes =
    List
      [
        Structure (0x4E, [ String "n1"; List []; Map [] ]);
        Structure (0x4E, [ String "n2"; List []; Map [] ]);
        Structure (0x4E, [ String "n3"; List []; Map [] ]);
      ]
  in
  let rels =
    List
      [
        Structure (0x72, [ String "r1"; String "A"; Map [] ]);
        Structure (0x72, [ String "r2"; String "B"; Map [] ]);
      ]
  in
  (* forward r1 (n1->n2), reverse r2 (n3->n2) *)
  let sequence = List [ Int 1L; Int 1L; Int (-2L); Int 2L ] in
  let struct_ = Structure (0x50, [ nodes; rels; sequence ]) in
  match Hydration.hydrate h struct_ with
  | Values.Path p -> (
      check int "path nodes" 3 (List.length p.nodes);
      check int "path rels" 2 (List.length p.relationships);
      match p.relationships with
      | [ r1; r2 ] ->
          check string "r1 start" "n1" r1.start;
          check string "r1 end" "n2" r1.end_;
          check string "r2 start" "n3" r2.start;
          check string "r2 end" "n2" r2.end_
      | _ -> fail "two rels")
  | v -> fail (Values.to_string v)

let temporal () =
  let h = Hydration.create Hydration.V2 in
  (match Hydration.hydrate h (Structure (0x44, [ Int 19723L ])) with
  | Values.Date d -> check string "date" "2024-01-01" (Values.to_string (Values.Date d))
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x54, [ Int 43_200_000_000_000L; Int 7200L ])) with
  | Values.Time t -> check string "time" "12:00:00+02:00" (Values.to_string (Values.Time t))
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x64, [ Int 0L; Int 0L ])) with
  | Values.DateTime dt ->
      check string "local dt" "1970-01-01T00:00:00" (Values.to_string (Values.DateTime dt))
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x49, [ Int (-7200L); Int 0L; Int 7200L ])) with
  | Values.DateTime dt ->
      check string "offset dt" "1970-01-01T00:00:00+02:00" (Values.to_string (Values.DateTime dt))
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x69, [ Int 0L; Int 0L; String "Europe/Warsaw" ])) with
  | Values.DateTime dt ->
      check string "zone dt" "1970-01-01T00:00:00" (Values.to_string (Values.DateTime dt))
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x45, [ Int 2L; Int 3L; Int 4L; Int 5L ])) with
  | Values.Duration d ->
      check string "duration" "P2M3DT4.000000005S" (Values.to_string (Values.Duration d))
  | v -> fail (Values.to_string v));
  (* 'F' is not valid in V2 *)
  match Hydration.hydrate h (Structure (0x46, [ Int 0L; Int 0L; Int 0L ])) with
  | Values.Broken _ -> ()
  | v -> fail (Values.to_string v)

let point_vector_unsupported () =
  let h = Hydration.create Hydration.V3 in
  (match Hydration.hydrate h (Structure (0x58, [ Int 4326L; Float 1.5; Float 2.5 ])) with
  | Values.Point p ->
      check bool "wgs84" true (Values.point_is_wgs84 p);
      check string "point" "Point{4326:1.5, 2.5}" (Values.to_string (Values.Point p))
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x56, [ Int 0xCBL; Bytes (Bytes.create 8) ])) with
  | Values.Vector v -> check int "vector len" 1 (Values.vector_length v)
  | v -> fail (Values.to_string v));
  (match Hydration.hydrate h (Structure (0x3F, [ String "FancyType"; Int 6L; Int 0L; Map [] ])) with
  | Values.Unsupported u ->
      check string "unsupported name" "FancyType" u.name;
      check (pair int int) "min version" (6, 0) u.minimum_protocol_version
  | v -> fail (Values.to_string v));
  (* vector is not valid in V2 *)
  let h2 = Hydration.create Hydration.V2 in
  match Hydration.hydrate h2 (Structure (0x56, [ Int 0xCBL; Bytes (Bytes.create 8) ])) with
  | Values.Broken _ -> ()
  | v -> fail (Values.to_string v)

let broken_propagation () =
  let h = Hydration.create Hydration.V2 in
  (* unknown tag inside a list *)
  (match Hydration.hydrate h (List [ Int 1L; Structure (0x7F, []) ]) with
  | Values.Broken _ -> ()
  | v -> fail (Values.to_string v));
  (* unknown tag inside a map value *)
  match Hydration.hydrate h (Map [ ("k", Structure (0x7F, [])) ]) with
  | Values.Broken _ -> ()
  | v -> fail (Values.to_string v)

let round_trip () =
  let h = Hydration.create Hydration.V2 in
  let values =
    [
      Values.Null;
      Values.Bool true;
      Values.Int (-5L);
      Values.Float 1.5;
      Values.String "text";
      Values.Bytes (Bytes.of_string "x");
      Values.List [ Values.Int 1L; Values.String "a" ];
      Values.Map [ ("k", Values.Bool false) ];
      Values.Date (Temporal.Date.of_days 19723);
      Values.Time (Temporal.Time.of_ticks 43_200_000_000_000L);
      Values.DateTime (Temporal.DateTime.of_epoch_seconds ~tz:(Temporal.Offset 7200) (-7200L) 0);
      Values.Duration (Temporal.Duration.of_fields ~months:2 ~days:3 ~seconds:4L ~nanoseconds:5);
      Values.Point { srid = 4326; x = 1.5; y = 2.5; z = None };
      Values.Node
        {
          element_id = "n1";
          legacy_id = None;
          labels = [ "Person" ];
          properties = [ ("name", Values.String "A") ];
        };
      Values.Relationship
        {
          element_id = "r1";
          legacy_id = None;
          rel_type = "KNOWS";
          start = "n1";
          end_ = "n2";
          start_legacy_id = None;
          end_legacy_id = None;
          properties = [];
        };
    ]
  in
  List.iter
    (fun v ->
      let packed = Hydration.dehydrate h v in
      match Hydration.hydrate h packed with
      | hydrated ->
          check string (Values.to_string v) (Values.to_string v) (Values.to_string hydrated))
    values

let vector_round_trip () =
  let h = Hydration.create Hydration.V3 in
  let v = Values.Vector { dtype = Values.F32; data = Bytes.create 8 } in
  let packed = Hydration.dehydrate h v in
  match Hydration.hydrate h packed with
  | Values.Vector v' -> check int "vector len" 2 (Values.vector_length v')
  | x -> fail (Values.to_string x)

(* Bolt 5.1+/6 node: [id; labels; properties; element_id]. *)
let node_element_id () =
  let h = Hydration.create Hydration.V3 in
  let struct_ = Structure (0x4E, [ Int 7L; List [ String "Person" ]; Map []; String "4:db:7" ]) in
  match Hydration.hydrate h struct_ with
  | Values.Node n ->
      check string "element_id" "4:db:7" n.element_id;
      check (option int) "legacy_id" (Some 7) n.legacy_id
  | v -> fail (Values.to_string v)

(* Bolt 5.1+/6 relationship: [id; start; end; type; props; element_id;
   start_element_id; end_element_id]. *)
let relationship_element_id () =
  let h = Hydration.create Hydration.V3 in
  let struct_ =
    Structure
      ( 0x52,
        [
          Int 1L;
          Int 4L;
          Int 5L;
          String "KNOWS";
          Map [ ("since", Int 1999L) ];
          String "5:rel:1";
          String "4:n4";
          String "4:n5";
        ] )
  in
  match Hydration.hydrate h struct_ with
  | Values.Relationship r ->
      check string "element_id" "5:rel:1" r.element_id;
      check (option int) "legacy_id" (Some 1) r.legacy_id;
      check string "start" "4:n4" r.start;
      check string "end" "4:n5" r.end_;
      check (option int) "start_legacy" (Some 4) r.start_legacy_id;
      check (option int) "end_legacy" (Some 5) r.end_legacy_id
  | v -> fail (Values.to_string v)

(* Bolt 5.1+/6 unbound relationship in a path: [id; type; props; element_id]. *)
let unbound_element_id () =
  let h = Hydration.create Hydration.V3 in
  let struct_ = Structure (0x72, [ Int 0L; String "KNOWS"; Map []; String "5:rel:0" ]) in
  match Hydration.hydrate h struct_ with
  | Values.Unbound_relationship r ->
      check string "element_id" "5:rel:0" r.element_id;
      check (option int) "legacy_id" (Some 0) r.legacy_id
  | v -> fail (Values.to_string v)

let tests =
  [
    ("[Hydration] scalar", [ test_case "scalars" `Quick scalar ]);
    ("[Hydration] node", [ test_case "node" `Quick node ]);
    ("[Hydration] node_legacy_id", [ test_case "legacy id" `Quick node_legacy_id ]);
    ("[Hydration] node_element_id", [ test_case "node with element_id" `Quick node_element_id ]);
    ("[Hydration] relationship", [ test_case "relationship" `Quick relationship ]);
    ( "[Hydration] relationship_element_id",
      [ test_case "relationship with element_ids" `Quick relationship_element_id ] );
    ( "[Hydration] unbound_element_id",
      [ test_case "unbound relationship with element_id" `Quick unbound_element_id ] );
    ("[Hydration] node_dedup", [ test_case "node dedup/merge" `Quick node_dedup ]);
    ("[Hydration] path", [ test_case "path stitching" `Quick path ]);
    ("[Hydration] temporal", [ test_case "temporal tags" `Quick temporal ]);
    ("[Hydration] point_vector_unsupported", [ test_case "v3 tags" `Quick point_vector_unsupported ]);
    ("[Hydration] broken", [ test_case "broken propagation" `Quick broken_propagation ]);
    ("[Hydration] round_trip", [ test_case "hydrate<->dehydrate" `Quick round_trip ]);
    ("[Hydration] vector_round_trip", [ test_case "vector round trip" `Quick vector_round_trip ]);
  ]
