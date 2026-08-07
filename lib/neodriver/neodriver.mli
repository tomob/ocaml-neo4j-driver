(** Friendly names for the whole Neo4j driver.

    Aggregates the public API of all packages under a single namespace, so consumers can `open
    Neodriver` and use Packstream, Errors, Config, Addressing, Deadline, Conn, Session, Tx,
    Transport, Bolt, State, Values, Temporal, Hydration, Capabilities, Neo4jResult, Summary and
    Driver directly. *)

module Packstream = Neodriver_packstream.Packstream
(** PackStream binary serialization. *)

module Errors = Neodriver_core.Errors
(** Error taxonomy. *)

module Config = Neodriver_core.Config
(** Configuration records. *)

module Addressing = Neodriver_core.Addressing
(** Server addresses and URI parsing. *)

module Deadline = Neodriver_core.Deadline
(** Deadlines. *)

module Temporal = Neodriver_core.Temporal
(** Temporal value types. *)

module Values = Neodriver_core.Values
(** Rich value types. *)

module Hydration = Neodriver_core.Hydration
(** Hydration. *)

module Capabilities = Neodriver_core.Capabilities
(** Per-version Bolt protocol capabilities. *)

module Conn = Neodriver_eio.Conn
(** Minimal Bolt connection (connect, authenticate, run/pull/discard, transactions). *)

module Session = Neodriver_eio.Session
(** Per-session connection: auto-commit queries, explicit and managed transactions. *)

module Tx = Neodriver_eio.Tx
(** Explicit transactions (BEGIN/COMMIT/ROLLBACK). *)

module Transport = Neodriver_eio.Transport
(** Eio-based TCP transport with Bolt message framing. *)

module Bolt = Neodriver_eio.Bolt
(** Bolt protocol messages (send/receive and response interpretation). *)

module State = Neodriver_eio.State
(** Bolt server-state machine. *)

module Neo4jResult = Neodriver_eio.Neo4jResult
(** A lazily-streamed query result (next/peek/fetch/consume/single). *)

module Summary = Neodriver_eio.Summary
(** The summary of a query result (counters, plan, notifications, ...). *)

module Driver = Neodriver_eio.Driver
(** Eio backend entry point ([Driver.connect]). *)
