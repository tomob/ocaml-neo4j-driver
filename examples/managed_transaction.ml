(* A managed transaction: [Session.execute] runs the work in a transaction,
   retrying retryable failures and committing it, and records the resulting
   bookmarks on the session. *)

open Neodriver

let () =
  Common.with_session (fun session ->
      let hydration = Common.hydration session in
      let created = ref 0 in
      let work tx =
        match
          Tx.run tx ~hydration ~query:"CREATE (p:Person {name: $name, id: toInteger($id)})"
            ~parameters:[ ("name", Values.String "Managed Person"); ("id", Values.Int 1000L) ]
        with
        | Ok result -> (
            match Neo4jResult.consume result with
            | Ok summary ->
                created := summary.counters.nodes_created;
                Ok ()
            | Error error -> Error (Session.Driver error))
        | Error error -> Error (Session.Driver error)
      in
      match Session.execute session ~mode:Config.Write work with
      | Ok () ->
          Printf.printf "created %d node(s); bookmarks: %s\n" !created
            (String.concat "," (Session.last_bookmarks session))
      | Error (Session.Driver error) -> failwith (Errors.to_string error)
      | Error Session.Client -> failwith "the application aborted the transaction")
