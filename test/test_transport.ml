(* Unit tests for the transport framing using a mock echo server. *)

open Neodriver
open Neodriver_eio
open Alcotest

let connect net clock sw port =
  let address = Addressing.IPv4 ("127.0.0.1", port) in
  Transport.connect net clock sw ~timeout:5.0 address

(* write then read back the same bytes through the mock (echo). *)
let echo () =
  Test_mock.with_server
    (fun flow ->
      let data = Test_mock.read_exact flow 5 in
      Test_mock.write flow data)
    (fun net clock sw port ->
      match connect net clock sw port with
      | Error error -> fail (Errors.to_string error)
      | Ok transport ->
          (match Transport.write transport (Bytes.of_string "hello") with
          | Ok () -> ()
          | Error e -> fail (Errors.to_string e));
          let buf = Bytes.create 5 in
          (match Transport.read_exact transport buf 0 5 with
          | Ok () -> check string "echo" "hello" (Bytes.to_string buf)
          | Error e -> fail (Errors.to_string e));
          Transport.close transport)

(* server echoes the exact chunk stream back; client reassembles a large
   multi-chunk message. *)
let framing_round_trip () =
  let message = String.make 40000 'x' in
  Test_mock.with_server
    (fun flow ->
      let buffer = Buffer.create 1024 in
      let rec loop () =
        let size = Bytes.get_uint16_be (Bytes.of_string (Test_mock.read_exact flow 2)) 0 in
        Buffer.add_char buffer (Char.chr (size lsr 8));
        Buffer.add_char buffer (Char.chr (size land 0xff));
        if size = 0 then ()
        else begin
          Buffer.add_string buffer (Test_mock.read_exact flow size);
          loop ()
        end
      in
      loop ();
      Test_mock.write flow (Buffer.contents buffer))
    (fun net clock sw port ->
      match connect net clock sw port with
      | Error error -> fail (Errors.to_string error)
      | Ok transport ->
          (match Transport.write_message transport (Bytes.of_string message) with
          | Ok () -> ()
          | Error e -> fail (Errors.to_string e));
          (match Transport.read_message transport with
          | Ok got -> check string "framing round trip" message (Bytes.to_string got)
          | Error e -> fail (Errors.to_string e));
          Transport.close transport)

(* a NOOP (empty message) is skipped by read_message. *)
let noop_skip () =
  Test_mock.with_server
    (fun flow ->
      Test_mock.write flow "\x00\x00";
      Test_mock.write flow "\x00\x02hi\x00\x00")
    (fun net clock sw port ->
      match connect net clock sw port with
      | Error error -> fail (Errors.to_string error)
      | Ok transport ->
          (match Transport.write_message transport (Bytes.of_string "hi") with
          | Ok () -> ()
          | Error e -> fail (Errors.to_string e));
          (match Transport.read_message transport with
          | Ok got -> check string "noop skipped" "hi" (Bytes.to_string got)
          | Error e -> fail (Errors.to_string e));
          Transport.close transport)

let tests =
  [
    ("[Transport] echo", [ test_case "write/read_exact echo" `Quick echo ]);
    ("[Transport] framing_round_trip", [ test_case "multi-chunk framing" `Quick framing_round_trip ]);
    ("[Transport] noop_skip", [ test_case "NOOP skipping" `Quick noop_skip ]);
  ]
