(** Explicit transaction on a single connection.

    A [t] wraps a connection with the per-transaction state: [Open] after BEGIN, [Failed] after any
    error inside the transaction, [Closed] after COMMIT/ROLLBACK. Operations on a closed transaction
    return a [Transaction_error "Transaction closed"]; operations on a failed transaction fail
    without touching the server (except ROLLBACK, which recovers the connection with a RESET).

    Modeled on the Python driver's AsyncTransaction (_async/work/transaction.py). *)

open Neodriver_packstream
open Neodriver_core

type state = Open | Failed | Closed  (** Per-transaction state. *)

type t
(** An explicit transaction. *)

val begin_transaction : Conn.t -> extra:Packstream.value -> (t, Errors.t) result
(** Send BEGIN on [conn] and return an [Open] transaction. A RESET is sent first if the connection
    is in the [Failed] state (recovering from a previous failed transaction). *)

val run :
  t ->
  hydration:Hydration.t ->
  query:string ->
  parameters:(string * Values.t) list ->
  (Neo4j_result.t, Errors.t) result
(** Send RUN for [query] inside the transaction; the result is streamed lazily via [Result]. On any
    error the transaction becomes [Failed] and an [Error _] is returned. The transaction's
    still-open results are drained before [commit]/[rollback]. *)

val commit : t -> (string option, Errors.t) result
(** Send COMMIT, applying the transaction's writes, and return the [bookmark] from the response. *)

val rollback : t -> (unit, Errors.t) result
(** Send ROLLBACK, discarding the transaction's writes (a RESET on a [Failed] connection). *)

val close : t -> (unit, Errors.t) result
(** Close the transaction, rolling back if it is still open. *)

val closed : t -> bool
(** Whether the transaction has been committed or rolled back. *)

val failed : t -> bool
(** Whether the transaction has failed. *)
