(* Rich value types for the Neo4j driver.

   See values.ml for the implementation. *)

type node = {
  element_id : string;
  legacy_id : int option;
  labels : string list;
  properties : (string * t) list;
}
(** A graph node. *)

and relationship = {
  element_id : string;
  legacy_id : int option;
  rel_type : string;
  start : string;
  end_ : string;
  start_legacy_id : int option;
  end_legacy_id : int option;
  properties : (string * t) list;
}
(** A directed relationship with its endpoints' [element_id]s (and legacy ids when known). *)

and unbound_relationship = {
  element_id : string;
  legacy_id : int option;
  rel_type : string;
  properties : (string * t) list;
}
(** A relationship without resolved endpoints (as in a path). *)

and path = { nodes : node list; relationships : relationship list }
(** A path: the ordered nodes and the relationships linking them. *)

and point = { srid : int; x : float; y : float; z : float option }
(** A spatial point with its SRID and coordinates. *)

and vector_dtype = I8 | I16 | I32 | I64 | F32 | F64  (** Element type of a vector. *)

and vector = { dtype : vector_dtype; data : bytes }
(** A big-endian vector of homogeneous elements. *)

and unsupported = { name : string; minimum_protocol_version : int * int; message : string option }
(** A server value type the driver does not understand. *)

and broken = { error : string; raw : Neodriver_packstream.Packstream.value }
(** A value that could not be decoded. *)

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
  | Broken of broken  (** A hydrated value exchanged with the server. *)

val point_x : point -> float
(** The x coordinate of a point. *)

val point_y : point -> float
(** The y coordinate of a point. *)

val point_z : point -> float option
(** The z coordinate of a point, if any. *)

val point_coordinates : point -> float list
(** The coordinates of a point as a list. *)

val point_is_cartesian : point -> bool
(** Whether a point uses a Cartesian SRID. *)

val point_is_wgs84 : point -> bool
(** Whether a point uses a WGS84 SRID. *)

val vector_dtype_size : vector_dtype -> int
(** Number of bytes per element of a vector dtype. *)

val vector_length : vector -> int
(** Number of elements in a vector. *)

val to_string : t -> string
(** Render a value as a human-readable string. *)
