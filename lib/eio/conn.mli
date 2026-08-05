(* Minimal Bolt connection: TCP connect + handshake.

   See conn.ml for the implementation. *)

open Neodriver_core

type config = { host : string; port : int; scheme : Addressing.scheme; connection_timeout : float }
(** Target connection settings. Only [Bolt] (plain TCP) is supported until TLS is implemented. *)

type t = { transport : Transport.t; major : int; minor : int }
(** An established Bolt connection: the transport plus the negotiated protocol version. *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  config ->
  (t, Errors.t) result
(** Establish a TCP connection and negotiate the Bolt protocol version. [connect] returns the
    connection (with [major] and [minor] set) on success.
    @return
      [Error _] for connection/handshake failures, or for TLS schemes (unsupported until TLS is
      implemented). *)

val close : t -> unit
(** Close the connection. *)
