(* The summary of a query result, derived from the final PULL summary metadata.

   Plan, profile, notifications and GQL status objects are hydrated into
   [Values.t], hiding the PackStream representation from the caller. *)

open Neodriver_core
open Neodriver_packstream

type counters = {
  nodes_created : int;
  nodes_deleted : int;
  relationships_created : int;
  relationships_deleted : int;
  properties_set : int;
  labels_added : int;
  labels_removed : int;
  indexes_added : int;
  indexes_removed : int;
  constraints_added : int;
  constraints_removed : int;
  system_updates : int;
  contains_updates : bool;
  contains_system_updates : bool;
}

type server_info = { address : Addressing.t; agent : string option; protocol_version : int * int }

type t = {
  counters : counters;
  plan : Values.t option;
  profile : Values.t option;
  query_type : string option;
  database : string option;
  result_available_after : int option;
  result_consumed_after : int option;
  notifications : Values.t list;
  gql_status_objects : Values.t list;
  had_records : bool;
  had_keys : bool;
  server_info : server_info;
  query : string;
  parameters : (string * Values.t) list;
}

let metadata_string key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with Some (Packstream.String s) -> Some s | _ -> None)
  | _ -> None

let metadata_int key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with
      | Some (Packstream.Int n) -> Some (Int64.to_int n)
      | _ -> None)
  | _ -> None

let metadata_value key = function Packstream.Map fields -> List.assoc_opt key fields | _ -> None

let stat key stats =
  match List.assoc_opt key stats with Some (Packstream.Int n) -> Int64.to_int n | _ -> 0

let counters_of metadata =
  let stats = match metadata_value "stats" metadata with Some (Packstream.Map s) -> s | _ -> [] in
  let n key = stat key stats in
  let flag key =
    match List.assoc_opt key stats with Some (Packstream.Bool b) -> Some b | _ -> None
  in
  (* The contains-updates flags are derived from the counters when the server
     did not send them (like the Python driver): contains_updates = any graph
     counter > 0, contains_system_updates = system_updates > 0. *)
  let graph_counters =
    [
      n "nodes-created";
      n "nodes-deleted";
      n "relationships-created";
      n "relationships-deleted";
      n "properties-set";
      n "labels-added";
      n "labels-removed";
      n "indexes-added";
      n "indexes-removed";
      n "constraints-added";
      n "constraints-removed";
    ]
  in
  let contains_updates =
    match flag "contains-updates" with
    | Some b -> b
    | None -> List.exists (fun c -> c > 0) graph_counters
  in
  let contains_system_updates =
    match flag "contains-system-updates" with Some b -> b | None -> n "system-updates" > 0
  in
  {
    nodes_created = n "nodes-created";
    nodes_deleted = n "nodes-deleted";
    relationships_created = n "relationships-created";
    relationships_deleted = n "relationships-deleted";
    properties_set = n "properties-set";
    labels_added = n "labels-added";
    labels_removed = n "labels-removed";
    indexes_added = n "indexes-added";
    indexes_removed = n "indexes-removed";
    constraints_added = n "constraints-added";
    constraints_removed = n "constraints-removed";
    system_updates = n "system-updates";
    contains_updates;
    contains_system_updates;
  }

(* A legacy notification from a Bolt 6 GQL status carrying a [neo4j_code]. *)
let notification_of_status = function
  | Values.Map fields -> (
      match List.assoc_opt "neo4j_code" fields with
      | None -> None
      | Some _ ->
          let diag =
            match List.assoc_opt "diagnostic_record" fields with
            | Some (Values.Map d) -> d
            | _ -> []
          in
          let items =
            List.filter_map Fun.id
              [
                Option.map (fun v -> ("title", v)) (List.assoc_opt "title" fields);
                Option.map (fun v -> ("code", v)) (List.assoc_opt "neo4j_code" fields);
                Option.map (fun v -> ("description", v)) (List.assoc_opt "description" fields);
                Option.map (fun v -> ("severity", v)) (List.assoc_opt "_severity" diag);
                Option.map (fun v -> ("category", v)) (List.assoc_opt "_classification" diag);
                Option.map (fun v -> ("position", v)) (List.assoc_opt "_position" diag);
              ]
          in
          Some (Values.Map items))
  | _ -> None

let of_stream stream ~query ~parameters =
  let conn = Conn.connection stream in
  let metadata = match Conn.summary stream with Some s -> s | None -> Packstream.Map [] in
  let run_metadata = Conn.run_metadata stream in
  let hydrate = Hydration.hydrate (Conn.hydration conn) in
  let value_of key = Option.map hydrate (metadata_value key metadata) in
  let notifications =
    match metadata_value "notifications" metadata with
    | Some (Packstream.List items) -> List.map hydrate items
    | _ -> (
        match metadata_value "statuses" metadata with
        | Some (Packstream.List statuses) ->
            List.filter_map notification_of_status (List.map hydrate statuses)
        | _ -> [])
  in
  let gql_status_objects =
    match metadata_value "statuses" metadata with
    | Some (Packstream.List statuses) -> List.map hydrate statuses
    | _ -> []
  in
  let major, minor = Conn.version conn in
  (* A query type outside {r, w, rw, s} is a protocol violation: the driver
     rejects it (the TestKit invalid-query-type tests). *)
  let query_type = metadata_string "type" metadata in
  match query_type with
  | Some t when not (List.mem t [ "r"; "w"; "rw"; "s" ]) ->
      Errors.Configuration_error (Printf.sprintf "invalid query type %S" t) |> Result.error
  | _ ->
      Ok
        {
          counters = counters_of metadata;
          plan = value_of "plan";
          profile = value_of "profile";
          query_type;
          database = metadata_string "db" metadata;
          result_available_after = run_metadata.t_first;
          result_consumed_after = metadata_int "t_last" metadata;
          notifications;
          gql_status_objects;
          had_records = Conn.had_record stream;
          had_keys = run_metadata.fields <> [];
          server_info =
            {
              address = Conn.address conn;
              agent = Conn.server_agent conn;
              protocol_version = (major, minor);
            };
          query;
          parameters;
        }
