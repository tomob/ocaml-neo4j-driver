(** LMT (Local Mean Time) offsets in seconds, keyed by zone name. Used for named-zone instants
    before the embedded database starts (1970). *)

val find : string -> int option
(** The LMT offset (seconds) of a canonical [zone], or [None] if unknown. *)
