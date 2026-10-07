(** Eio-based TCP transport with Bolt message framing.

    See transport.ml for the implementation. *)

open Neodriver_core

type t
(** A TCP transport with a bounded read/write timeout, a TCP keep-alive flag and Bolt chunk framing.
*)

val id : t -> int
(** The connection id of this transport (rendered as "[#XXXX]" in log lines; see [Log.conn]). *)

val keep_alive : t -> bool
(** Whether TCP keep-alive ([SO_KEEPALIVE]) is enabled on the connection's socket. *)

val set_read_timeout : t -> Eio.Time.Timeout.t -> unit
(** Replace the timeout bounding reads (and writes) on the connection. The server advertises a
    receive timeout through the [connection.recv_timeout_seconds] HELLO hint, overriding the
    driver-configured default for that connection. *)

type tls_mode =
  | Plain
  | Secure of Tls_client.config
      (** How the connection is secured with TLS:
          - [Plain]: no TLS.
          - [Secure config]: wrap the connection in TLS with [config]'s trust anchors and host
            (system trust store for [bolt+s], trust-all for [bolt+ssc], or explicit custom
            certificates). *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Eio.Switch.t ->
  ?timeout:Eio.Time.Timeout.t ->
  ?keep_alive:bool ->
  ?tls:tls_mode ->
  Addressing.t ->
  (t, Errors.t) result
(** Open a TCP connection to [address] (resolving host names as needed) and return a transport. Each
    resolved address (IPv4 and IPv6) is tried in turn until one connects. If [tls] is [Secure _],
    the connection is wrapped in TLS before returning. [keep_alive] (default [true]) sets the
    [SO_KEEPALIVE] socket option on the TCP socket (before any TLS wrap); a failure to set it is
    treated like a connection failure for that address. The TCP connect and TLS handshake share a
    single [timeout] deadline; reads/writes on the result are bounded by the same deadline. The
    default ([Eio.Time.Timeout.none]) imposes no deadline.
    @return
      [Error _] if the address cannot be resolved, if every resolved address fails to connect or
      complete the TLS handshake (all failures are aggregated into the [Service_unavailable]
      message), or if the operation times out. *)

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
