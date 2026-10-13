(* The canonical hello world: create a Greeting node in a managed (retried)
   write transaction and print the message the server returns. *)

open Neodriver

let message = "hello, world"

let () =
  Common.with_session (fun session ->
      let greeting = ref "" in
      let work tx =
        match
          Tx.run tx ~hydration:(Common.hydration session)
            ~query:
              "CREATE (a:Greeting) SET a.message = $message RETURN a.message + ', from node ' + \
               id(a)"
            ~parameters:[ ("message", Values.String message) ]
        with
        | Ok result -> (
            match Neo4jResult.single result with
            | Ok [ Values.String text ] ->
                greeting := text;
                Ok ()
            | Ok _ -> Error Session.Client
            | Error error -> Error (Session.Driver error))
        | Error error -> Error (Session.Driver error)
      in
      match Session.execute_write session work with
      | Ok () -> print_endline !greeting
      | Error (Session.Driver error) -> failwith (Errors.to_string error)
      | Error Session.Client -> failwith "the query did not return a single string")
