(* Bolt handshake: protocol version negotiation.

   See handshake.ml for the implementation. *)

open Neodriver_core

val magic : Bytes.t
val proposal : Bytes.t
val supported : (int * int) list
val negotiate : Transport.t -> (int * int, Errors.t) result
