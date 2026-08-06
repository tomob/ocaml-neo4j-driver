(* Eio-based TCP transport with Bolt message framing.

   See transport.ml for the implementation. *)

open Neodriver_core

type t
(** A TCP transport with a bounded read/write timeout and Bolt chunk framing. *)

type tls_mode =
  | Plain
  | Verify of string
  | Trust_all of string
      (** How the connection is secured with TLS:
          - [Plain]: no TLS.
          - [Verify host]: wrap the connection in TLS, validating the server certificate against the
            system trust store and checking [host] ([bolt+s]).
          - [Trust_all host]: wrap the connection in TLS without validating the server certificate
            ([bolt+ssc]). *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Eio.Switch.t ->
  ?timeout:Eio.Time.Timeout.t ->
  ?tls:tls_mode ->
  Addressing.t ->
  (t, Errors.t) result
(** Open a TCP connection to [address] (resolving host names as needed) and return a transport. If
    [tls] is [Verify _] or [Trust_all _], the connection is wrapped in TLS before returning. The TCP
    connect and TLS handshake share a single [timeout] deadline; reads/writes on the result are
    bounded by the same deadline. The default ([Eio.Time.Timeout.none]) imposes no deadline.
    @return
      [Error _] if the address cannot be resolved, the connection or TLS handshake fails, or the
      operation times out. *)

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
