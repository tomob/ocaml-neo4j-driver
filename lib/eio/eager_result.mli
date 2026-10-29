(** An in-memory (eager) query result: the field names, every record and the final summary.

    [Driver.execute_query] returns a [t]; {!of_result} drains a lazily-streamed [Neo4j_result.t]
    into one (the Python driver's [Result.to_eager_result]). *)

open Neodriver_core

type t = {
  keys : string list;  (** The field names of the returned records. *)
  records : Values.t list list;  (** All records, each a list of values in field order. *)
  summary : Summary.t;  (** The summary of the query execution. *)
}
(** An in-memory result of a query. *)

val of_result : Neo4j_result.t -> (t, Errors.t) result
(** Drain [result] fully and return its keys, records and summary. *)

val check_keys : t -> 'a Decode.t -> (unit, Errors.t) result
(** Check that [decoder] can find every field it reads in {!keys}; extra keys are allowed, a missing
    or duplicate key is an [Errors.Decode_error]. *)

val decode_all : t -> 'a Decode.t -> ('a list, Errors.t) result
(** Decode every record with [decoder]. On a decode failure the error names the 1-based record
    number. *)
