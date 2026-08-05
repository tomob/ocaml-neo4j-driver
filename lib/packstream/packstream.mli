(* PackStream — binary serialization for the Neo4j Bolt protocol.

   See packstream.ml for the implementation. *)

type value =
  | Null
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Bytes of bytes
  | List of value list
  | Map of (string * value) list
  | Structure of int * value list

type error =
  | Unexpected_end_of_data
  | Unknown_marker of int
  | Map_key_not_string
  | Depth_limit_exceeded of int

type limits = { max_depth : int }

val default_limits : limits
val pack : value -> Bytes.t
val unpack : ?limits:limits -> Bytes.t -> (value, error) result
val error_to_string : error -> string
val to_string : value -> string
