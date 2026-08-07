(** User-facing entry point of the Eio backend of the Neo4j driver.

    [connect] parses a driver URI, builds the connection and session configuration and wires the Eio
    resources into a ready, lazily connecting [Session.t]. There is no connection pool yet: each
    [connect] produces a single session that owns its own connection. Routing ([neo4j://] and its
    [+s]/[+ssc] variants) is not implemented yet and is rejected by [Conn.connect] on first use. *)

open Neodriver_core

val connect :
  ?resolver:(Addressing.t -> (Addressing.t list, Errors.t) result) ->
  uri:string ->
  auth:Conn.auth ->
  ?user_agent:string ->
  ?connection_timeout:float ->
  ?config:Session.config ->
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  (Session.t, Errors.t) result
(** Build a session for [uri] with [auth]. [resolver] replaces the address lookup (each returned
    address is tried in turn); [user_agent] defaults to [Conn.default_user_agent];
    [connection_timeout] (seconds) defaults to 30.0 and bounds the whole connection attempt and
    subsequent reads/writes. [config] is the session's [Session.config] (defaults from
    [Session.default_config]: write access, no database or impersonation, the Python retry
    defaults). The connection is established lazily on first use; a [neo4j://] URI fails then with a
    [Service_unavailable] error (routing is not implemented yet). The [sw] switch is captured by the
    session (it hosts the lazy connection attempt), so it must outlive the returned [Session.t].
    @return
      [Error (Configuration_error _)] for an unparseable URI; [Error _] from the lazy [Conn.connect]
      on first use otherwise. *)
