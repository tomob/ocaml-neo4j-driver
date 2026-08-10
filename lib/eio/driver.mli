(* User-facing entry point of the Eio backend of the Neo4j driver.

   [connect] parses a driver URI, builds the connection and pool configuration
   and wires the Eio resources into a pool-backed [t]. Sessions borrow a
   connection from the pool on first use and return it (with a RESET) on
   close. Routing ([neo4j://] and its [+s]/[+ssc] variants) is not implemented
   yet and is rejected by [Conn.connect] on first use. *)

open Neodriver_core

type t
(** A driver: a connection pool for the configured address. *)

val connect :
  ?resolver:(Addressing.t -> (Addressing.t list, Errors.t) result) ->
  uri:string ->
  auth:Conn.auth ->
  ?user_agent:string ->
  ?connection_timeout:float ->
  ?pool_config:Config.pool_config ->
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  (t, Errors.t) result
(** Build a driver for [uri] with [auth]. [resolver] replaces the address lookup (each returned
    address is tried in turn); [user_agent] defaults to [Conn.default_user_agent];
    [connection_timeout] (seconds) defaults to 30.0 and bounds each connection attempt and its
    subsequent reads/writes. [pool_config] (defaults from [Config.default_pool_config]: 100
    connections, 1h lifetime, 60s acquisition timeout, no liveness check) sizes the pool and its
    acquisition timeout. Connections are established lazily on first use; a [neo4j://] URI fails
    then with a [Service_unavailable] error (routing is not implemented yet). The [sw] switch is
    captured by the pool (it hosts the connection attempts), so it must outlive the returned [t].
    @return
      [Error (Configuration_error _)] for an unparseable URI; [Error _] from the lazy [Conn.connect]
      on first use otherwise. *)

val session : ?config:Session.config -> t -> Session.t
(** A new session borrowing a connection from the driver's pool on first use and returning it (with
    a RESET) on close. [config] defaults to [Session.default_config]: write access, no database or
    impersonation, the Python retry defaults. *)

val acquire : t -> (Conn.t, Errors.t) result
(** A connection for driver-level operations (e.g. verify connectivity); return it with [release].
*)

val release : t -> Conn.t -> unit
(** Return a connection acquired with [acquire] to the pool. *)

val close : t -> unit
(** Close the driver's pool: idle connections are closed and further [acquire]/[session] operations
    fail. Connections still in use by open sessions are closed (not returned to the pool) when those
    sessions close. *)
