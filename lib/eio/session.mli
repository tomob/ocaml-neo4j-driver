(* Per-session connection with auto-commit queries, explicit and managed
   transactions.

   A [t] owns the session's lazy connection, its bookmarks and its current
   explicit transaction. [run] executes an auto-commit query and records the
   bookmark from the PULL summary; [begin_transaction] opens an explicit
   transaction; [execute] runs a managed transaction (unit of work) with the
   retry loop described in the PLAN (budget, jittered backoff, decision via
   [Errors.is_retryable]). Between retry attempts the connection is recovered
   with a RESET rather than reconnected.

   Modeled on the Python driver's AsyncSession (_async/work/session.py). *)

open Neodriver_core
open Neodriver_packstream

type failure =
  | Driver of Errors.t
  | Client
      (** How a unit of work failed: [Driver e] is a driver/server error ([e] may be retryable);
          [Client] is an application (frontend) error, which is never retried. *)

type config = {
  database : string option;
  access_mode : Config.access_mode;
  impersonated_user : string option;
  fetch_size : int option;
  bookmarks : string list;
  max_transaction_retry_time : float;
  initial_retry_delay : float;
  retry_delay_multiplier : float;
  retry_delay_jitter_factor : float;
}
(** Session settings. [bookmarks] seeds the session's bookmarks. The retry parameters mirror the
    Python driver defaults ([max_transaction_retry_time] is configurable via the TestKit driver
    request). *)

val default_config : config
(** Session configuration with the driver defaults: write access, no database or impersonation, and
    the Python retry defaults (1s initial delay, x2 multiplier, 0.2 jitter, 30s budget). *)

type t
(** A session: its lazy connection, bookmarks and current transaction. *)

val create :
  config ->
  clock:Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  connect:(unit -> (Conn.t, Errors.t) result) ->
  t
(** Create a session. [connect] establishes the session's connection on first use (the backend
    provides it from the Eio context). [clock] bounds the transaction retry budget and backoff. *)

val conn : t -> (Conn.t, Errors.t) result
(** The session's connection, connecting on first use. *)

val run :
  ?timeout:float ->
  ?metadata:(string * Values.t) list ->
  t ->
  query:string ->
  parameters:(string * Values.t) list ->
  (Conn.run_metadata * Values.t list list * Packstream.value, Errors.t) result
(** Run an auto-commit query: RUN + PULL, buffering the result. The session's bookmarks, database
    and access mode go into the RUN extra; a [bookmark] in the PULL summary updates the session's
    bookmarks. *)

val begin_transaction :
  ?metadata:(string * Values.t) list -> ?timeout:float -> t -> (Tx.t, Errors.t) result
(** Begin an explicit transaction on the session's connection.
    @return
      [Error (Transaction_error "Explicit transaction already open")] if a transaction is already
      open. *)

val execute :
  t ->
  mode:Config.access_mode ->
  ?metadata:(string * Values.t) list ->
  ?timeout:float ->
  (Tx.t -> (unit, failure) result) ->
  (unit, failure) result
(** Run the unit of work [work] in a managed transaction with retry. [work] is invoked on a fresh
    transaction each attempt. On [Ok] the transaction is committed and the session's bookmarks
    updated. On [Error (Driver e)] the transaction is rolled back; if [Errors.is_retryable e] and
    the [max_transaction_retry_time] budget remains, [work] is retried after a jittered backoff. On
    [Error Client] the transaction is rolled back without retrying. *)

val last_bookmarks : t -> string list
(** The session's last known bookmarks (seeded from the config, updated on every successful commit).
*)

val mark_tx_ended : t -> bookmark:string option -> unit
(** Record the end of the session's current transaction: a successful commit's [bookmark] updates
    the session's bookmarks; [None] leaves them unchanged. The session is then free to begin a new
    transaction. *)

val close : t -> unit
(** Close the session's open transaction (if any) and its connection. *)
