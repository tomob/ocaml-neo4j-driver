(* Rich value types for the Neo4j driver.

   See values.ml for the implementation. *)

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
and unsupported = { name : string; minimum_protocol_version : int * int; message : string option }
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

val point_x : point -> float
val point_y : point -> float
val point_z : point -> float option
val point_coordinates : point -> float list
val point_is_cartesian : point -> bool
val point_is_wgs84 : point -> bool
val vector_dtype_size : vector_dtype -> int
val vector_length : vector -> int
val to_string : t -> string
