open Neodriver
open Alcotest

let empty_update_is_a_noop () =
  let calls = ref 0 in
  let manager =
    Bookmark_manager.neo4j_bookmark_manager ~initial_bookmarks:(Bookmarks.of_list [ "bm1" ])
      ~consumer:(fun _ -> incr calls)
      ()
  in
  manager.update_bookmarks ~previous:(Bookmarks.of_list [ "bm1" ]) ~new_bookmarks:Bookmarks.empty;
  check int "consumer not called on empty update" 0 !calls;
  check (list string) "state unchanged" [ "bm1" ] (Bookmarks.to_list (manager.get_bookmarks ()))

let update_diffs_previous_and_unions_new () =
  let manager =
    Bookmark_manager.neo4j_bookmark_manager
      ~initial_bookmarks:(Bookmarks.of_list [ "bm1"; "bm2" ])
      ()
  in
  manager.update_bookmarks
    ~previous:(Bookmarks.of_list [ "bm1"; "bm3" ])
    ~new_bookmarks:(Bookmarks.of_list [ "bm4" ]);
  check (list string) "previous removed, new added" [ "bm2"; "bm4" ]
    (Bookmarks.to_list (manager.get_bookmarks ()));
  check bool "update idempotent" true
    (Bookmarks.equal (Bookmarks.of_list [ "bm2"; "bm4" ]) (manager.get_bookmarks ()))

let supplier_enriches_without_storing () =
  (* The supplier only enriches [get_bookmarks]; its result never enters the
     manager's own state. *)
  let supply = ref true in
  let manager =
    Bookmark_manager.neo4j_bookmark_manager
      ~supplier:(fun () -> if !supply then Bookmarks.of_list [ "extra" ] else Bookmarks.empty)
      ()
  in
  check (list string) "get unions supplier" [ "extra" ]
    (Bookmarks.to_list (manager.get_bookmarks ()));
  manager.update_bookmarks ~previous:(Bookmarks.of_list [ "extra" ])
    ~new_bookmarks:(Bookmarks.of_list [ "bm1" ]);
  supply := false;
  check (list string) "supplied bookmarks not stored" [ "bm1" ]
    (Bookmarks.to_list (manager.get_bookmarks ()))

let consumer_notified_with_snapshot () =
  let calls = ref [] in
  let manager =
    Bookmark_manager.neo4j_bookmark_manager ~initial_bookmarks:(Bookmarks.of_list [ "a" ])
      ~consumer:(fun snapshot -> calls := Bookmarks.to_list snapshot :: !calls)
      ()
  in
  manager.update_bookmarks ~previous:(Bookmarks.of_list [ "a" ])
    ~new_bookmarks:(Bookmarks.of_list [ "b" ]);
  manager.update_bookmarks ~previous:(Bookmarks.of_list [ "b" ])
    ~new_bookmarks:(Bookmarks.of_list [ "c" ]);
  manager.update_bookmarks ~previous:(Bookmarks.of_list [ "c" ]) ~new_bookmarks:Bookmarks.empty;
  check (list (list string)) "consumer got each post-update snapshot" [ [ "c" ]; [ "b" ] ] !calls

let initial_bookmarks_seed_state () =
  let manager =
    Bookmark_manager.neo4j_bookmark_manager
      ~initial_bookmarks:(Bookmarks.of_list [ "first_bm"; "adb:bm1" ])
      ()
  in
  check (list string) "initial bookmarks in first-seen order" [ "first_bm"; "adb:bm1" ]
    (Bookmarks.to_list (manager.get_bookmarks ()));
  let no_initial = Bookmark_manager.neo4j_bookmark_manager () in
  check bool "empty default initial" true (Bookmarks.is_empty (no_initial.get_bookmarks ()))

let shared_across_get_and_update () =
  (* A manager shared by two sequential sessions chains their commits: the
     second session's transaction seeds from the first session's commit. *)
  let manager = Bookmark_manager.neo4j_bookmark_manager () in
  manager.update_bookmarks ~previous:Bookmarks.empty ~new_bookmarks:(Bookmarks.of_list [ "bm1" ]);
  check (list string) "second session seeds from first commit" [ "bm1" ]
    (Bookmarks.to_list (manager.get_bookmarks ()));
  manager.update_bookmarks ~previous:(Bookmarks.of_list [ "bm1" ])
    ~new_bookmarks:(Bookmarks.of_list [ "bm2" ]);
  check (list string) "bookmark replaced by the newer one" [ "bm2" ]
    (Bookmarks.to_list (manager.get_bookmarks ()))

let tests =
  [
    ("[Bookmark_manager] empty update", [ test_case "no-op" `Quick empty_update_is_a_noop ]);
    ( "[Bookmark_manager] update",
      [ test_case "difference + union" `Quick update_diffs_previous_and_unions_new ] );
    ( "[Bookmark_manager] supplier",
      [ test_case "enriches without storing" `Quick supplier_enriches_without_storing ] );
    ( "[Bookmark_manager] consumer",
      [ test_case "notified with snapshot" `Quick consumer_notified_with_snapshot ] );
    ( "[Bookmark_manager] initial bookmarks",
      [ test_case "seeds state" `Quick initial_bookmarks_seed_state ] );
    ( "[Bookmark_manager] chaining",
      [ test_case "sessions share a manager" `Quick shared_across_get_and_update ] );
  ]
