(** A lazily-streamed query result. [next]/[peek]/[fetch] iterate the records (pulling from the
    connection on demand); [consume] drains the stream and returns its summary;
    [single]/[single_optional] enforce cardinality.

    A deferred server failure is surfaced as [Error] once the buffered records before it have been
    consumed. *)

open Neodriver_core

type t
(** A lazily-streamed result over a connection. *)

val make :
  ?fetch_size:int -> ?query:string -> ?parameters:(string * Values.t) list -> Conn.stream -> t
(** Wrap a stream (as produced by [Session.run] or [Tx.run]) into a [t]. [fetch_size] is the number
    of records pulled per PULL when the buffer runs out (default 1000). *)

val stream : t -> Conn.stream
(** The underlying stream (for the summary, buffered records and raw pull). *)

val keys : t -> string list
(** The field names of the returned records. *)

val next : t -> (Values.t list option, Errors.t) result
(** The next record, or [None] once the stream is exhausted. *)

val peek : t -> (Values.t list option, Errors.t) result
(** The next record without advancing past it. *)

val fetch : ?n:int -> t -> (Values.t list list, Errors.t) result
(** Up to [n] records (all remaining when [n] is omitted). *)

val values : t -> (Values.t list list, Errors.t) result
(** All remaining records. *)

val data : t -> ((string * Values.t) list list, Errors.t) result
(** All remaining records, each paired with its field names. *)

val consume : t -> (Summary.t, Errors.t) result
(** Drain the stream and return its summary. *)

val single : t -> (Values.t list, Errors.t) result
(** The single remaining record; an error unless exactly one. *)

val single_optional : t -> (Values.t list option, Errors.t) result
(** The single remaining record, or [None]; an error if more than one. *)
