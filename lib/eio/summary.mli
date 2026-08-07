(** The summary of a query result, derived from the final PULL summary metadata.

    Plan, profile, notifications and GQL status objects are hydrated into [Values.t], hiding the
    PackStream representation from the caller. *)

open Neodriver_core

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
(** The write-counters of a query result (from the PULL summary's [stats]). *)

type server_info = { address : Addressing.t; agent : string option; protocol_version : int * int }
(** The server the query ran on: its [address], the [agent] string from HELLO and the negotiated
    [protocol_version]. *)

type t = {
  counters : counters;
  plan : Values.t option;
  profile : Values.t option;
  query_type : string;
  database : string option;
  result_available_after : int option;
  result_consumed_after : int option;
  notifications : Values.t list;
  gql_status_objects : Values.t list;
  server_info : server_info;
  query : string;
  parameters : (string * Values.t) list;
}
(** A query result summary: counters, plan/profile, timings, notifications and GQL status objects,
    the [server_info] and the original [query]/[parameters]. *)

val of_stream : Conn.stream -> query:string -> parameters:(string * Values.t) list -> t
(** Build the summary from a completed stream (after the final PULL). The plan, profile,
    notifications and GQL status objects are hydrated into [Values.t]. *)
