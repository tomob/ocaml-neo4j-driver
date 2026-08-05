(* Temporal value types for the Neo4j driver.

   See temporal.ml for the implementation. *)

type tz = Offset of int | Zone_name of string
type date = int

module Date : sig
  type t = date

  val of_days : int -> t
  val to_days : t -> int
  val of_ymd : int * int * int -> t option
  val to_ymd : t -> int * int * int
  val to_ordinal : t -> int
  val of_ordinal : int -> t
  val add_days : int -> t -> t
  val diff_days : t -> t -> int
  val add_months : int -> t -> t option
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_iso8601 : t -> string
  val of_iso8601 : string -> t option
  val to_string : t -> string
end

type time = { ticks : int64; tz_offset_seconds : int option }

module Time : sig
  type t = time

  val of_ticks : ?tz_offset_seconds:int -> int64 -> t
  val to_ticks : t -> int64
  val tz_offset_seconds : t -> int option
  val of_hms_ns : ?tz_offset_seconds:int -> int -> int -> int -> int -> t option
  val to_hms_ns : t -> int * int * int * int
  val add : int64 -> t -> t
  val sub : int64 -> t -> t
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_iso8601 : t -> string
  val of_iso8601 : string -> t option
  val to_string : t -> string
end

type duration = { months : int; days : int; seconds : int64; nanoseconds : int }

module Duration : sig
  type t = duration

  val of_fields :
    months:int -> days:int -> seconds:int64 -> nanoseconds:int -> t

  val to_fields : t -> int * int * int64 * int
  val neg : t -> t
  val add : t -> t -> t
  val sub : t -> t -> t
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_total_seconds : t -> int64
  val to_iso8601 : t -> string
  val of_iso8601 : string -> t option
  val to_span : t -> Ptime.Span.t option
  val of_span : Ptime.Span.t -> t
  val to_string : t -> string
end

type datetime = { epoch_seconds : int64; nanoseconds : int; tz : tz option }

module DateTime : sig
  type t = datetime

  val of_epoch_seconds : ?tz:tz -> int64 -> int -> t
  val to_epoch_seconds : t -> int64 * int
  val tz : t -> tz option

  val of_ymd_hms :
    ?tz:tz -> int * int * int -> int * int * int -> int -> t option

  val to_ymd_hms : t -> (int * int * int) * (int * int * int) * int
  val add : Duration.t -> t -> t option
  val sub : Duration.t -> t -> t option
  val diff : t -> t -> Duration.t option
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_iso8601 : t -> string
  val of_iso8601 : string -> t option
  val to_ptime : t -> Ptime.t option
  val of_ptime : ?tz:tz -> Ptime.t -> t
  val to_string : t -> string
end
