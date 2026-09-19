(** TLS client wrapper for the bolt+s / bolt+ssc URI schemes. *)

open Neodriver_core

type trust =
  | System
  | Trust_all
  | Custom of X509.Certificate.t list
      (** How the server certificate is validated:
          - [System]: against the operating system's trust store ([bolt+s]).
          - [Trust_all]: accept any certificate ([bolt+ssc]).
          - [Custom certs]: only the given trust anchors (the explicit [trusted_certificates]
            configuration). The [host] is still checked against the leaf certificate. *)

type client_certificate = {
  chain : X509.Certificate.t list;  (** The certificate chain, leaf first. *)
  key : X509.Private_key.t;  (** The private key matching the leaf certificate. *)
}
(** A client certificate (mTLS) presented to the server. *)

type config = {
  trust : trust;
  host : string;
  client_certificate : (unit -> client_certificate) option;
      (** Supplies the client certificate for the handshake. A provider (rather than a value) so a
          rotating certificate is re-read on every connection. *)
}
(** [host] is used for SNI and hostname verification (ignored for [Trust_all]). *)

val wrap :
  config ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
  ([ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t, Errors.t) result
(** Wrap [socket] in TLS, completing the TLS handshake.
    @return
      [Error (Certificate_configuration_error _)] if the trust store or TLS configuration cannot be
      set up, or [Error (Service_unavailable _)] if the handshake fails. *)
