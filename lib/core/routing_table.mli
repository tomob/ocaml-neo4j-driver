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

val pick : int ref -> Addressing.t list -> Addressing.t option
(** Round-robin over a role's addresses using the given counter (an [Addressing.t list] is a slice
    of the table for that role). *)
