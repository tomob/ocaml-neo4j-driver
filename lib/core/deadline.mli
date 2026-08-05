(* Deadlines for the Neo4j driver.

   A deadline is an absolute monotonic time with an optional original
   timeout, providing one unified timing mechanism for connection
   acquisition, I/O, handshake and transactions. See deadline.ml for the
   implementation. *)

type t

val create : float option -> t
val to_timeout : t -> float option
val expired : t -> bool
val is_set : t -> bool
val original_timeout : t -> float option
val to_string : t -> string
val merge : t list -> t option
val merge_and_timeouts : float option list -> t option
