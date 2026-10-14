(* Transaction metadata and timeout: a managed write transaction carries custom
   metadata (the server records it with the query) and is bounded by a timeout.
   The same options are available on Driver.execute_query. *)

open Neodriver

let check = function
  | Ok () -> ()
  | Error (Session.Driver error) -> failwith (Errors.to_string error)
  | Error Session.Client -> failwith "the transaction aborted"

let () =
  Common.with_session (fun session ->
      let work tx =
        match
          Tx.run tx ~hydration:(Common.hydration session) ~query:"CREATE (a:Person {name: $name})"
            ~parameters:[ ("name", Values.String "Config Person") ]
        with
        | Ok result -> (
            match Neo4jResult.consume result with
            | Ok _ -> Ok ()
            | Error error -> Error (Session.Driver error))
        | Error error -> Error (Session.Driver error)
      in
      let metadata = [ ("applicationId", Values.String "123") ] in
      check (Session.execute_write session ~metadata ~timeout:5.0 work);
      print_endline "committed with metadata applicationId=123 and a 5s timeout")
