(* Bookmark managers: a record of closures so custom managers plug in directly,
   with a built-in thread-safe implementation. See bookmark_manager.mli. *)

type t = {
  get_bookmarks : unit -> Bookmarks.t;
  update_bookmarks : previous:Bookmarks.t -> new_bookmarks:Bookmarks.t -> unit;
}

(* The built-in manager: a set of bookmarks under a lock. [get_bookmarks]
   unions the current set with the supplier's result (called outside the lock)
   without storing it; [update_bookmarks] removes the [previous] bookmarks that
   were sent and adds [new_bookmarks], notifying the consumer (outside the
   lock) with the resulting snapshot. Mirrors the Python
   AsyncNeo4jBookmarkManager. *)
let neo4j_bookmark_manager ?(initial_bookmarks = Bookmarks.empty) ?supplier ?consumer () =
  let lock = Mutex.create () in
  let bookmarks = ref initial_bookmarks in
  let get_bookmarks () =
    let own = Mutex.protect lock (fun () -> !bookmarks) in
    match supplier with Some supplier -> Bookmarks.union own (supplier ()) | None -> own
  in
  let update_bookmarks ~previous ~new_bookmarks =
    if Bookmarks.is_empty new_bookmarks then ()
    else
      let snapshot =
        Mutex.protect lock (fun () ->
            bookmarks := Bookmarks.union (Bookmarks.diff !bookmarks previous) new_bookmarks;
            !bookmarks)
      in
      match consumer with Some consumer -> consumer snapshot | None -> ()
  in
  { get_bookmarks; update_bookmarks }
