(* Unit tests for TLS wrapping (bolt+s / bolt+ssc) using a mock TLS server. *)

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

(* bolt+ssc: TLS handshake with no certificate validation succeeds. *)
let trust_all () =
  Test_tls_mock.with_mock
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      match negotiate_tls (Transport.Trust_all "localhost") net clock sw port with
      | Ok (major, minor) -> check (pair int int) "tls+bolt version" (5, 8) (major, minor)
      | Error error -> fail (Errors.to_string error))

(* bolt+s: a self-signed certificate is rejected against the system trust store. *)
let verify_rejects_self_signed () =
  Test_tls_mock.with_mock
    (Test_mock.Manifest [ (5, 8, 8) ])
    (fun net clock sw port ->
      match negotiate_tls (Transport.Verify "localhost") net clock sw port with
      | Ok _ -> fail "verify should reject a self-signed certificate"
      | Error _ -> ())

(* TLS client against a plain (non-TLS) server: the handshake cannot complete. *)
let tls_against_plain_server () =
  Test_mock.with_mock
    (Test_mock.V1 (4, 4))
    (fun net clock sw port ->
      match negotiate_tls (Transport.Trust_all "localhost") net clock sw port with
      | Ok _ -> fail "tls against a plain server should fail"
      | Error _ -> ())

let tests =
  [
    ("[TLS] trust_all", [ test_case "bolt+ssc handshake over TLS" `Quick trust_all ]);
    ("[TLS] verify", [ test_case "bolt+s rejects self-signed" `Quick verify_rejects_self_signed ]);
    ( "[TLS] plain_server",
      [ test_case "tls against plain server fails" `Quick tls_against_plain_server ] );
  ]
