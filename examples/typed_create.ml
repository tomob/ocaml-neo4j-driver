(* Like create.ml, but the query parameters are generated from a typed record
   with [@@deriving neo4j_params]. Run from the repository root. *)

open Neodriver

let csv_path = "examples/data/employees.csv"

type employee = {
  id : int64;
  name : string;
  government_id : int64; [@neo4j.alias "gov_id"]
  location : string;
  company : string;
  position : string;
}
[@@deriving neo4j_params]
(* [employee_params] is:
     [("id", Int ...); ("name", String ...); ("gov_id", Int ...); ...] *)

let merge_query =
  "MERGE (p:Person {id: $id, name: $name, governmentId: $gov_id})\n\
   MERGE (l:Location {name: $location})\n\
   MERGE (c:Company {name: $company})\n\
   MERGE (p)-[:LIVES_IN]->(l)\n\
   MERGE (p)-[:WORKS_AT {position: $position}]->(c)"

let employee_of_csv header row =
  let column key =
    match List.assoc_opt key (List.combine header row) with
    | Some value -> value
    | None -> failwith (Printf.sprintf "missing CSV column %S" key)
  in
  {
    id = Int64.of_string (column "id");
    name = column "name";
    government_id = Int64.of_string (column "gov_id");
    location = column "location";
    company = column "company";
    position = column "position";
  }

let () =
  Common.with_session (fun session ->
      match Common.read_csv csv_path with
      | [] -> failwith (csv_path ^ " is empty")
      | header :: rows ->
          List.iter
            (fun row ->
              let parameters = employee_params (employee_of_csv header row) in
              match Session.run session ~query:merge_query ~parameters with
              | Ok result -> (
                  match Neo4jResult.consume result with
                  | Ok summary ->
                      Printf.printf "created %d node(s)\n" summary.counters.nodes_created
                  | Error error -> failwith (Errors.to_string error))
              | Error error -> failwith (Errors.to_string error))
            rows)
