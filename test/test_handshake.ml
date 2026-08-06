(* Unit tests for the Bolt handshake using a mock server (no live Neo4j). *)

open Neodriver
open Neodriver_eio
open Alcotest

let negotiate net clock sw port =
  let address = Addressing.IPv4 ("127.0.0.1", port) in
  match Transport.connect net sw ~timeout:(Eio.Time.Timeout.seconds clock 5.0) address with
  | Error error -> Error error
  | Ok transport ->
      let result = Handshake.negotiate transport in
      Transport.close transport;
      result

let v1 () =
  Test_mock.with_mock
    (Test_mock.V1 (4, 4))
    (fun net clock sw port ->
      match negotiate net clock sw port with
      | Ok (major, minor) -> check (pair int int) "v1 version" (4, 4) (major, minor)
      | Error error -> fail (Errors.to_string error))

let reject () =
  Test_mock.with_mock Test_mock.Reject (fun net clock sw port ->
      match negotiate net clock sw port with Ok _ -> fail "reject should fail" | Error _ -> ())

let http () =
  Test_mock.with_mock Test_mock.Http (fun net clock sw port ->
      match negotiate net clock sw port with Ok _ -> fail "http should fail" | Error _ -> ())

let manifest_unknown () =
  Test_mock.with_mock Test_mock.Manifest_unknown (fun net clock sw port ->
      match negotiate net clock sw port with
      | Ok _ -> fail "unknown manifest should fail"
      | Error _ -> ())

let manifest () =
  (* Offering (5,7,7) covers 5.0..5.7 -> the highest supported version is 5.7. *)
  Test_mock.with_mock
    (Test_mock.Manifest [ (5, 7, 7) ])
    (fun net clock sw port ->
      match negotiate net clock sw port with
      | Ok (major, minor) -> check (pair int int) "manifest version" (5, 7) (major, minor)
      | Error error -> fail (Errors.to_string error))

let manifest_highest () =
  (* Offerings (4,4,2) covers 4.2..4.4 and (6,0,0) covers 6.0 ->
     the highest supported version is 6.0. *)
  Test_mock.with_mock
    (Test_mock.Manifest [ (4, 4, 2); (6, 0, 0) ])
    (fun net clock sw port ->
      match negotiate net clock sw port with
      | Ok (major, minor) -> check (pair int int) "manifest highest" (6, 0) (major, minor)
      | Error error -> fail (Errors.to_string error))

let tests =
  [
    ("[Handshake] v1", [ test_case "v1 negotiation" `Quick v1 ]);
    ("[Handshake] reject", [ test_case "all versions rejected" `Quick reject ]);
    ("[Handshake] http", [ test_case "http endpoint" `Quick http ]);
    ( "[Handshake] manifest_unknown",
      [ test_case "unknown manifest version" `Quick manifest_unknown ] );
    ("[Handshake] manifest", [ test_case "manifest negotiation" `Quick manifest ]);
    ("[Handshake] manifest_highest", [ test_case "manifest picks highest" `Quick manifest_highest ]);
  ]
