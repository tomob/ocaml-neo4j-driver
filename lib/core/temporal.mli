(** Temporal value types for the Neo4j driver.

    See temporal.ml for the implementation. Named time zones are resolved through the IANA time zone
    database embedded in [Timedesc] (timedesc-tzdb, 1970-2040); unknown zones fall back to opaque
    handling ([None]). *)

type tz =
  | Offset of int
  | Zone_name of string
      (** A time zone: a fixed UTC offset in seconds, or an IANA zone name (handled opaquely). *)

type date = int
(** A date as days since 1970-01-01 (proleptic Gregorian). *)

module Date : sig
  type t = date
  (** A date (see {!type:date}). *)

  val of_days : int -> t
  (** A date from days since 1970-01-01. *)

  val to_days : t -> int
  (** Days since 1970-01-01. *)

  val of_ymd : int * int * int -> t option
  (** A date from (year, month, day); [None] if out of range. *)

  val to_ymd : t -> int * int * int
  (** The (year, month, day) of a date. *)

  val to_ordinal : t -> int
  (** Days since 0001-01-01 (proleptic Gregorian ordinal). *)

  val of_ordinal : int -> t
  (** A date from a proleptic Gregorian ordinal. *)

  val add_days : int -> t -> t
  (** Add a number of days. *)

  val diff_days : t -> t -> int
  (** Difference in days ([a - b]). *)

  val add_months : int -> t -> t option
  (** Add a number of months, clamping the day to the month length; [None] if the result is out of
      the supported year range. *)

  val compare : t -> t -> int
  (** Compare two dates. *)

  val equal : t -> t -> bool
  (** Whether two dates are equal. *)

  val to_iso8601 : t -> string
  (** Format as "YYYY-MM-DD". *)

  val of_iso8601 : string -> t option
  (** Parse "YYYY-MM-DD"; [None] if invalid. *)

  val to_string : t -> string
  (** Alias for {!to_iso8601}. *)
end

type time = { ticks : int64; tz_offset_seconds : int option }
(** A time of day as nanoseconds since midnight, with an optional UTC offset in seconds. *)

module Time : sig
  type t = time
  (** A time of day (see {!type:time}). *)

  val of_ticks : ?tz_offset_seconds:int -> int64 -> t
  (** A time from nanoseconds since midnight and an optional offset. *)

  val to_ticks : t -> int64
  (** Nanoseconds since midnight. *)

  val tz_offset_seconds : t -> int option
  (** The UTC offset in seconds, if any. *)

  val of_hms_ns : ?tz_offset_seconds:int -> int -> int -> int -> int -> t option
  (** A time from (hour, minute, second, nanosecond); [None] if out of range. *)

  val to_hms_ns : t -> int * int * int * int
  (** The (hour, minute, second, nanosecond) of a time. *)

  val add : int64 -> t -> t
  (** Add nanoseconds. *)

  val sub : int64 -> t -> t
  (** Subtract nanoseconds. *)

  val compare : t -> t -> int
  (** Compare two times by their ticks. *)

  val equal : t -> t -> bool
  (** Whether two times are equal (including offset). *)

  val to_iso8601 : t -> string
  (** Format as "HH:MM:SS[.fff...][+HH:MM]". *)

  val of_iso8601 : string -> t option
  (** Parse "HH:MM:SS[.fraction][Z|+HH:MM]"; [None] if invalid. *)

  val to_string : t -> string
  (** Alias for {!to_iso8601}. *)
end

type duration = { months : int; days : int; seconds : int64; nanoseconds : int }
(** A duration with independent months, days, seconds and nanoseconds. *)

module Duration : sig
  type t = duration
  (** A duration (see {!type:duration}). *)

  val of_fields : months:int -> days:int -> seconds:int64 -> nanoseconds:int -> t
  (** A duration from its components. *)

  val to_fields : t -> int * int * int64 * int
  (** The (months, days, seconds, nanoseconds) of a duration. *)

  val neg : t -> t
  (** The negated duration. *)

  val add : t -> t -> t
  (** Element-wise addition, normalising sub-second nanoseconds. *)

  val sub : t -> t -> t
  (** Element-wise subtraction, normalising sub-second nanoseconds. *)

  val compare : t -> t -> int
  (** Compare two durations. *)

  val equal : t -> t -> bool
  (** Whether two durations are equal. *)

  val to_total_seconds : t -> int64
  (** Total seconds, approximating months as 30 days. *)

  val to_iso8601 : t -> string
  (** Format as an ISO 8601 duration ("PnYnMnDTnHnMnS"). *)

  val of_iso8601 : string -> t option
  (** Parse an ISO 8601 duration; [None] if invalid. *)

  val to_span : t -> Ptime.Span.t option
  (** Convert to a [Ptime.Span.t]; [None] if the duration has months (spans cannot represent them).
  *)

  val of_span : Ptime.Span.t -> t
  (** A duration from a [Ptime.Span.t] (months = 0). *)

  val to_string : t -> string
  (** Alias for {!to_iso8601}. *)
end

type datetime = { epoch_seconds : int64; nanoseconds : int; tz : tz option }
(** A point in time as UTC epoch seconds + sub-second nanoseconds, with an optional time zone. Named
    zones are handled opaquely. *)

module DateTime : sig
  type t = datetime
  (** A point in time (see {!type:datetime}). *)

  val of_epoch_seconds : ?tz:tz -> int64 -> int -> t
  (** A datetime from UTC epoch seconds and sub-second nanoseconds. *)

  val to_epoch_seconds : t -> int64 * int
  (** The (epoch seconds, nanoseconds) of a datetime. *)

  val tz : t -> tz option
  (** The time zone, if any. *)

  val of_ymd_hms : ?tz:tz -> int * int * int -> int * int * int -> int -> t option
  (** A datetime from a wall clock and optional time zone. Named zones are resolved through the IANA
      time zone database embedded in [Timedesc]; [None] for unknown zones or out-of-range values. *)

  val to_ymd_hms : t -> (int * int * int) * (int * int * int) * int
  (** The wall clock ((y, m, d), (h, m, s), nanoseconds) in the datetime's zone. For named zones the
      offset at the instant is resolved from the embedded IANA database. *)

  val offset_seconds : t -> int option
  (** The UTC offset in seconds at the datetime's instant: the fixed offset for [Offset] zones,
      resolved from the embedded IANA database for [Zone_name] zones ([None] if the zone is
      unknown). *)

  val add : Duration.t -> t -> t option
  (** Add a duration; [None] for named zones. *)

  val sub : Duration.t -> t -> t option
  (** Subtract a duration; [None] for named zones. *)

  val diff : t -> t -> Duration.t option
  (** Difference [a - b] as a duration; [None] if either has a named zone. *)

  val compare : t -> t -> int
  (** Compare two datetimes by their instant. *)

  val equal : t -> t -> bool
  (** Whether two datetimes are the same instant. *)

  val to_iso8601 : t -> string
  (** Format as "YYYY-MM-DDTHH:MM:SS[.fff...][+HH:MM]". *)

  val of_iso8601 : string -> t option
  (** Parse an ISO 8601 datetime; [None] if invalid or the zone is named. *)

  val to_ptime : t -> Ptime.t option
  (** Convert to a [Ptime.t]; [None] for named zones. *)

  val of_ptime : ?tz:tz -> Ptime.t -> t
  (** A datetime from a [Ptime.t] (UTC). *)

  val to_string : t -> string
  (** Alias for {!to_iso8601}. *)
end
