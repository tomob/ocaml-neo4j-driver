(* A bounded connection pool for a single address. See pool.ml for the
   implementation. *)

open Neodriver_core

type t
(** A connection pool for the driver's address. *)

val create :
  pool_config:Config.pool_config ->
  connect:(unit -> (Conn.t, Errors.t) result) ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  t
(** Create a pool. [connect] establishes a new connection on demand.
    [pool_config.max_connection_pool_size] bounds the number of connections;
    [pool_config.connection_acquisition_timeout] (seconds) bounds how long [acquire] waits for a
    free connection; [pool_config.max_connection_lifetime] (seconds) expires idle connections;
    [pool_config.liveness_check_timeout] enables a RESET liveness check on reuse. *)

val in_use_count : t -> int
(** The number of connections currently checked out of the pool (the load a routing cluster uses to
    balance across addresses). *)

val acquire : t -> (Conn.t, Errors.t) result
(** Get a connection, reusing an idle one (lifetime- and liveness-checked) or creating a new one.
    @return
      [Error (Errors.Connection_acquisition_timeout _)] if no connection becomes available within
      the acquisition timeout; [Error _] if creating a new connection fails. *)

val release : t -> Conn.t -> unit
(** Return a connection to the pool: RESET it and queue it for reuse. A connection in the [Failed]
    state, or one whose RESET fails, is closed instead (its permit is still released). *)

val close : t -> unit
(** Close all idle connections. Connections still in use by open sessions are not closed here. *)
