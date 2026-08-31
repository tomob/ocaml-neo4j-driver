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
let goodbye_tag = 0x02
let run_tag = 0x10
let begin_tag = 0x11
let commit_tag = 0x12
let rollback_tag = 0x13
let route_tag = 0x66
let discard_tag = 0x2F
let pull_tag = 0x3F
let record_tag = 0x71
let success_tag = 0x70
let failure_tag = 0x7F
let ignored_tag = 0x7E

(* TELEMETRY (Bolt 5.4): a fire-and-forget notification about driver features
   used, sent before the query. *)
let telemetry_tag = 0x54

(* The wire name of an outgoing message tag, for the "C: <NAME>" log lines
   (like the Python driver's per-message logging). *)
let name_of_tag = function
  | t when t = hello_tag -> "HELLO"
  | t when t = logon_tag -> "LOGON"
  | t when t = logoff_tag -> "LOGOFF"
  | t when t = reset_tag -> "RESET"
  | t when t = goodbye_tag -> "GOODBYE"
  | t when t = run_tag -> "RUN"
  | t when t = begin_tag -> "BEGIN"
  | t when t = commit_tag -> "COMMIT"
  | t when t = rollback_tag -> "ROLLBACK"
  | t when t = route_tag -> "ROUTE"
  | t when t = discard_tag -> "DISCARD"
  | t when t = pull_tag -> "PULL"
  | t when t = record_tag -> "RECORD"
  | t when t = success_tag -> "SUCCESS"
  | t when t = failure_tag -> "FAILURE"
  | t when t = ignored_tag -> "IGNORED"
  | t when t = telemetry_tag -> "TELEMETRY"
  | tag -> Printf.sprintf "TAG_0x%02X" tag

(* The outgoing message log line: "C: <NAME> <fields>", with the HELLO/LOGON
   credentials redacted. The value rendering runs lazily inside the log
   closure, so it costs nothing when the io source is off. *)
let log_client transport ~tag ~fields =
  let id = Transport.id transport in
  if fields = [] then Log.debug Log.io (fun m -> m "[#%04X]  C: %s" id (name_of_tag tag))
  else
    Log.debug Log.io (fun m ->
        m "[#%04X]  C: %s %s" id (name_of_tag tag)
          (if tag = hello_tag || tag = logon_tag then
             Log.value_masked [ "credentials" ] (Packstream.List fields)
           else Log.value (Packstream.List fields)))

let send transport ~tag fields =
  log_client transport ~tag ~fields;
  Packstream.pack (Packstream.Structure (tag, fields)) |> Transport.write_message transport

let recv_fields transport =
  let* message = Transport.read_message transport in
  match Packstream.unpack message with
  | Error error ->
      Log.debug Log.io (fun m ->
          m "[#%04X]  _: Failed to unpack response: %s" (Transport.id transport)
            (Packstream.error_to_string error));
      Error (Errors.Service_unavailable (Packstream.error_to_string error))
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

(* The metadata of a message as a map: its single field, or an empty map when
   the message carries no fields. *)
let metadata_of_fields = function [] -> Packstream.Map [] | field :: _ -> field

(* A server FAILURE as a driver error, from its metadata map. *)
let failure_error metadata =
  let code = failure_code metadata in
  let message = Option.value ~default:"" (field_string "message" metadata) in
  let gql_status = field_string "gql_status" metadata in
  Errors.of_neo4j_code_with_gql_status ~gql_status ~code ~message

let respond transport =
  let* tag, payload = recv transport in
  match tag with
  | t when t = success_tag ->
      let metadata = Option.value ~default:(Packstream.Map []) payload in
      Log.debug Log.io (fun m ->
          m "[#%04X]  S: SUCCESS %s" (Transport.id transport) (Log.value metadata));
      Ok metadata
  | t when t = failure_tag ->
      let metadata = Option.value ~default:(Packstream.Map []) payload in
      Log.debug Log.io (fun m ->
          m "[#%04X]  S: FAILURE %s" (Transport.id transport) (Log.value metadata));
      Error (failure_error metadata)
  | t when t = ignored_tag ->
      Log.debug Log.io (fun m -> m "[#%04X]  S: IGNORED" (Transport.id transport));
      Error (Errors.Service_unavailable "Unexpected IGNORED response")
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

(* GOODBYE (Bolt 4.4+): the client tells the server it is closing the
   connection. No response is read (the server closes). *)
let goodbye transport = send transport ~tag:goodbye_tag []

(* ROUTE (Bolt 4.3+): ask the server for the routing table of a database. The
   fields are [routing_context, bookmarks, extra], where [extra] is the
   database name (Bolt 4.3) or a map of [db]/[imp_user] (Bolt 4.4+). *)
let route transport ~routing_context ~bookmarks ~extra =
  let* () = send transport ~tag:route_tag [ routing_context; bookmarks; extra ] in
  respond transport

(* Read the RECORD messages of a result up to its summary (SUCCESS/FAILURE/IGNORED).
   A RECORD carries its values as a single List field. The records delivered
   before a FAILURE/IGNORED are kept: the outcome is [Ok summary] on SUCCESS and
   [Error _] on a server failure, so a mid-stream error can be surfaced after
   the buffered records are consumed. A transport failure (the server closed
   mid-stream) is treated the same way: the records read so far are kept and the
   error becomes the outcome. *)
let rec collect_records acc transport =
  match recv_fields transport with
  | Error error -> Ok (List.rev acc, Error error)
  | Ok (tag, fields) -> (
      match tag with
      | t when t = record_tag ->
          (* Never log the record data, only its shape (like the Python
             driver's "S: RECORD * %d" with the field count). *)
          Log.debug Log.io (fun m ->
              m "[#%04X]  S: RECORD * %d" (Transport.id transport) (List.length fields));
          let record = match fields with [ Packstream.List values ] -> values | _ -> fields in
          collect_records (record :: acc) transport
      | t when t = success_tag ->
          Log.debug Log.io (fun m ->
              m "[#%04X]  S: SUCCESS %s" (Transport.id transport)
                (Log.value (metadata_of_fields fields)));
          Ok (List.rev acc, Ok (metadata_of_fields fields))
      | t when t = failure_tag ->
          Log.debug Log.io (fun m ->
              m "[#%04X]  S: FAILURE %s" (Transport.id transport)
                (Log.value (metadata_of_fields fields)));
          Ok (List.rev acc, Error (failure_error (metadata_of_fields fields)))
      | t when t = ignored_tag ->
          Log.debug Log.io (fun m -> m "[#%04X]  S: IGNORED" (Transport.id transport));
          Ok (List.rev acc, Error (Errors.Service_unavailable "Unexpected IGNORED response"))
      | tag ->
          Ok
            ( List.rev acc,
              Error
                (Errors.Service_unavailable
                   (Printf.sprintf "Unexpected Bolt message tag 0x%02x" tag)) ))

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
