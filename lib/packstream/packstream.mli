(** PackStream — binary serialization for the Neo4j Bolt protocol.

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
      (** A PackStream value; [Structure] carries a tag byte and its fields. *)

type error =
  | Unexpected_end_of_data
  | Unknown_marker of int
  | Map_key_not_string
  | Depth_limit_exceeded of int  (** Decode failures reported by {!unpack}. *)

type limits = { max_depth : int }
(** Limits for {!unpack}, guarding against stack overflow on deeply nested values. *)

val default_limits : limits
(** Default [limits]: [max_depth = 256]. *)

val pack : value -> Bytes.t
(** Serialize a [value] into its PackStream byte representation. *)

val unpack : ?limits:limits -> Bytes.t -> (value, error) result
(** Deserialize a [value] from PackStream [bytes], subject to the given [limits] (defaults to
    {!default_limits}). *)

val error_to_string : error -> string
(** Render a decode [error] as a human-readable message. *)

val to_string : value -> string
(** Render a [value] as a human-readable string. *)
