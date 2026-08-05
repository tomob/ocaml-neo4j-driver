(* Bolt handshake: protocol version negotiation.

   See handshake.ml for the implementation. *)

open Neodriver_core

val magic : Bytes.t
(** The Bolt magic preamble sent before the version proposals. *)

val proposal : Bytes.t
(** The 16-byte handshake proposal: manifest-style (0x000001FF), Bolt 5.8-5.0, Bolt 4.4-4.2 and Bolt
    3.0. *)

val supported : (int * int) list
(** The versions this driver can handle, highest first. *)

val negotiate : Transport.t -> (int * int, Errors.t) result
(** Perform the handshake over [transport]: send the magic preamble and proposal, read the server
    response, and agree on a protocol version. Handles both the v1 reply and the v2 manifest
    (selecting the highest supported version within the server's offerings).
    @return
      [(major, minor)] on success, or an error for an HTTP endpoint, a rejection, or an unsupported
      manifest version. *)
