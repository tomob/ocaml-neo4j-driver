(* An immutable set of bookmark string values, kept in first-seen order
   (duplicates removed) so that what the user passes is what goes on the wire.
   See bookmarks.mli. *)

type t = string list

let empty = []
let is_empty = function [] -> true | _ -> false
let singleton bookmark = [ bookmark ]

(* The given bookmarks with duplicates removed, preserving first-seen order. *)
let of_list bookmarks =
  let seen = Hashtbl.create 8 in
  List.filter
    (fun bookmark ->
      if Hashtbl.mem seen bookmark then false
      else begin
        Hashtbl.add seen bookmark ();
        true
      end)
    bookmarks

let to_list bookmarks = bookmarks

(* The union of two sets: [a] followed by [b]'s elements not already in [a]. *)
let union a b = a @ List.filter (fun bookmark -> not (List.mem bookmark a)) b

(* [a] without the elements of [b], preserving [a]'s order. *)
let diff a b = List.filter (fun bookmark -> not (List.mem bookmark b)) a

let add bookmark bookmarks =
  if List.mem bookmark bookmarks then bookmarks else bookmarks @ [ bookmark ]

let mem bookmark = List.mem bookmark

(* Set equality: the same elements in any order. *)
let equal a b =
  List.length a = List.length b && List.for_all (fun bookmark -> List.mem bookmark b) a
