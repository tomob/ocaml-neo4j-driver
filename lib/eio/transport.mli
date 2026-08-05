(* Eio-based TCP transport with Bolt message framing.

   See transport.ml for the implementation. *)

open Neodriver_core

type t
(** A TCP transport with a bounded read/write timeout and Bolt chunk framing. *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  float Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  ?timeout:float ->
  Addressing.t ->
  (t, Errors.t) result
(** Open a TCP connection to [address] (resolving host names as needed) and return a transport.
    Reads/writes on the result are bounded by [timeout] seconds (no timeout if omitted).
    @return
      [Error _] if the address cannot be resolved, the connection fails, or the connection times
      out. *)

val read_exact : t -> Bytes.t -> int -> int -> (unit, Errors.t) result
(** Read exactly [len] bytes into [buf] starting at offset [off].
    @return [Error _] on timeout or end-of-file. *)

val write : t -> Bytes.t -> (unit, Errors.t) result
(** Write [buf] to the connection.
    @return [Error _] on timeout or write failure. *)

val write_message : t -> Bytes.t -> (unit, Errors.t) result
(** Write a Bolt message, splitting it into 16 KiB chunks prefixed by their size and terminated by a
    0x0000 chunk. *)

val read_message : t -> (Bytes.t, Errors.t) result
(** Read one Bolt message, reassembling its chunks and skipping NOOP (empty) messages.
    @return [Error _] on timeout or end-of-file. *)

val close : t -> unit
(** Close the connection. *)
