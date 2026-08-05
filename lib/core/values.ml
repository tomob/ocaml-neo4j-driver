(* Rich value types for the Neo4j driver.

   These are the hydrated values exchanged with the server, as opposed to the
   transport-level Packstream.value. Graph entities, spatial points, temporal
   values, vectors and unsupported types are produced by the hydration layer
   from PackStream structures. See temporal.ml for the temporal types. *)

type node = {
  element_id : string;
  legacy_id : int option;
  labels : string list;
  properties : (string * t) list;
}

and relationship = {
  element_id : string;
  legacy_id : int option;
  rel_type : string;
  start : string;
  end_ : string;
  properties : (string * t) list;
}

and unbound_relationship = {
  element_id : string;
  legacy_id : int option;
  rel_type : string;
  properties : (string * t) list;
}

and path = { nodes : node list; relationships : relationship list }
and point = { srid : int; x : float; y : float; z : float option }
and vector_dtype = I8 | I16 | I32 | I64 | F32 | F64
and vector = { dtype : vector_dtype; data : bytes }

and unsupported = {
  name : string;
  minimum_protocol_version : int * int;
  message : string option;
}

and broken = { error : string; raw : Neodriver_packstream.Packstream.value }

and t =
  | Null
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Bytes of bytes
  | List of t list
  | Map of (string * t) list
  | Node of node
  | Relationship of relationship
  | Unbound_relationship of unbound_relationship
  | Path of path
  | Point of point
  | Date of Temporal.Date.t
  | Time of Temporal.Time.t
  | DateTime of Temporal.DateTime.t
  | Duration of Temporal.Duration.t
  | Vector of vector
  | Unsupported of unsupported
  | Broken of broken

(* --- Point --- *)

let cartesian_2d_srid = 7203
let cartesian_3d_srid = 9157
let wgs84_2d_srid = 4326
let wgs84_3d_srid = 4979
let point_x p = p.x
let point_y p = p.y
let point_z p = p.z

let point_coordinates p =
  match p.z with None -> [ p.x; p.y ] | Some z -> [ p.x; p.y; z ]

let point_is_cartesian p =
  p.srid = cartesian_2d_srid || p.srid = cartesian_3d_srid

let point_is_wgs84 p = p.srid = wgs84_2d_srid || p.srid = wgs84_3d_srid

(* --- Vector --- *)

let vector_dtype_size = function
  | I8 -> 1
  | I16 -> 2
  | I32 -> 4
  | I64 -> 8
  | F32 -> 4
  | F64 -> 8

let vector_length v = Bytes.length v.data / vector_dtype_size v.dtype

let vector_dtype_to_string = function
  | I8 -> "I8"
  | I16 -> "I16"
  | I32 -> "I32"
  | I64 -> "I64"
  | F32 -> "F32"
  | F64 -> "F64"

(* --- Pretty printing --- *)

let rec map_to_string entries =
  "{"
  ^ String.concat ", "
      (List.map (fun (k, v) -> Printf.sprintf "%S: %s" k (to_string v)) entries)
  ^ "}"

and to_string = function
  | Null -> "null"
  | Bool b -> string_of_bool b
  | Int n -> Int64.to_string n
  | Float f -> string_of_float f
  | String s -> Printf.sprintf "%S" s
  | Bytes b -> Printf.sprintf "<bytes:%d>" (Bytes.length b)
  | List items -> "[" ^ String.concat ", " (List.map to_string items) ^ "]"
  | Map entries -> map_to_string entries
  | Node n ->
      Printf.sprintf "Node<%s>{%s}%s" n.element_id
        (String.concat "," n.labels)
        (map_to_string n.properties)
  | Relationship r ->
      Printf.sprintf "Relationship<%s>%s" r.element_id
        (map_to_string r.properties)
  | Unbound_relationship r ->
      Printf.sprintf "UnboundRelationship<%s>%s" r.element_id
        (map_to_string r.properties)
  | Path p ->
      Printf.sprintf "Path(%s)"
        (String.concat ", " (List.map (fun n -> n.element_id) p.nodes))
  | Point p ->
      Printf.sprintf "Point{%d:%s}" p.srid
        (String.concat ", " (List.map string_of_float (point_coordinates p)))
  | Date d -> Temporal.Date.to_string d
  | Time t -> Temporal.Time.to_string t
  | DateTime dt -> Temporal.DateTime.to_string dt
  | Duration d -> Temporal.Duration.to_string d
  | Vector v ->
      Printf.sprintf "Vector<%s:%d>"
        (vector_dtype_to_string v.dtype)
        (vector_length v)
  | Unsupported u -> Printf.sprintf "UnsupportedType<%s>" u.name
  | Broken b -> Printf.sprintf "<broken: %s>" b.error
