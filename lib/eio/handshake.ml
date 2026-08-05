(* Bolt handshake: protocol version negotiation.

   The client sends a magic preamble followed by four version proposals
   (manifest-style for Bolt 5.4+ and fixed ranges for 5.x/4.x/3.x). The server
   replies with either a 4-byte agreed version (Bolt 3/4/5, v1) or, when the
   last byte is 0xFF, a manifest (v2) describing the ranges it supports, to
   which the client replies with its chosen version and capabilities.

   Modeled on the Neo4j Python driver's _async/io/_bolt_socket.py. *)

open Neodriver_core

let ( let* ) = Result.bind
let magic = Bytes.of_string "\x60\x60\xb0\x17"

(* 16-byte proposal: manifest (0x000001FF), 5.8-5.0 (range 8),
   4.4-4.2 (range 2), 3.0. *)
let proposal = Bytes.of_string "\x00\x00\x01\xff\x00\x08\x08\x05\x00\x02\x04\x04\x00\x00\x00\x03"

(* Versions we can handle, highest first. *)
let supported =
  [ (6, 1); (6, 0) ]
  @ List.init 9 (fun i -> (5, 8 - i))
  @ List.init 3 (fun i -> (4, 4 - i))
  @ [ (3, 0) ]

(* Read a variable-length integer (LEB128-style) from the connection.

   Bytes are read one at a time; each contributes its low 7 bits to the
   result, placed at the current bit position. The high bit (0x80) of a byte
   signals that more bytes follow, so the loop continues at the next 7-bit
   group (shift += 7). Decoding stops at the first byte without the
   continuation bit. This is the encoding used by the Bolt manifest handshake
   for the number of offerings and the capabilities. *)
let read_varint transport =
  let byte = Bytes.create 1 in
  let rec go shift acc =
    let* () = Transport.read_exact transport byte 0 1 in
    let b = Bytes.get_uint8 byte 0 in
    let acc = acc lor ((b land 0x7F) lsl shift) in
    if b land 0x80 <> 0 then go (shift + 7) acc else Ok acc
  in
  go 0 0

let negotiate_manifest transport =
  let* count = read_varint transport in
  let buf = Bytes.create 4 in
  let rec read_offerings acc = function
    | 0 -> Ok (List.rev acc)
    | n ->
        let* () = Transport.read_exact transport buf 0 4 in
        let major = Bytes.get_uint8 buf 3 in
        let minor = Bytes.get_uint8 buf 2 in
        let range = Bytes.get_uint8 buf 1 in
        read_offerings ((major, minor, range) :: acc) (n - 1)
  in
  let* offerings = read_offerings [] count in
  let* _capabilities = read_varint transport in
  let chosen =
    List.find_opt
      (fun (c_major, c_minor) ->
        List.exists
          (fun (o_major, o_minor, o_range) ->
            c_major = o_major && c_minor >= o_minor - o_range && c_minor <= o_minor)
          offerings)
      supported
  in
  match chosen with
  | None -> Error (Errors.Service_unavailable "No protocol version in common")
  | Some (major, minor) ->
      let reply =
        Bytes.of_string
          ("\x00\x00" ^ String.make 1 (Char.chr minor) ^ String.make 1 (Char.chr major))
      in
      let* () = Transport.write transport reply in
      (* chosen capabilities: none *)
      let* () = Transport.write transport (Bytes.of_string "\x00") in
      Ok (major, minor)

let negotiate transport =
  let* () = Transport.write transport (Bytes.cat magic proposal) in
  let response = Bytes.create 4 in
  let* () = Transport.read_exact transport response 0 4 in
  if response = Bytes.of_string "HTTP" then
    Error (Errors.Service_unavailable "Endpoint looks like HTTP, not Bolt")
  else if Bytes.get_uint8 response 3 = 0xFF then begin
    let manifest_version = Bytes.get_uint8 response 2 in
    if manifest_version <> 1 then
      Error
        (Errors.Service_unavailable
           (Printf.sprintf "Unsupported Bolt handshake manifest version %d" manifest_version))
    else negotiate_manifest transport
  end
  else if response = Bytes.of_string "\x00\x00\x00\x00" then
    Error (Errors.Service_unavailable "Server rejected all protocol versions")
  else begin
    let major = Bytes.get_uint8 response 3 in
    let minor = Bytes.get_uint8 response 2 in
    Ok (major, minor)
  end
