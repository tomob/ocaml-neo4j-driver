(* Deadlines for the Neo4j driver.

   Modelled on the Neo4j Python driver's _deadline.py. A deadline is an
   absolute monotonic time with an optional original timeout, providing one
   unified timing mechanism for connection acquisition, I/O, handshake and
   transactions. *)

type t = { deadline : float; original_timeout : float option }

let now () = Int64.to_float (Mtime_clock.now_ns ()) /. 1_000_000_000.

let create = function
  | None -> { deadline = infinity; original_timeout = None }
  | Some timeout ->
      if timeout = infinity then
        { deadline = infinity; original_timeout = None }
      else { deadline = now () +. timeout; original_timeout = Some timeout }

let to_timeout t =
  if t.deadline = infinity then None else Some (max 0.0 (t.deadline -. now ()))

let expired t = to_timeout t = Some 0.0
let is_set t = t.deadline <> infinity
let original_timeout t = t.original_timeout

let to_string t =
  match t.original_timeout with
  | Some timeout -> Printf.sprintf "Deadline(timeout=%g)" timeout
  | None -> "Deadline(timeout=none)"

(* The earliest of the given deadlines; [None] if none is set. *)
let merge deadlines =
  match List.filter is_set deadlines with
  | [] -> None
  | d :: rest ->
      Some
        (List.fold_left
           (fun acc x -> if x.deadline < acc.deadline then x else acc)
           d rest)

(* The earliest deadline among the given timeouts (unset timeouts ignored). *)
let merge_and_timeouts timeouts = merge (List.map create timeouts)
