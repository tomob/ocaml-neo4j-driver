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
  | Values.Uuid u -> field "CypherUUID" (`String u)
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
  let node_id = function
    | Some id -> field "CypherInt" (`Intlit (string_of_int id))
    | None -> field "CypherString" (`String "")
  in
  `Assoc
    [
      ("name", `String "Relationship");
      ( "data",
        `Assoc
          [
            ("id", legacy_id r.legacy_id);
            ("startNodeId", node_id r.start_legacy_id);
            ("endNodeId", node_id r.end_legacy_id);
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
    match Temporal.DateTime.offset_seconds dt with
    | Some offset -> ("utc_offset_s", `Int offset) :: data
    | None -> data
  in
  let data =
    match (Temporal.DateTime.tz dt, Temporal.DateTime.offset_seconds dt) with
    | Some (Temporal.Zone_name zone), Some _ -> ("timezone_id", `String zone) :: data
    | _ -> data
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
  `Assoc
    [
      ("name", `String "CypherVector");
      ("data", `Assoc [ ("dtype", `String (dtype_string v.dtype)); ("data", `String hex) ]);
    ]

and dtype_string = function
  | Values.I8 -> "i8"
  | Values.I16 -> "i16"
  | Values.I32 -> "i32"
  | Values.I64 -> "i64"
  | Values.F32 -> "f32"
  | Values.F64 -> "f64"

and dtype_of_string = function
  | "i8" -> Values.I8
  | "i16" -> Values.I16
  | "i32" -> Values.I32
  | "i64" -> Values.I64
  | "f32" -> Values.F32
  | "f64" -> Values.F64
  | other -> invalid_arg ("unknown vector dtype " ^ other)

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

(* --- Decoding (TestKit JSON -> Values.t) --- *)

let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

let int_field key data =
  match member key data with
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (
      match int_of_string_opt s with Some n -> n | None -> invalid_arg ("bad int " ^ key))
  | _ -> invalid_arg ("missing int " ^ key)

let int64_field key data =
  match member key data with
  | Some (`Int n) -> Int64.of_int n
  | Some (`Intlit s) -> (
      match Int64.of_string_opt s with Some n -> n | None -> invalid_arg ("bad int64 " ^ key))
  | _ -> invalid_arg ("missing int64 " ^ key)

let float_field key data =
  match member key data with
  | Some (`Float f) -> f
  | Some (`Int n) -> float_of_int n
  | _ -> invalid_arg ("missing float " ^ key)

let bytes_of_hex s =
  let parts = String.split_on_char ' ' (String.trim s) |> List.filter (fun p -> p <> "") in
  let b = Bytes.create (List.length parts) in
  List.iteri (fun i hex -> Bytes.set b i (Char.chr (int_of_string ("0x" ^ hex)))) parts;
  b

let date_of data =
  match
    Temporal.Date.of_ymd (int_field "year" data, int_field "month" data, int_field "day" data)
  with
  | Some d -> d
  | None -> invalid_arg "bad CypherDate"

let time_of data =
  let tz_offset_seconds =
    match member "utc_offset_s" data with Some (`Int n) -> Some n | _ -> None
  in
  match
    Temporal.Time.of_hms_ns ?tz_offset_seconds (int_field "hour" data) (int_field "minute" data)
      (int_field "second" data) (int_field "nanosecond" data)
  with
  | Some t -> t
  | None -> invalid_arg "bad CypherTime"

let datetime_of data =
  let tz_name =
    match member "timezone_id" data with Some (`String zone) -> Some zone | _ -> None
  in
  let tz_offset = match member "utc_offset_s" data with Some (`Int n) -> Some n | _ -> None in
  (* Prefer the named zone; use the given offset for the epoch so the wall
     clock maps to the same instant, then label the datetime with the zone. *)
  let base_tz =
    match tz_offset with
    | Some n -> Some (Temporal.Offset n)
    | None -> ( match tz_name with Some zone -> Some (Temporal.Zone_name zone) | None -> None)
  in
  match
    Temporal.DateTime.of_ymd_hms ?tz:base_tz
      (int_field "year" data, int_field "month" data, int_field "day" data)
      (int_field "hour" data, int_field "minute" data, int_field "second" data)
      (int_field "nanosecond" data)
  with
  | Some dt -> (
      match tz_name with
      | Some zone -> { dt with Temporal.tz = Some (Temporal.Zone_name zone) }
      | None -> dt)
  | None -> invalid_arg "bad CypherDateTime"

let duration_of data =
  Temporal.Duration.of_fields ~months:(int_field "months" data) ~days:(int_field "days" data)
    ~seconds:(int64_field "seconds" data) ~nanoseconds:(int_field "nanoseconds" data)

let point_of data =
  let system =
    match member "system" data with
    | Some (`String s) -> s
    | _ -> invalid_arg "missing point system"
  in
  let z =
    match member "z" data with
    | Some (`Float f) -> Some f
    | Some (`Int n) -> Some (float_of_int n)
    | _ -> None
  in
  let srid =
    match (system, z) with
    | "cartesian", None -> 7203
    | "cartesian", Some _ -> 9157
    | "wgs84", None -> 4326
    | "wgs84", Some _ -> 4979
    | _ -> invalid_arg ("unknown point system " ^ system)
  in
  { Values.srid; x = float_field "x" data; y = float_field "y" data; z }

let rec of_yojson json =
  let name =
    match member "name" json with Some (`String n) -> n | _ -> invalid_arg "missing value name"
  in
  let data = match member "data" json with Some d -> d | None -> `Assoc [] in
  let value = match member "value" data with Some v -> v | None -> `Null in
  match name with
  | "CypherNull" -> Values.Null
  | "CypherBool" -> (
      match value with `Bool b -> Values.Bool b | _ -> invalid_arg "bad CypherBool")
  | "CypherInt" -> (
      match value with
      | `Int n -> Values.Int (Int64.of_int n)
      | `Intlit s -> Values.Int (Int64.of_string s)
      | _ -> invalid_arg "bad CypherInt")
  | "CypherFloat" -> (
      match value with
      | `Float f -> Values.Float f
      | `Int n -> Values.Float (float_of_int n)
      | `Intlit s -> Values.Float (float_of_string s)
      | `String "NaN" -> Values.Float nan
      | `String "+Infinity" -> Values.Float infinity
      | `String "-Infinity" -> Values.Float neg_infinity
      | _ -> invalid_arg "bad CypherFloat")
  | "CypherString" -> (
      match value with `String s -> Values.String s | _ -> invalid_arg "bad CypherString")
  | "CypherBytes" -> (
      match value with
      | `String hex -> Values.Bytes (bytes_of_hex hex)
      | _ -> invalid_arg "bad CypherBytes")
  | "CypherList" -> (
      match value with
      | `List l -> Values.List (List.map of_yojson l)
      | _ -> invalid_arg "bad CypherList")
  | "CypherMap" -> (
      match value with
      | `Assoc m -> Values.Map (List.map (fun (k, v) -> (k, of_yojson v)) m)
      | _ -> invalid_arg "bad CypherMap")
  | "CypherDate" -> Values.Date (date_of data)
  | "CypherTime" -> Values.Time (time_of data)
  | "CypherDateTime" -> Values.DateTime (datetime_of data)
  | "CypherDuration" -> Values.Duration (duration_of data)
  | "CypherPoint" -> Values.Point (point_of data)
  | "CypherUUID" -> (
      match value with `String s -> Values.Uuid s | _ -> invalid_arg "bad CypherUUID")
  | "CypherVector" -> (
      match data with
      | `Assoc fields -> (
          match (List.assoc_opt "dtype" fields, List.assoc_opt "data" fields) with
          | Some (`String dtype), Some (`String hex) ->
              Values.Vector { Values.dtype = dtype_of_string dtype; data = bytes_of_hex hex }
          | _ -> invalid_arg "bad CypherVector")
      | _ -> invalid_arg "bad CypherVector")
  | _ -> invalid_arg ("unsupported TestKit value " ^ name)
