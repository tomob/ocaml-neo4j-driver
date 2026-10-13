(* The read/write split: a managed write transaction creates a Person and a
   managed read transaction fetches its id, both in the same session. *)

open Neodriver

let check = function
  | Ok () -> ()
  | Error (Session.Driver error) -> failwith (Errors.to_string error)
  | Error Session.Client -> failwith "the unit of work aborted"

let add_person session name =
  let work tx =
    match
      Tx.run tx ~hydration:(Common.hydration session) ~query:"CREATE (a:Person {name: $name})"
        ~parameters:[ ("name", Values.String name) ]
    with
    | Ok result -> (
        match Neo4jResult.consume result with
        | Ok _ -> Ok ()
        | Error error -> Error (Session.Driver error))
    | Error error -> Error (Session.Driver error)
  in
  Session.execute_write session work

let person_id session name =
  let id = ref None in
  let work tx =
    match
      Tx.run tx ~hydration:(Common.hydration session)
        ~query:"MATCH (a:Person {name: $name}) RETURN id(a)"
        ~parameters:[ ("name", Values.String name) ]
    with
    | Ok result -> (
        match Neo4jResult.single result with
        | Ok [ Values.Int n ] ->
            id := Some n;
            Ok ()
        | Ok _ -> Error Session.Client
        | Error error -> Error (Session.Driver error))
    | Error error -> Error (Session.Driver error)
  in
  match Session.execute_read session work with
  | Ok () -> ( match !id with Some n -> n | None -> failwith "no id")
  | Error (Session.Driver error) -> failwith (Errors.to_string error)
  | Error Session.Client -> failwith "the query did not return an id"

let () =
  Common.with_session (fun session ->
      let name = "Alice" in
      check (add_person session name);
      Printf.printf "created %s with id %Ld\n" name (person_id session name))
