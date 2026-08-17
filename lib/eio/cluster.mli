(** Routing for [neo4j://] drivers: per-database routing tables (fetched over the ROUTE message), a
    pool per cluster address and address deactivation (failed servers are dropped from the tables
    until a refresh re-lists them). See cluster.ml for the implementation. *)

open Neodriver_core
open Neodriver_packstream

type t
(** A routing cluster for one [neo4j://] driver. *)

val create :
  ?resolver:(Addressing.t -> (Addressing.t list, Errors.t) result) ->
  pool_config:Config.pool_config ->
  connect:(Addressing.t -> (Conn.t, Errors.t) result) ->
  connect_routing:(Addressing.t -> (Conn.t, Errors.t) result) ->
  routing_context:(string * string) list ->
  initial:Addressing.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  t
(** Create a cluster rooted at [initial] (the URI's address). [connect] establishes a connection to
    the given address (the Driver closes over its Eio resources); routing tables are fetched from a
    router (the initial address until the first fetch) and cached per database with the
    server-provided TTL. *)

val acquire :
  t ->
  mode:Config.access_mode ->
  database:string option ->
  imp_user:string option ->
  bookmarks:string list ->
  (Conn.t * string option, Errors.t) result
(** Get a connection for [mode] and [database]: the routing table (refreshed when stale) selects the
    least-loaded address (fewest in-use connections) among the matching role (readers for [Read],
    writers for [Write]) and a per-address pool serves the connection. [imp_user] (the session's
    impersonated user, [None] for the driver's own user) is sent with the ROUTE request (Bolt 4.4+)
    and keys the home-db cache; [bookmarks] are sent with the ROUTE request too (the session's
    bookmarks, or [] for a plain resolution). The effective database is also returned: for a fixed
    [database] it is that database; for the default database ([None]) it is the server's home
    database — resolved from the ROUTE response's [db] field and cached per [imp_user]
    ([Some home_db] thereafter), or taken from the cache when fresh. When the selected server is
    unreachable ([Service_unavailable]) it is deactivated and the next address is tried, bounded by
    the pool's [connection_acquisition_timeout]. *)

val deactivate : t -> Addressing.t -> unit
(** Remove [addr] from every routing table and close its pool: future acquires skip it until a
    routing-table refresh re-lists it. *)

val on_write_failure : t -> database:string option -> Addressing.t -> unit
(** Remove [addr] from the [writers] of [database] (a NotALeader / read-only failure). *)

val update_table : t -> database:string option -> imp_user:string option -> Packstream.value -> unit
(** Apply an [rt] routing table received from the server (server-side routing) for [database]: parse
    it and, when valid, replace the cached table (fresh timestamp), refresh [routers] and clear a
    cached fetch error. The table's [db] field (the server's home database) is cached for [imp_user]
    so default-database sessions can reuse it without a ROUTE. Malformed values are ignored. *)

val routing_table_of : t -> database:string option -> Routing_table.t option
(** The cached routing table for [database], if any (no fetch; read under the lock). Test-support
    API for the TestKit backend ([GetRoutingTable]). *)

val force_routing_table_update :
  t -> database:string option -> bookmarks:string list -> (unit, Errors.t) result
(** Fetch a fresh routing table for [database] via the routers, bypassing the freshness and
    negative-cache checks, and store it (refreshing [routers] and clearing a cached fetch error).
    Bounded by the pool's [connection_acquisition_timeout]. Test-support API for the TestKit backend
    ([ForcedRoutingTableUpdate]). *)

val release : t -> Conn.t -> unit
(** Return a connection to its pool (found via the connection's address; a connection whose pool is
    unknown is closed instead). *)

val close : t -> unit
(** Close all the cluster's pools. *)
