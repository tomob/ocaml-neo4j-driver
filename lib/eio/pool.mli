(* A bounded connection pool for a single address. See pool.ml for the
   implementation. *)

open Neodriver_core

type t
(** A connection pool for the driver's address. *)

val create :
  pool_config:Config.pool_config ->
  ?auth_manager:Auth_manager.t option ->
  connect:(Auth_manager.token option -> (Conn.t, Errors.t) result) ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  t
(** Create a pool. [connect] establishes a new connection on demand for the given session auth token
    ([None] = the driver's auth — resolved from [auth_manager], which the driver passes; [None]
    disables auth management). [pool_config.max_connection_pool_size] bounds the number of
    connections; [pool_config.connection_acquisition_timeout] (seconds) bounds how long [acquire]
    waits for a free connection; [pool_config.max_connection_lifetime] (seconds) expires idle
    connections; [pool_config.liveness_check_timeout] enables a RESET liveness check on reuse. With
    an auth manager, a reused connection is re-authenticated when its token differs from the one the
    connection is logged on with (or after it was marked unauthenticated); on Bolt < 5.1 the
    connection is purged and the acquire retried. Server security errors are handled through the
    manager and an [AuthorizationExpired] marks every connection unauthenticated. *)

val acquire :
  ?force_auth:bool ->
  session_auth:Auth_manager.token option ->
  force_liveness:bool ->
  t ->
  (Conn.t, Errors.t) result
(** Acquire a connection. [session_auth] (user switching) opens a new connection with that token and
    re-authenticates a reused one to it; [None] uses the pool's auth manager. Session-level auth
    requires re-authentication support (Bolt >= 5.1); a [Configuration_error] is surfaced then
    rather than the backwards-compatible purge used for the driver's own auth. [force_liveness]
    RESETs a reused connection before returning it ([false] for a session acquire; [true] for a
    one-shot driver-level acquire such as GetServerInfo, which must see a clean connection — cf. the
    Python driver's [liveness_check_timeout = 0]). [force_auth] (default [false]) re-authenticates a
    reused connection even when it already carries [session_auth] (the Python driver's
    [verify_authentication] forces a LOGOFF/LOGON so the server re-checks the credentials). *)

val in_use_count : t -> int
(** The number of connections currently checked out of the pool (the load a routing cluster uses to
    balance across addresses). *)

val put_conn : t -> Conn.t -> unit
(** Get a connection, reusing an idle one (lifetime- and liveness-checked) or creating a new one.
    @return
      [Error (Errors.Connection_acquisition_timeout _)] if no connection becomes available within
      the acquisition timeout; [Error _] if creating a new connection fails. *)

val release : t -> Conn.t -> unit
(** Return a connection to the pool: RESET it and queue it for reuse. A connection in the [Failed]
    state, or one whose RESET fails, is closed instead (its permit is still released). *)

val close : t -> unit
(** Close all idle connections. Connections still in use by open sessions are not closed here. *)
