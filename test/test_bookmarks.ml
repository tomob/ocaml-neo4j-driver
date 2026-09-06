open Neodriver
open Alcotest

let of_list () =
  let a = Bookmarks.of_list [ "bm2"; "bm1"; "bm2"; "bm3" ] in
  check (list string) "dedupe keeps first-seen order" [ "bm2"; "bm1"; "bm3" ] (Bookmarks.to_list a);
  let empty = Bookmarks.of_list [] in
  check bool "empty from []" true (Bookmarks.is_empty empty);
  check bool "non-empty" false (Bookmarks.is_empty a)

let singleton () =
  let a = Bookmarks.singleton "bm1" in
  check bool "not empty" false (Bookmarks.is_empty a);
  check (list string) "value" [ "bm1" ] (Bookmarks.to_list a)

let union () =
  let a = Bookmarks.of_list [ "bm1"; "bm3" ] in
  let b = Bookmarks.of_list [ "bm2"; "bm3" ] in
  check (list string) "union appends b's new elements" [ "bm1"; "bm3"; "bm2" ]
    (Bookmarks.to_list (Bookmarks.union a b));
  check bool "union with empty" true (Bookmarks.equal a (Bookmarks.union a Bookmarks.empty));
  check bool "union is idempotent on itself" true (Bookmarks.equal a (Bookmarks.union a a));
  check bool "union is commutative" true
    (Bookmarks.equal (Bookmarks.union a b) (Bookmarks.union b a))

let diff () =
  let a = Bookmarks.of_list [ "bm1"; "bm2"; "bm3" ] in
  let b = Bookmarks.of_list [ "bm2"; "bm4" ] in
  check (list string) "diff removes shared only" [ "bm1"; "bm3" ]
    (Bookmarks.to_list (Bookmarks.diff a b));
  check bool "diff of a with itself" true (Bookmarks.is_empty (Bookmarks.diff a a));
  check bool "diff by empty leaves intact" true
    (Bookmarks.equal a (Bookmarks.diff a Bookmarks.empty));
  check bool "diff empty by anything is empty" true
    (Bookmarks.is_empty (Bookmarks.diff Bookmarks.empty a))

let add_mem () =
  let a = Bookmarks.empty in
  check bool "mem on empty" false (Bookmarks.mem "bm1" a);
  let a = Bookmarks.add "bm1" a in
  let a = Bookmarks.add "bm1" a in
  check (list string) "add dedupes" [ "bm1" ] (Bookmarks.to_list a);
  check bool "mem after add" true (Bookmarks.mem "bm1" a);
  let a = Bookmarks.add "bm0" a in
  check (list string) "add appends" [ "bm1"; "bm0" ] (Bookmarks.to_list a)

let equal () =
  check bool "equal canonical forms" true
    (Bookmarks.equal (Bookmarks.of_list [ "bm2"; "bm1" ]) (Bookmarks.of_list [ "bm1"; "bm2" ]));
  check bool "order-independent equal" true
    (Bookmarks.equal (Bookmarks.of_list [ "a"; "b" ]) (Bookmarks.of_list [ "b"; "a" ]));
  check bool "different sets differ" false
    (Bookmarks.equal (Bookmarks.of_list [ "a" ]) Bookmarks.empty)

let tests =
  [
    ("[Bookmarks] of_list", [ test_case "dedupe, first-seen order" `Quick of_list ]);
    ("[Bookmarks] singleton", [ test_case "value" `Quick singleton ]);
    ("[Bookmarks] union", [ test_case "merge" `Quick union ]);
    ("[Bookmarks] diff", [ test_case "subtract" `Quick diff ]);
    ("[Bookmarks] add/mem", [ test_case "add and membership" `Quick add_mem ]);
    ("[Bookmarks] equal", [ test_case "order-independent" `Quick equal ]);
  ]
