(* TLS client wrapper for the bolt+s / bolt+ssc URI schemes.

   Two trust modes are supported, mirroring the Neo4j drivers:
   - [Verify]: the server certificate is validated against the operating
     system's trust store and [host] is checked against the certificate. Used
     for [bolt+s].
   - [Trust_all]: no certificate validation. Used for [bolt+ssc] with
     self-signed certificates.

   Custom trust anchors (TrustCustomCAs) and client certificates (mTLS) are
   deferred to a later phase. *)

open Eio.Std
open Neodriver_core

let ( let* ) = Result.bind

type mode = Verify | Trust_all
type config = { mode : mode; host : string }

(* Trust every server certificate (bolt+ssc). *)
let trust_all ?ip:_ ~host:_ _ = Ok None

let authenticator = function
  | Verify -> (
      match Ca_certs.authenticator () with
      | Ok authenticator -> Ok authenticator
      | Error (`Msg msg) ->
          Error
            (Errors.Certificate_configuration_error
               (Printf.sprintf "Could not load system certificates: %s" msg)))
  | Trust_all -> Ok trust_all

(* The host is used for SNI and hostname verification. Addresses that are not
   valid domain names (e.g. IP literals) simply skip both. *)
let peer_name host = Result.to_option (Result.bind (Domain_name.of_string host) Domain_name.host)

let wrap config socket =
  let* authenticator = authenticator config.mode in
  match Tls.Config.client ~authenticator ~version:(`TLS_1_2, `TLS_1_3) () with
  | Error (`Msg msg) ->
      Error
        (Errors.Certificate_configuration_error (Printf.sprintf "Invalid TLS configuration: %s" msg))
  | Ok client -> (
      Mirage_crypto_rng_unix.use_default ();
      let tls =
        try Ok (Tls_eio.client_of_flow client ?host:(peer_name config.host) socket) with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            Error
              (Errors.Service_unavailable
                 (Printf.sprintf "TLS handshake failed: %s" (Printexc.to_string exn)))
      in
      match tls with
      | Error _ as error -> error
      | Ok tls -> Ok (tls :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r))
