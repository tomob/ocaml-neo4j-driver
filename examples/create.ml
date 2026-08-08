(* Read examples/data/employees.csv and create the graph, one MERGE query per
   row (analogous to the Python driver's create_data example). Run from the
   repository root. *)

open Neodriver

let csv_path = "examples/data/employees.csv"

let merge_query =
  "MERGE (p:Person {id: toInteger($id), name: $name, governmentId: $gov_id})\n\
   MERGE (l:Location {name: $location})\n\
   MERGE (c:Company {name: $company})\n\
   MERGE (p)-[:LIVES_IN]->(l)\n\
   MERGE (p)-[:WORKS_AT {position: $position}]->(c)"

let () =
  Common.with_session (fun session ->
      let rows = Common.read_csv csv_path in
      match rows with
      | [] -> failwith (csv_path ^ " is empty")
      | header :: data ->
          let field row key =
            match List.assoc_opt key (List.combine header row) with
            | Some value -> value
            | None -> ""
          in
          List.iter
            (fun row ->
              let parameters =
                [
                  ("id", Values.Int (Int64.of_int (int_of_string (field row "id"))));
                  ("name", Values.String (field row "name"));
                  ("gov_id", Values.Int (Int64.of_int (int_of_string (field row "gov_id"))));
                  ("location", Values.String (field row "location"));
                  ("company", Values.String (field row "company"));
                  ("position", Values.String (field row "position"));
                ]
              in
              match Session.run session ~query:merge_query ~parameters with
              | Ok result -> (
                  match Neo4jResult.consume result with
                  | Ok summary ->
                      Printf.printf "created %d node(s)\n" summary.counters.nodes_created
                  | Error error -> failwith (Errors.to_string error))
              | Error error -> failwith (Errors.to_string error))
            data)
