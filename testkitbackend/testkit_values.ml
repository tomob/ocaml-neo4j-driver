open Neodriver

(* TestKit value encoding: Values.t -> TestKit JSON.

   Mirrors the Python driver's testkitbackend/totestkit.py field(). Scalars are
   wrapped as {"name": <CypherType>, "data": {"value": <value>}}; graph and
   temporal types carry their fields directly in "data". *)

let field name value = `Assoc [ ("name", `String name); ("data", `Assoc [ ("value", value) ]) ]
let null = `Assoc [ ("name", `String "CypherNull") ]
let cypher_int i = field "CypherInt" (`Intlit (Int64.to_string i))

let rec to_yojson = function
  | Values.Null -> null
  | Values.Bool b -> field "CypherBool" (`Bool b)
  | Values.Int i -> cypher_int i
  | Values.Float f ->
      let value =
        if f = infinity then `String "+Infinity"
        else if f = neg_infinity then `String "-Infinity"
        else if Float.is_nan f then `String "NaN"
        else `Float f
      in
      field "CypherFloat" value
  | Values.String s -> field "CypherString" (`String s)
  | Values.Bytes b ->
      let hex =
        Bytes.to_string b |> String.to_seq
        |> Seq.map (fun c -> Printf.sprintf "%02x" (Char.code c))
        |> List.of_seq |> String.concat " "
      in
      field "CypherBytes" (`String hex)
  | Values.List l -> field "CypherList" (`List (List.map to_yojson l))
  | Values.Map m -> field "CypherMap" (`Assoc (List.map (fun (k, v) -> (k, to_yojson v)) m))
  | Values.Node n -> node n
  | Values.Relationship r -> relationship r
  | Values.Unbound_relationship _ -> invalid_arg "UnboundRelationship cannot be encoded"
  | Values.Path p -> path p
  | Values.Point p -> point p
  | Values.Date d -> date d
  | Values.Time t -> time t
  | Values.DateTime dt -> datetime dt
  | Values.Duration d -> duration d
  | Values.Vector v -> vector v
  | Values.Unsupported u -> unsupported u
  | Values.Broken _ -> invalid_arg "Broken values cannot be encoded"

and node n =
  `Assoc
    [
      ("name", `String "Node");
      ( "data",
        `Assoc
          [
            ("id", legacy_id n.legacy_id);
            ( "labels",
              field "CypherList"
                (`List (List.map (fun l -> field "CypherString" (`String l)) n.labels)) );
            ( "props",
              field "CypherMap" (`Assoc (List.map (fun (k, v) -> (k, to_yojson v)) n.properties)) );
            ("elementId", field "CypherString" (`String n.element_id));
          ] );
    ]

and relationship r =
  `Assoc
    [
      ("name", `String "Relationship");
      ( "data",
        `Assoc
          [
            ("id", legacy_id r.legacy_id);
            ("startNodeId", field "CypherString" (`String r.start));
            ("endNodeId", field "CypherString" (`String r.end_));
            ("type", field "CypherString" (`String r.rel_type));
            ( "props",
              field "CypherMap" (`Assoc (List.map (fun (k, v) -> (k, to_yojson v)) r.properties)) );
            ("elementId", field "CypherString" (`String r.element_id));
            ("startNodeElementId", field "CypherString" (`String r.start));
            ("endNodeElementId", field "CypherString" (`String r.end_));
          ] );
    ]

and path p =
  `Assoc
    [
      ("name", `String "Path");
      ( "data",
        `Assoc
          [
            ("nodes", field "CypherList" (`List (List.map node p.nodes)));
            ("relationships", field "CypherList" (`List (List.map relationship p.relationships)));
          ] );
    ]

and point p =
  let system = if Values.point_is_cartesian p then "cartesian" else "wgs84" in
  `Assoc
    [
      ("name", `String "CypherPoint");
      ( "data",
        `Assoc
          [
            ("system", `String system);
            ("x", `Float p.x);
            ("y", `Float p.y);
            ("z", match p.z with Some z -> `Float z | None -> `Null);
          ] );
    ]

and date d =
  let year, month, day = Temporal.Date.to_ymd d in
  `Assoc
    [
      ("name", `String "CypherDate");
      ("data", `Assoc [ ("year", `Int year); ("month", `Int month); ("day", `Int day) ]);
    ]

and time t =
  let hour, minute, second, nanosecond = Temporal.Time.to_hms_ns t in
  let data =
    [
      ("hour", `Int hour);
      ("minute", `Int minute);
      ("second", `Int second);
      ("nanosecond", `Int nanosecond);
    ]
  in
  let data =
    match Temporal.Time.tz_offset_seconds t with
    | Some offset -> ("utc_offset_s", `Int offset) :: data
    | None -> data
  in
  `Assoc [ ("name", `String "CypherTime"); ("data", `Assoc data) ]

and datetime dt =
  let (year, month, day), (hour, minute, second), nanosecond = Temporal.DateTime.to_ymd_hms dt in
  let data =
    [
      ("year", `Int year);
      ("month", `Int month);
      ("day", `Int day);
      ("hour", `Int hour);
      ("minute", `Int minute);
      ("second", `Int second);
      ("nanosecond", `Int nanosecond);
    ]
  in
  let data =
    match Temporal.DateTime.tz dt with
    | None -> data
    | Some (Temporal.Offset offset) -> ("utc_offset_s", `Int offset) :: data
    | Some (Temporal.Zone_name zone) -> ("timezone_id", `String zone) :: data
  in
  `Assoc [ ("name", `String "CypherDateTime"); ("data", `Assoc data) ]

and duration d =
  `Assoc
    [
      ("name", `String "CypherDuration");
      ( "data",
        `Assoc
          [
            ("months", `Int d.months);
            ("days", `Int d.days);
            ("seconds", `Intlit (Int64.to_string d.seconds));
            ("nanoseconds", `Int d.nanoseconds);
          ] );
    ]

and vector v =
  let hex =
    Bytes.to_string v.data |> String.to_seq
    |> Seq.map (fun c -> Printf.sprintf "%02x" (Char.code c))
    |> List.of_seq |> String.concat " "
  in
  field "CypherVector" (`Assoc [ ("dtype", `String (dtype_string v.dtype)); ("data", `String hex) ])

and dtype_string = function
  | Values.I8 -> "i8"
  | Values.I16 -> "i16"
  | Values.I32 -> "i32"
  | Values.I64 -> "i64"
  | Values.F32 -> "f32"
  | Values.F64 -> "f64"

and unsupported u =
  let data =
    [
      ("name", `String u.name);
      ( "minimumProtocol",
        `String
          (Printf.sprintf "%d.%d" (fst u.minimum_protocol_version) (snd u.minimum_protocol_version))
      );
    ]
  in
  let data = match u.message with Some m -> ("message", `String m) :: data | None -> data in
  `Assoc [ ("name", `String "CypherUnsupportedType"); ("data", `Assoc data) ]

and legacy_id = function
  | Some i -> field "CypherInt" (`Intlit (string_of_int i))
  | None -> field "CypherString" (`String "")
