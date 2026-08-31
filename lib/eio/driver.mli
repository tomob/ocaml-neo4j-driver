(* User-facing entry point of the Eio backend of the Neo4j driver.

   [connect] parses a driver URI, builds the connection and pool (or routing
   cluster) configuration and wires the Eio resources into a pool-backed [t].
   Sessions borrow a connection on first use and return it (with a RESET) on
   close. [bolt://] drivers use a single connection pool; [neo4j://] (and its
   [+s]/[+ssc] variants) use minimal routing (routing tables fetched over the
   ROUTE message — see cluster.ml). *)

open Neodriver_core

type t
(** A driver: a connection pool for the configured address, or a routing cluster for [neo4j://]. *)

val connect :
  ?resolver:(Addressing.t -> (Addressing.t list, Errors.t) result) ->
  ?domain_name_resolver:(string -> (string list, Errors.t) result) ->
  uri:string ->
  auth:Conn.auth ->
  ?auth_manager:Auth_manager.t ->
  ?user_agent:string ->
  ?connection_timeout:float ->
  ?pool_config:Config.pool_config ->
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  (t, Errors.t) result
(** Build a driver for [uri] with [auth]. [auth_manager] (default [Auth_manager.static auth])
    supplies the tokens: new connections authenticate with its current token and a reused connection
    is re-authenticated when it rotates. [resolver] replaces the address lookup for direct [bolt://]
    drivers (each returned address is tried in turn); [user_agent] defaults to
    [Conn.default_user_agent]; [connection_timeout] (seconds) defaults to 30.0 and bounds each
    connection attempt and its subsequent reads/writes. [pool_config] (defaults from
    [Config.default_pool_config]: 100 connections, 1h lifetime, 60s acquisition timeout, no liveness
    check) sizes the pool and its acquisition timeout. Connections are established lazily on first
    use; for [neo4j://] the URI's address is the initial router and routing tables are fetched on
    demand. The [sw] switch is captured (it hosts the connection attempts), so it must outlive the
    returned [t].
    @return
      [Error (Configuration_error _)] for an unparseable URI; [Error _] from the lazy connect on
      first use otherwise. *)

val session : ?config:Session.config -> t -> Session.t
(** A new session borrowing a connection from the driver's pool (or routing cluster, selected by the
    session's [access_mode]/[database]) on first use and returning it (with a RESET) on close.
    [config] defaults to [Session.default_config]: write access, no database or impersonation, the
    Python retry defaults. *)

val acquire : ?mode:Config.access_mode -> t -> (Conn.t, Errors.t) result
(** A connection for driver-level operations (e.g. verify connectivity); return it with [release].
    For a routed driver this uses the default database and [mode] (default write access). *)

val release : t -> Conn.t -> unit
(** Return a connection acquired with [acquire] to the pool (or cluster). *)

val close : t -> unit
(** Close the driver's pool/cluster: idle connections are closed and further [acquire]/[session]
    operations fail. Connections still in use by open sessions are closed (not returned to the pool)
    when those sessions close. *)

val get_routing_table : t -> database:string option -> Routing_table.t option
(** The driver's cached routing table for [database] ([None] for a direct [bolt://] driver or before
    the first fetch). Test-support API for the TestKit backend. *)

val force_routing_table_update :
  t -> database:string option -> bookmarks:string list -> (unit, Errors.t) result
(** Force a routing-table refresh for [database] (test-support API for the TestKit backend; a direct
    [bolt://] driver has no routing table and gets an error). *)
