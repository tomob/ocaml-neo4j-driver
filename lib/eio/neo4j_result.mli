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

val check_keys : t -> 'a Decode.t -> (unit, Errors.t) result
(** Check that [decoder] can find every field it requires (its [Decode.aliases]) in the result's
    field names. Extra result fields are allowed; a missing required field or a duplicate result
    field name is an [Errors.Decode_error]. Fields read with [Decode.field_opt] or [Decode.field_or]
    are optional and are not required. RUN already reports the field names, so this can reject a
    wrong query/decoder pair before any record is pulled. *)

val next : t -> (Values.t list option, Errors.t) result
(** The next record, or [None] once the stream is exhausted. *)

val next_as : t -> 'a Decode.t -> ('a option, Errors.t) result
(** Like {!next}, but decode the record with [decoder]. Field names come from the result's RUN
    metadata, so decoding is by name, not by position. The record is consumed even when decoding
    fails; the rest of the stream stays readable (drain it with {!consume}). The
    server-failure/consumed-result behaviour is exactly that of {!next}. *)

val peek : t -> (Values.t list option, Errors.t) result
(** The next record without advancing past it. *)

val fetch : ?n:int -> t -> (Values.t list list, Errors.t) result
(** Up to [n] records (all remaining when [n] is omitted). *)

val values : t -> (Values.t list list, Errors.t) result
(** All remaining records. *)

val list : t -> (Values.t list list, Errors.t) result
(** All remaining records, fetched in a single PULL ([n = -1]) — the TestKit
    [Optimization:ResultListFetchAll] behaviour of the idiomatic [list()]: any already-buffered
    records are consumed first and the rest pulled at once, instead of batch by batch with the
    configured fetch size. *)

val data : t -> ((string * Values.t) list list, Errors.t) result
(** All remaining records, each paired with its field names. A record whose number of values does
    not match the number of field names is a [Errors.Broken_record_error]. *)

val decode_all : t -> 'a Decode.t -> ('a list, Errors.t) result
(** All remaining records, decoded with [decoder]. On a decode failure the rest of the stream is
    discarded and the error names the 1-based record number. *)

val consume : t -> (Summary.t, Errors.t) result
(** Drain the stream and return its summary. *)

val single : t -> (Values.t list, Errors.t) result
(** The single remaining record; an error unless exactly one. *)

val decode_single : t -> 'a Decode.t -> ('a, Errors.t) result
(** Like {!single}, decoded with [decoder]. *)

val single_optional : t -> (Values.t list option * string list, Errors.t) result
(** Expect at most one record. Zero records is [Ok (None, [])]; one is [Ok (Some _, [])]; more than
    one returns the first record together with a warning (draining the rest of the stream). *)

val decode_single_optional : t -> 'a Decode.t -> ('a option * string list, Errors.t) result
(** Like {!single_optional}, with the record decoded by [decoder]. *)
