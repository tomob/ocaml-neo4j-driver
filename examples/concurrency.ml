(* Concurrency on Eio fibers: the driver is shared, and each fiber runs its own
   session/transaction through Driver.execute_query. No separate async API is
   needed — Eio fibers provide the concurrency. *)

open Neodriver

let or_fail = function Ok value -> value | Error error -> failwith (Errors.to_string error)

let query driver i =
  Driver.execute_query driver ~query:"RETURN $i AS i"
    ~parameters:[ ("i", Values.Int (Int64.of_int i)) ]
  |> or_fail
  |> fun eager -> eager.records

let int_of_row = function
  | [ [ Values.Int n ] ] -> Int64.to_int n
  | _ -> failwith "expected a single integer"

let run driver sw =
  let queries = List.init 8 (fun i -> Eio.Fiber.fork_promise ~sw (fun () -> query driver i)) in
  let values = List.map Eio.Promise.await_exn queries |> List.map int_of_row in
  Printf.printf "%d parallel queries, sum = %d\n" (List.length values)
    (List.fold_left ( + ) 0 values)

let () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let driver = Common.connect net clock sw in
          Fun.protect ~finally:(fun () -> Driver.close driver) (fun () -> run driver sw)))
