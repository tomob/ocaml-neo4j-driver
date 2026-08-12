(** Routing tables for [neo4j://] (routed) drivers.

    A routing table lists the cluster addresses for one database, grouped by role ([ROUTE] routers,
    [READ] readers, [WRITE] writers). See routing_table.ml for the implementation. *)

open Neodriver_packstream

type t = {
  ttl_seconds : int;
  routers : Addressing.t list;
  readers : Addressing.t list;
  writers : Addressing.t list;
}
(** A routing table for one database. *)

val parse : Packstream.value -> t option
(** Parse a routing table from a PackStream [rt] value: a map with [ttl] (seconds) and [servers],
    each server a map of [addresses] to a [role] ("ROUTE"/"READ"/"WRITE"). Returns [None] for
    malformed values. *)

val ttl_seconds : t -> int
(** The table's TTL in seconds. *)

val routers : t -> Addressing.t list
(** The cluster's router addresses. *)

val readers : t -> Addressing.t list
(** The cluster's reader addresses. *)

val writers : t -> Addressing.t list
(** The cluster's writer addresses. *)

val least_loaded : load:(Addressing.t -> int) -> Addressing.t list -> Addressing.t option
(** Choose the least-loaded address of a role: the smallest [load], ties broken by list order.
    Returns [None] for an empty list. *)

val remove_address : Addressing.t -> t -> t
(** Drop [addr] from routers, readers and writers (full deactivation). The TTL is kept. *)

val remove_writer : Addressing.t -> t -> t
(** Drop [addr] from the writers only (a NotALeader / read-only failure). Routers and readers are
    untouched. *)
