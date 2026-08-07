(** Public interface of the neodriver_eio library.

    Curated public surface: only the modules aliased here are part of the public API. *)

module Driver = Driver
(** User-facing entry point: [Driver.connect] builds a session from a URI and auth token. *)

module Transport = Transport
(** Eio-based TCP transport with Bolt message framing. *)

module Handshake = Handshake
(** Bolt handshake (protocol version negotiation). *)

module Conn = Conn
(** A minimal Bolt connection (connect, authenticate, RUN/PULL/DISCARD, transactions). *)

module Bolt = Bolt
(** Bolt protocol messages (send/receive and response interpretation). *)

module State = State
(** Bolt server-state machine. *)

module Tx = Tx
(** Explicit transactions (BEGIN/COMMIT/ROLLBACK with per-transaction state). *)

module Session = Session
(** Per-session connection: auto-commit queries, explicit and managed transactions. *)

module Neo4jResult = Neo4j_result
(** A lazily-streamed query result (next/peek/fetch/consume/single). *)

module Summary = Summary
(** The summary of a query result (counters, plan, notifications, ...). *)
