(* Public interface of the neodriver_eio library.

   Curated public surface: only the modules aliased here are part of the
   public API. *)

module Driver = Driver
(** Entry point of the Eio backend (placeholder). *)

module Transport = Transport
(** Eio-based TCP transport with Bolt message framing. *)

module Handshake = Handshake
(** Bolt handshake (protocol version negotiation). *)

module Conn = Conn
(** Minimal Bolt connection (TCP connect + handshake). *)
