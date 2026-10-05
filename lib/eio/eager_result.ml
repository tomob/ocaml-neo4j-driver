(* An in-memory (eager) query result: the field names, every record and the
   final summary. [of_result] drains a lazily-streamed [Neo4j_result.t] into a
   [t], mirroring the Python driver's [Result.to_eager_result]. *)

open Neodriver_core

type t = { keys : string list; records : Values.t list list; summary : Summary.t }

let of_result result =
  let keys = Neo4j_result.keys result in
  let ( let* ) = Result.bind in
  let* records = Neo4j_result.values result in
  let* summary = Neo4j_result.consume result in
  Ok { keys; records; summary }
