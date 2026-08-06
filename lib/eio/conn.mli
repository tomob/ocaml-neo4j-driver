(* Minimal Bolt connection: TCP connect + handshake.

   See conn.ml for the implementation. *)

open Neodriver_core

type config = { host : string; port : int; scheme : Addressing.scheme; connection_timeout : float }
(** Target connection settings. The scheme selects TLS: [Bolt] plain, [Bolt_secure] TLS with
    certificate validation, [Bolt_self_signed] TLS without validation. Routing schemes ([Neo4j*])
    are rejected until routing is implemented. *)

type t = { transport : Transport.t; major : int; minor : int }
(** An established Bolt connection: the transport plus the negotiated protocol version. *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  config ->
  (t, Errors.t) result
(** Establish a connection (over TLS when the scheme requires it) and negotiate the Bolt protocol
    version. [clock] bounds the whole attempt (TCP connect + TLS handshake) and subsequent
    reads/writes by [config.connection_timeout]. [connect] returns the connection (with [major] and
    [minor] set) on success.
    @return
      [Error _] for connection/handshake failures, or for routing schemes (unsupported until routing
      is implemented). *)

val close : t -> unit
(** Close the connection. *)
