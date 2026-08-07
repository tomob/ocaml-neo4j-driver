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
let reset_tag = 0x0F
let run_tag = 0x10
let begin_tag = 0x11
let commit_tag = 0x12
let rollback_tag = 0x13
let discard_tag = 0x2F
let pull_tag = 0x3F
let record_tag = 0x71
let success_tag = 0x70
let failure_tag = 0x7F
let ignored_tag = 0x7E

let send transport ~tag fields =
  Packstream.pack (Packstream.Structure (tag, fields)) |> Transport.write_message transport

let recv_fields transport =
  let* message = Transport.read_message transport in
  match Packstream.unpack message with
  | Error error -> Error (Errors.Service_unavailable (Packstream.error_to_string error))
  | Ok (Packstream.Structure (tag, fields)) -> Ok (tag, fields)
  | Ok _ -> Error (Errors.Service_unavailable "Expected a Bolt message structure")

let recv transport =
  let* tag, fields = recv_fields transport in
  let payload = match fields with [] -> None | field :: _ -> Some field in
  Ok (tag, payload)

let field_string key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with
      | Some (Packstream.String value) -> Some value
      | _ -> None)
  | _ -> None

(* Bolt 6 renamed the FAILURE code key to [neo4j_code]; older versions use
   [code]. *)
let failure_code payload =
  match field_string "neo4j_code" payload with
  | Some code -> code
  | None -> Option.value ~default:"" (field_string "code" payload)

let respond transport =
  let* tag, payload = recv transport in
  match tag with
  | t when t = success_tag -> Ok (Option.value ~default:(Packstream.Map []) payload)
  | t when t = failure_tag ->
      let code = failure_code (Option.value ~default:(Packstream.Map []) payload) in
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

let run transport ~query ~parameters ~extra =
  let* () = send transport ~tag:run_tag [ Packstream.String query; parameters; extra ] in
  respond transport

let begin_ transport ~extra =
  let* () = send transport ~tag:begin_tag [ extra ] in
  respond transport

let commit transport =
  let* () = send transport ~tag:commit_tag [] in
  respond transport

let rollback transport =
  let* () = send transport ~tag:rollback_tag [] in
  respond transport

(* Read the RECORD messages of a result up to its summary (SUCCESS/FAILURE/IGNORED).
   A RECORD carries its values as a single List field. The records delivered
   before a FAILURE/IGNORED are kept: the outcome is [Ok summary] on SUCCESS and
   [Error _] on a server failure, so a mid-stream error can be surfaced after
   the buffered records are consumed. *)
let rec collect_records acc transport =
  let* tag, fields = recv_fields transport in
  match tag with
  | t when t = record_tag ->
      let record = match fields with [ Packstream.List values ] -> values | _ -> fields in
      collect_records (record :: acc) transport
  | t when t = success_tag ->
      let metadata = match fields with [] -> Packstream.Map [] | field :: _ -> field in
      Ok (List.rev acc, Ok metadata)
  | t when t = failure_tag ->
      let metadata = match fields with [] -> Packstream.Map [] | field :: _ -> field in
      let code = failure_code metadata in
      let message = Option.value ~default:"" (field_string "message" metadata) in
      Ok (List.rev acc, Error (Errors.of_neo4j_code ~code ~message))
  | t when t = ignored_tag ->
      Ok (List.rev acc, Error (Errors.Service_unavailable "Unexpected IGNORED response"))
  | tag ->
      Ok
        ( List.rev acc,
          Error
            (Errors.Service_unavailable (Printf.sprintf "Unexpected Bolt message tag 0x%02x" tag))
        )

let pull transport ~extra =
  let* () = send transport ~tag:pull_tag [ extra ] in
  collect_records [] transport

let discard transport ~extra =
  let* () = send transport ~tag:discard_tag [ extra ] in
  collect_records [] transport

let metadata_bool key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with Some (Packstream.Bool value) -> value | _ -> false)
  | _ -> false

let metadata_has_more = metadata_bool "has_more"
