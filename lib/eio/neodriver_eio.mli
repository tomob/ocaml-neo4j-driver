(* Public interface of the neodriver_eio library.

   Curated public surface: only the modules aliased here are part of the
   public API. *)

module Driver = Driver
(** Entry point of the Eio backend (placeholder). *)

module Transport = Transport
(** Eio-based TCP transport with Bolt message framing. *)

module Handshake = Handshake
(** Bolt handshake (protocol version negotiation). *)

module Conn = Conn
(** Minimal Bolt connection (TCP connect + handshake). *)

module Bolt = Bolt
(** Bolt protocol messages (send/receive and response interpretation). *)

module State = State
(** Bolt server-state machine. *)

module Tx = Tx
(** Explicit transactions (BEGIN/COMMIT/ROLLBACK with per-transaction state). *)

module Session = Session
(** Per-session connection: auto-commit queries, explicit and managed transactions. *)
