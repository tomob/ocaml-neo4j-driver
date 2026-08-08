(* Run a read query and print the returned records (field name and value). *)

open Neodriver

let query = "MATCH (p:Person)-[:WORKS_AT]->(c:Company) RETURN p.name AS name, c.name AS company"

let () =
  Common.with_session (fun session ->
      match Session.run session ~query ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.data result with
          | Ok rows ->
              List.iter
                (fun row ->
                  List.iter
                    (fun (key, value) -> Printf.printf "%s = %s\n" key (Values.to_string value))
                    row)
                rows
          | Error error -> failwith (Errors.to_string error))
      | Error error -> failwith (Errors.to_string error))
