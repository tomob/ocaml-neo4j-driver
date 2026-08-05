(* Minimal Bolt connection: TCP connect + handshake.

   See conn.ml for the implementation. *)

open Neodriver_core

type config = { host : string; port : int; scheme : Addressing.scheme; connection_timeout : float }
type t = { transport : Transport.t; major : int; minor : int }

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  config ->
  (t, Errors.t) result

val close : t -> unit
