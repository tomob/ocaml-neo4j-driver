(* Unit tests for TLS wrapping (bolt+s / bolt+ssc / mTLS) using a mock TLS server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let negotiate_tls tls net clock sw port =
  let address = Addressing.IPv4 ("127.0.0.1", port) in
  match Transport.connect net sw ~timeout:(Eio.Time.Timeout.seconds clock 1.0) ~tls address with
  | Error error -> Error error
  | Ok transport ->
      let result = Handshake.negotiate transport in
      Transport.close transport;
      result

let secure ?client_certificate trust =
  let client_certificate = Option.map (fun certificate () -> certificate) client_certificate in
  Transport.Secure { Tls_client.trust; host = "localhost"; client_certificate }

(* bolt+ssc: TLS handshake with no certificate validation succeeds. *)
let trust_all () =
  Test_tls_mock.with_mock
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      match negotiate_tls (secure Tls_client.Trust_all) net clock sw port with
      | Ok (major, minor) -> check (pair int int) "tls+bolt version" (5, 8) (major, minor)
      | Error error -> fail (Errors.to_string error))

(* bolt+s: a self-signed certificate is rejected against the system trust store. *)
let verify_rejects_self_signed () =
  Test_tls_mock.with_mock
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      match negotiate_tls (secure Tls_client.System) net clock sw port with
      | Ok _ -> fail "verify should reject a self-signed certificate"
      | Error _ -> ())

(* TLS client against a plain (non-TLS) server: the handshake cannot complete. *)
let tls_against_plain_server () =
  Test_mock.with_mock
    (Test_mock.V1 (4, 4))
    (fun net clock sw port ->
      match negotiate_tls (secure Tls_client.Trust_all) net clock sw port with
      | Ok _ -> fail "tls against a plain server should fail"
      | Error _ -> ())

let fixture_client_certificate () =
  Tls_client.{ chain = [ Test_tls_mock.certificate () ]; key = Test_tls_mock.private_key () }

(* mTLS: the server requires the committed client certificate. *)
let client_certificate_present () =
  Test_tls_mock.with_mock ~require_client_cert:true
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      let tls = secure ~client_certificate:(fixture_client_certificate ()) Tls_client.Trust_all in
      match negotiate_tls tls net clock sw port with
      | Ok (major, minor) -> check (pair int int) "tls+bolt version" (5, 8) (major, minor)
      | Error error -> fail (Errors.to_string error))

(* mTLS: without a client certificate the server rejects the handshake. *)
let client_certificate_absent () =
  Test_tls_mock.with_mock ~require_client_cert:true
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      match negotiate_tls (secure Tls_client.Trust_all) net clock sw port with
      | Ok _ -> fail "the server requires a client certificate"
      | Error _ -> ())

let tests =
  [
    ("[TLS] trust_all", [ test_case "bolt+ssc handshake over TLS" `Quick trust_all ]);
    ("[TLS] verify", [ test_case "bolt+s rejects self-signed" `Quick verify_rejects_self_signed ]);
    ( "[TLS] plain_server",
      [ test_case "tls against plain server fails" `Quick tls_against_plain_server ] );
    ( "[TLS] client_certificate",
      [ test_case "mTLS sends the client certificate" `Quick client_certificate_present ] );
    ( "[TLS] client_certificate absent",
      [ test_case "mTLS without a certificate is rejected" `Quick client_certificate_absent ] );
  ]
