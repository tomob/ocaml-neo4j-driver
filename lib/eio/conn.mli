(* Minimal Bolt connection: TCP connect (+ optional TLS) + handshake + HELLO/auth.

   See conn.ml for the implementation. *)

open Neodriver_core

type auth = { scheme : string; principal : string; credentials : string }
(** Authentication token sent in HELLO (Bolt <= 5.0) or LOGON (Bolt >= 5.1). Only the [basic] scheme
    is supported so far. *)

type config = {
  host : string;
  port : int;
  scheme : Addressing.scheme;
  connection_timeout : float;
  user_agent : string;
  auth : auth;
}
(** Target connection settings. The scheme selects TLS: [Bolt] plain, [Bolt_secure] TLS with
    certificate validation, [Bolt_self_signed] TLS without validation. Routing schemes ([Neo4j*])
    are rejected until routing is implemented. *)

type t = { transport : Transport.t; major : int; minor : int }
(** An established, authenticated Bolt connection: the transport plus the negotiated protocol
    version. *)

val default_user_agent : string
(** Default [user_agent] header for HELLO. *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  config ->
  (t, Errors.t) result
(** Establish a connection (over TLS when the scheme requires it), negotiate the Bolt protocol
    version and authenticate. For Bolt >= 5.1 the authentication is sent via LOGON after HELLO; for
    older versions it is inline in HELLO. [mono_clock] bounds the whole attempt and subsequent
    reads/writes by [config.connection_timeout].
    @return
      [Error _] for connection/handshake failures, for routing schemes (unsupported until routing is
      implemented), or for an authentication failure reported by the server. *)

val logon : t -> auth -> (unit, Errors.t) result
(** Re-authenticate with [auth] via LOGON (Bolt >= 5.1 only).
    @return [Error _] for older protocol versions or on server failure. *)

val logoff : t -> (unit, Errors.t) result
(** De-authenticate via LOGOFF (Bolt >= 5.1 only).
    @return [Error _] for older protocol versions or on server failure. *)

val close : t -> unit
(** Close the connection. *)
