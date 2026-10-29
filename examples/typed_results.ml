(* Decode a query result into OCaml records, by field name.

   The query returns a whole node, a scalar, an aggregated list, and a few
   nullable values (scalar, date, nested map). The decoders are the single
   source of truth for the shapes; [check_keys] rejects a wrong query/decoder
   pair before any record is pulled. *)

open Neodriver

type person = { name : string; age : int }
type address = { city : string; country : string option }

type employee_row = {
  person : person;
  company : string;
  locations : string list;
  nickname : string option;
  hired_at : Temporal.Date.t option;
  home : address option;
}

let person_decoder : person Decode.t =
  let open Decode in
  let+ name = field "name" string and+ age = field "age" int in
  { name; age }

let address_decoder : address Decode.t =
  let open Decode in
  let+ city = field "city" string and+ country = field_opt "country" string in
  { city; country }

let employee_row_decoder : employee_row Decode.t =
  let open Decode in
  let+ person = field "person" person_decoder
  and+ company = field "company" string
  and+ locations = field "locations" (list string)
  and+ nickname = field "nickname" (option string)
  and+ hired_at = field "hired_at" (option date)
  and+ home = field "home" (option address_decoder) in
  { person; company; locations; nickname; hired_at; home }

let cleanup_query = "MATCH (n:TypedResultsDemo) DETACH DELETE n"

let setup_query =
  "UNWIND $people AS person\n\
   MERGE (p:TypedResultsDemo:Person {name: person.name})\n\
   SET p.age = person.age,\n\
   p.nickname = person.nickname,\n\
   p.hired_at = date(person.hired_at),\n\
   p.home = person.home\n\
   MERGE (c:TypedResultsDemo:Company {name: person.company})\n\
   MERGE (p)-[:WORKS_AT]->(c)\n\
   FOREACH (location IN CASE WHEN person.location IS NULL THEN [] ELSE [person.location] END |\n\
   MERGE (l:TypedResultsDemo:Location {name: location})\n\
   MERGE (p)-[:LIVES_IN]->(l))"

let read_query =
  {|MATCH (p:TypedResultsDemo:Person)-[:WORKS_AT]->(c:TypedResultsDemo:Company)
OPTIONAL MATCH (p)-[:LIVES_IN]->(l:TypedResultsDemo:Location)
RETURN p                        AS person,
       c.name                   AS company,
       collect(DISTINCT l.name) AS locations,
       p.nickname               AS nickname,
       p.hired_at               AS hired_at,
       p.home                   AS home
ORDER BY p.name|}

let null = Values.Null
let optional_string = function Some value -> Values.String value | None -> null

let optional_home = function
  | None -> null
  | Some (city, country) ->
      Values.Map [ ("city", Values.String city); ("country", optional_string country) ]

let demo_person ~name ~age ~nickname ~hired_at ~home ~company ~location =
  Values.Map
    [
      ("name", Values.String name);
      ("age", Values.Int (Int64.of_int age));
      ("nickname", optional_string nickname);
      ("hired_at", optional_string hired_at);
      ("home", optional_home home);
      ("company", Values.String company);
      ("location", optional_string location);
    ]

let run session ~query ~parameters =
  match Session.run session ~query ~parameters with
  | Ok result -> (
      match Neo4jResult.consume result with
      | Ok _ -> ()
      | Error error -> failwith (Errors.to_string error))
  | Error error -> failwith (Errors.to_string error)

let setup session =
  let people =
    Values.List
      [
        demo_person ~name:"Alice" ~age:42 ~nickname:(Some "Al") ~hired_at:(Some "2020-01-02")
          ~home:(Some ("Krakow", Some "PL"))
          ~company:"Acme" ~location:(Some "Krakow");
        demo_person ~name:"Bob" ~age:7 ~nickname:None ~hired_at:None ~home:None ~company:"Acme"
          ~location:None;
      ]
  in
  run session ~query:setup_query ~parameters:[ ("people", people) ]

let fetch_employees session =
  let result =
    match Session.run session ~query:read_query ~parameters:[] with
    | Ok result -> result
    | Error error -> failwith (Errors.to_string error)
  in
  (* RUN already reported the field names: reject a renamed AS alias before
     pulling a single record. *)
  (match Neo4jResult.check_keys result employee_row_decoder with
  | Ok () -> ()
  | Error error -> failwith (Errors.to_string error));
  let rec loop index acc =
    match Neo4jResult.next_as result employee_row_decoder with
    | Ok None -> List.rev acc
    | Ok (Some row) -> loop (index + 1) (row :: acc)
    | Error error -> failwith (Printf.sprintf "record %d: %s" (index + 1) (Errors.to_string error))
  in
  let rows = loop 0 [] in
  (* Drain to the summary so the auto-commit bookmark is recorded. *)
  (match Neo4jResult.consume result with
  | Ok _ -> ()
  | Error error -> failwith (Errors.to_string error));
  rows

let print_row row =
  Printf.printf "%s (%d) @ %s\n" row.person.name row.person.age row.company;
  Printf.printf "  locations: %s\n"
    (match row.locations with [] -> "-" | locations -> String.concat ", " locations);
  (match row.nickname with Some nickname -> Printf.printf "  aka %s\n" nickname | None -> ());
  (match row.hired_at with
  | Some date -> Printf.printf "  hired %s\n" (Temporal.Date.to_iso8601 date)
  | None -> ());
  match row.home with
  | Some home ->
      Printf.printf "  home: %s (%s)\n" home.city (Option.value ~default:"?" home.country)
  | None -> ()

let () =
  Common.with_session (fun session ->
      let cleanup () = run session ~query:cleanup_query ~parameters:[] in
      cleanup ();
      Fun.protect ~finally:cleanup (fun () ->
          setup session;
          let rows = fetch_employees session in
          List.iter print_row rows;
          Printf.printf "%d row(s)\n" (List.length rows)))
