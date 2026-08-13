(** Routing tables for [neo4j://] (routed) drivers.

    A routing table lists the cluster addresses for one database, grouped by role ([ROUTE] routers,
    [READ] readers, [WRITE] writers). See routing_table.ml for the implementation. *)

open Neodriver_packstream

type t = {
  ttl_seconds : int;
  routers : Addressing.t list;
  readers : Addressing.t list;
  writers : Addressing.t list;
  database : string option;
}
(** A routing table for one database. [database] is the table's [db] field: the database the table
    was fetched for — the server's home database when it was fetched for the default database
    ([None] tables carry [None]). *)

val parse : Packstream.value -> t option
(** Parse a routing table from a PackStream [rt] value: a map with [ttl] (seconds), [servers], each
    server a map of [addresses] to a [role] ("ROUTE"/"READ"/"WRITE"), and an optional [db] (the
    database the table is for). Returns [None] for malformed values. *)

val ttl_seconds : t -> int
(** The table's TTL in seconds. *)

val routers : t -> Addressing.t list
(** The cluster's router addresses. *)

val readers : t -> Addressing.t list
(** The cluster's reader addresses. *)

val writers : t -> Addressing.t list
(** The cluster's writer addresses. *)

val database : t -> string option
(** The table's [db] field: the database it was fetched for (the server's home database for a
    default-database fetch). [None] when the [rt] carried no [db]. *)

val least_loaded : load:(Addressing.t -> int) -> Addressing.t list -> Addressing.t option
(** Choose the least-loaded address of a role: the smallest [load], ties broken by list order.
    Returns [None] for an empty list. *)

val remove_address : Addressing.t -> t -> t
(** Drop [addr] from routers, readers and writers (full deactivation). The TTL is kept. *)

val remove_writer : Addressing.t -> t -> t
(** Drop [addr] from the writers only (a NotALeader / read-only failure). Routers and readers are
    untouched. *)
