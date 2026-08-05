(* Deadlines for the Neo4j driver.

   A deadline is an absolute monotonic time with an optional original
   timeout, providing one unified timing mechanism for connection
   acquisition, I/O, handshake and transactions. See deadline.ml for the
   implementation. *)

type t
(** An absolute deadline based on a monotonic clock. *)

val create : float option -> t
(** Create a deadline from an optional timeout in seconds; [None] means no deadline (never expires).
*)

val to_timeout : t -> float option
(** Remaining time in seconds until the deadline, or [None] if unset. *)

val expired : t -> bool
(** Whether the deadline has already passed. *)

val is_set : t -> bool
(** Whether a deadline is set ([true]) or not ([false]). *)

val original_timeout : t -> float option
(** The original timeout used to create the deadline. *)

val to_string : t -> string
(** Render the deadline as a string. *)

val merge : t list -> t option
(** The earliest of the given deadlines, or [None] if none is set. *)

val merge_and_timeouts : float option list -> t option
(** The earliest deadline among the given timeouts; [None] entries are ignored. *)
