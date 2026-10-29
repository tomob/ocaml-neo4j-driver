(* An in-memory (eager) query result: the field names, every record and the
   final summary. [of_result] drains a lazily-streamed [Neo4j_result.t] into a
   [t], mirroring the Python driver's [Result.to_eager_result]. *)

open Neodriver_core

let ( let* ) = Result.bind

type t = { keys : string list; records : Values.t list list; summary : Summary.t }

let of_result result =
  let keys = Neo4j_result.keys result in
  let ( let* ) = Result.bind in
  let* records = Neo4j_result.values result in
  let* summary = Neo4j_result.consume result in
  Ok { keys; records; summary }

let check_keys t decoder = Decode.check_keys ~keys:t.keys decoder

let decode_all t decoder =
  let* () = check_keys t decoder in
  let rec collect index acc = function
    | [] -> Ok (List.rev acc)
    | record :: rest -> (
        let* row = Decode.row_of_values ~keys:t.keys record in
        match Decode.decode_row decoder row with
        | Ok value -> collect (index + 1) (value :: acc) rest
        | Error (Errors.Decode_error message) ->
            Error (Errors.Decode_error (Printf.sprintf "record %d: %s" index message))
        | Error error -> Error error)
  in
  collect 1 [] t.records
