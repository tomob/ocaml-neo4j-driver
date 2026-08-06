(* Bolt protocol messages.

   After the handshake, Bolt messages are PackStream structures whose tag byte
   identifies the message type; the chunk framing is handled by Transport. This
   module provides the message-level send/receive primitives, the interpretation
   of responses (SUCCESS / FAILURE / IGNORED), and convenience functions for the
   messages used so far (HELLO, LOGON, LOGOFF).

   Modeled on the Neo4j Python driver's _async/io/_bolt.py. *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

(* Message tags. *)
let hello_tag = 0x01
let logon_tag = 0x6A
let logoff_tag = 0x6B
let success_tag = 0x70
let failure_tag = 0x7F
let ignored_tag = 0x7E

let send transport ~tag fields =
  Packstream.pack (Packstream.Structure (tag, fields)) |> Transport.write_message transport

let recv transport =
  let* message = Transport.read_message transport in
  match Packstream.unpack message with
  | Error error -> Error (Errors.Service_unavailable (Packstream.error_to_string error))
  | Ok (Packstream.Structure (tag, fields)) ->
      let payload = match fields with [] -> None | field :: _ -> Some field in
      Ok (tag, payload)
  | Ok _ -> Error (Errors.Service_unavailable "Expected a Bolt message structure")

let field_string key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with
      | Some (Packstream.String value) -> Some value
      | _ -> None)
  | _ -> None

let respond transport =
  let* tag, payload = recv transport in
  match tag with
  | t when t = success_tag -> Ok (Option.value ~default:(Packstream.Map []) payload)
  | t when t = failure_tag ->
      let code = Option.value ~default:"" (Option.bind payload (field_string "code")) in
      let message = Option.value ~default:"" (Option.bind payload (field_string "message")) in
      Error (Errors.of_neo4j_code ~code ~message)
  | t when t = ignored_tag -> Error (Errors.Service_unavailable "Unexpected IGNORED response")
  | tag ->
      Error (Errors.Service_unavailable (Printf.sprintf "Unexpected Bolt message tag 0x%02x" tag))

let hello transport ~headers =
  let* () = send transport ~tag:hello_tag [ headers ] in
  respond transport

let logon transport ~auth =
  let* () = send transport ~tag:logon_tag [ auth ] in
  respond transport

let logoff transport =
  let* () = send transport ~tag:logoff_tag [] in
  respond transport
