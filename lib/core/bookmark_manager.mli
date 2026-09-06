(** Bookmark managers: share the bookmarks of committed writes across sessions.

    Sessions created without a manager keep their own bookmarks (the classic
    [Session.last_bookmarks] causal chaining); sessions given a manager seed each transaction with
    the manager's bookmarks and hand the manager every bookmark returned by a successful commit, so
    the manager grows with the driver's writes. Modelled on the Python driver's [BookmarkManager] /
    [AsyncNeo4jBookmarkManager] (_async/bookmark_manager.py).

    The interface is a record of closures so custom managers (e.g. one that round-trips
    supplier/consumer calls to an external process in the TestKit backend) plug in directly;
    [neo4j_bookmark_manager] is the built-in implementation.

    Phase A8: sessions integrate a manager via [Session.config]'s [bookmark_manager] field. *)

type t = {
  get_bookmarks : unit -> Bookmarks.t;
      (** The bookmarks to seed the next transaction with: the manager's own set enriched by its
          [supplier] (if any). Never mutates the manager's state. *)
  update_bookmarks : previous:Bookmarks.t -> new_bookmarks:Bookmarks.t -> unit;
      (** Record [new_bookmarks] returned by a committed transaction: the manager's set becomes
          ([set] without [previous]) plus [new_bookmarks], and its [consumer] (if any) is notified
          with the resulting snapshot. An empty [new_bookmarks] is a no-op. *)
}

val neo4j_bookmark_manager :
  ?initial_bookmarks:Bookmarks.t ->
  ?supplier:(unit -> Bookmarks.t) ->
  ?consumer:(Bookmarks.t -> unit) ->
  unit ->
  t
(** The built-in (Neo4j-style) bookmark manager, the OCaml analogue of the Python
    [AsyncNeo4jBookmarkManager]: a thread-safe set of bookmarks.

    [get_bookmarks] returns the current set unioned with the [supplier]'s result (the supplier is
    called on every access and its bookmarks are not stored). [update_bookmarks] drops the
    [previous] bookmarks (those that were actually sent at the start of the transaction), adds
    [new_bookmarks], and calls the [consumer] (outside the lock) with the resulting snapshot.
    [initial_bookmarks] seeds the set (default empty). Supplier/consumer exceptions propagate to the
    caller. *)
