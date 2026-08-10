(* A micro-benchmark for reading a large result: reports the elapsed time and
   the allocation. Run from the repository root with the number of records
   (requires a live Neo4j via the NEO4J_* environment variables):

     dune exec examples/bench.exe -- 20000
*)

open Neodriver

let () =
  let n =
    match Sys.argv with
    | [| _; n |] -> ( match int_of_string_opt n with Some n -> n | None -> 100000)
    | _ -> 100000
  in
  let query = Printf.sprintf "UNWIND RANGE(0, %d) AS i RETURN i" n in
  let words_to_mib w = float_of_int w *. 8.0 /. (1024. *. 1024.) in
  let bytes_to_mib b = b /. (1024. *. 1024.) in
  Common.with_session (fun session ->
      Gc.full_major ();
      let live_before = (Gc.quick_stat ()).Gc.live_words in
      let allocated_before = Gc.allocated_bytes () in
      let t0 = Unix.gettimeofday () in
      match Session.run session ~query ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.values result with
          | Ok records ->
              let seconds = Unix.gettimeofday () -. t0 in
              Gc.full_major ();
              let allocated = Gc.allocated_bytes () -. allocated_before in
              let live = (Gc.quick_stat ()).Gc.live_words in
              Printf.printf
                "n=%d records=%d time=%.3fs allocated=%.1f MiB live=%.1f MiB (baseline %.1f MiB)\n"
                n (List.length records) seconds (bytes_to_mib allocated) (words_to_mib live)
                (words_to_mib live_before)
          | Error e -> failwith (Errors.to_string e))
      | Error e -> failwith (Errors.to_string e))
