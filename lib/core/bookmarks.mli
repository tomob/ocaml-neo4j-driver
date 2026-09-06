(** An immutable set of bookmark string values.

    Bookmarks causally chain sessions: a bookmark is an opaque token representing the database state
    after a write; passing the bookmarks of one session (or a shared [Bookmark_manager]) into the
    next session's configuration guarantees the second session observes the first session's writes.
    Modelled on the Python driver's [Bookmarks] container (api.py): a set with union semantics —
    kept in first-seen order (duplicates removed) so that what a caller passes is what goes on the
    wire.

    Phase A8: the [Bookmark_manager] module builds on this type. *)

type t

val empty : t
(** The empty bookmark set. *)

val is_empty : t -> bool
(** Whether the set contains no bookmarks. *)

val singleton : string -> t
(** A set with the single [bookmark]. *)

val of_list : string list -> t
(** A set from [bookmarks]: duplicates are removed, the first-seen order is preserved. *)

val to_list : t -> string list
(** The raw bookmark values in first-seen order (the Python [raw_values]). *)

val union : t -> t -> t
(** The union of two sets ([a + b]): [a] followed by [b]'s new elements. *)

val diff : t -> t -> t
(** [a] without the elements of [b] ([a - b]). *)

val add : string -> t -> t
(** [bookmark] added to the set. *)

val mem : string -> t -> bool
(** Whether [bookmark] is in the set. *)

val equal : t -> t -> bool
(** Whether two sets contain the same bookmarks (order-independent). *)
