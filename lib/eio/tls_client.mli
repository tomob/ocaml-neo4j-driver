(* TLS client wrapper for the bolt+s / bolt+ssc URI schemes. *)

open Neodriver_core

type mode =
  | Verify
  | Trust_all
      (** How the server certificate is validated:
          - [Verify]: against the operating system's trust store ([bolt+s]).
          - [Trust_all]: accept any certificate ([bolt+ssc]). *)

type config = { mode : mode; host : string }
(** [host] is used for SNI and hostname verification (ignored for [Trust_all]). *)

val wrap :
  config ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
  ([ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t, Errors.t) result
(** Wrap [socket] in TLS, completing the TLS handshake.
    @return
      [Error (Certificate_configuration_error _)] if the trust store or TLS configuration cannot be
      set up, or [Error (Service_unavailable _)] if the handshake fails. *)
