(* An explicit transaction: BEGIN, RUN, COMMIT (rolling back on failure). *)

open Neodriver

let () =
  Common.with_session (fun session ->
      match Session.begin_transaction session with
      | Ok tx -> (
          match
            Tx.run tx ~hydration:(Common.hydration session)
              ~query:"CREATE (p:Person {name: $name, id: toInteger($id)})"
              ~parameters:[ ("name", Values.String "Explicit Person"); ("id", Values.Int 999L) ]
          with
          | Ok result -> (
              match Neo4jResult.consume result with
              | Ok _ -> (
                  match Tx.commit tx with
                  | Ok _ -> print_endline "committed the transaction"
                  | Error error ->
                      ignore (Tx.rollback tx);
                      failwith (Errors.to_string error))
              | Error error ->
                  ignore (Tx.rollback tx);
                  failwith (Errors.to_string error))
          | Error error ->
              ignore (Tx.rollback tx);
              failwith (Errors.to_string error))
      | Error error -> failwith (Errors.to_string error))
