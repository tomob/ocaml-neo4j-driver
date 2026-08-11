(** Minimal routing for [neo4j://] drivers: per-database routing tables (fetched over the ROUTE
    message) and a pool per cluster address. See cluster.ml for the implementation. *)

open Neodriver_core

type t
(** A routing cluster for one [neo4j://] driver. *)

val create :
  pool_config:Config.pool_config ->
  connect:(Addressing.t -> (Conn.t, Errors.t) result) ->
  routing_context:(string * string) list ->
  initial:Addressing.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  t
(** Create a cluster rooted at [initial] (the URI's address). [connect] establishes a connection to
    the given address (the Driver closes over its Eio resources); routing tables are fetched from a
    router (the initial address until the first fetch) and cached per database with the
    server-provided TTL. *)

val acquire : t -> mode:Config.access_mode -> database:string option -> (Conn.t, Errors.t) result
(** Get a connection for [mode] and [database]: the routing table (refreshed when stale) selects an
    address round-robin among the matching role (readers for [Read], writers for [Write]) and a
    per-address pool serves the connection. *)

val release : t -> Conn.t -> unit
(** Return a connection to its pool (found via the connection's address; a connection whose pool is
    unknown is closed instead). *)

val close : t -> unit
(** Close all the cluster's pools. *)
