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

module Tls_client = Tls_client
(** TLS client settings: the trust anchors ([System], [Trust_all] or custom certificates) used to
    validate server certificates. *)

module Pem_key = Pem_key
(** Loading PEM private keys, including the legacy OpenSSL-encrypted form. *)

module Bolt = Bolt
(** Bolt protocol messages (send/receive and response interpretation). *)

module State = State
(** Bolt server-state machine. *)

module Tx = Tx
(** Explicit transactions (BEGIN/COMMIT/ROLLBACK with per-transaction state). *)

module Session = Session
(** Per-session connection: auto-commit queries, explicit and managed transactions. *)

module Pool = Pool
(** A bounded connection pool (acquire/release/close), used by [Driver]. *)

module Cluster = Cluster
(** Minimal routing for [neo4j://] drivers (routing tables + per-address pools). *)

module Neo4jResult = Neo4j_result
(** A lazily-streamed query result (next/peek/fetch/consume/single). *)

module Summary = Summary
(** The summary of a query result (counters, plan, notifications, ...). *)

module Bookmarks = Neodriver_core.Bookmarks
(** An immutable set of bookmark string values (causal chaining). *)

module Bookmark_manager = Neodriver_core.Bookmark_manager
(** Bookmark managers (sharing bookmarks across sessions). *)

module Log = Neodriver_core.Log
(** Logging infrastructure ([Logs] sources, connection ids, value formatting and the
    [NEO4J_LOG_LEVEL] / [NEO4J_LOG_SCOPES] environment control). *)
