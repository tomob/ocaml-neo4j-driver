(* Retaining a result: a lazy Neo4j_result.t belongs to its transaction's
   connection, so materialize it with Neo4jResult.list *inside* the read
   transaction, then use the plain values in later transactions. Here the names
   of all Person nodes are read once and each is linked to a Company in its own
   managed write transaction. Expects some :Person nodes to exist. *)

open Neodriver

let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let driver_error = function Ok value -> Ok value | Error error -> Error (Session.Driver error)

let check = function
  | Ok () -> ()
  | Error (Session.Driver error) -> failwith (Errors.to_string error)
  | Error Session.Client -> failwith "the unit of work aborted"

let person_names session =
  let names = ref [] in
  let work tx =
    let* result =
      Tx.run tx ~hydration:(Common.hydration session)
        ~query:"MATCH (a:Person) RETURN a.name AS name" ~parameters:[]
      |> driver_error
    in
    let+ rows = Neo4jResult.list result |> driver_error in
    names := List.filter_map (function [ Values.String name ] -> Some name | _ -> None) rows
  in
  check (Session.execute_read session work);
  !names

let employ session company name =
  let work tx =
    let* result =
      Tx.run tx ~hydration:(Common.hydration session)
        ~query:
          "MATCH (emp:Person {name: $name}) MERGE (com:Company {name: $company}) MERGE \
           (emp)-[:WORKS_FOR]->(com)"
        ~parameters:[ ("name", Values.String name); ("company", Values.String company) ]
      |> driver_error
    in
    let* _ = Neo4jResult.consume result |> driver_error in
    Ok ()
  in
  check (Session.execute_write session work)

let () =
  Common.with_session (fun session ->
      let company = "Acme" in
      let names = person_names session in
      List.iter (employ session company) names;
      Printf.printf "linked %d person(s) to %s\n" (List.length names) company)
