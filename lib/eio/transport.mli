(* Eio-based TCP transport with Bolt message framing.

   See transport.ml for the implementation. *)

open Neodriver_core

type t

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  ?timeout:float ->
  Addressing.t ->
  (t, Errors.t) result

val read_exact : t -> Bytes.t -> int -> int -> (unit, Errors.t) result
val write : t -> Bytes.t -> (unit, Errors.t) result
val write_message : t -> Bytes.t -> (unit, Errors.t) result
val read_message : t -> (Bytes.t, Errors.t) result
val close : t -> unit
