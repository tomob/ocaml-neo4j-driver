(* Minimal Bolt connection: TCP connect (+ optional TLS) + handshake + HELLO/auth.

   A [t] represents an established, authenticated Bolt connection (transport +
   agreed protocol version). Authentication is sent inline in HELLO for Bolt
   <= 5.0, or via a separate LOGON message for Bolt >= 5.1. Routing
   (neo4j:// schemes) is not implemented yet. *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

type auth = { scheme : string; principal : string; credentials : string }

type config = {
  host : string;
  port : int;
  scheme : Addressing.scheme;
  connection_timeout : float;
  user_agent : string;
  auth : auth;
}

type t = {
  transport : Transport.t;
  major : int;
  minor : int;
  state : State.t ref;
  server_agent : string option ref;
  address : Addressing.t;
  current_auth : auth option ref;
}

let default_user_agent = "ocaml-neo4j-driver/0.1.0"

(* The basic authentication token: scheme [basic] with the given principal and
   credentials. *)
let basic_auth ?(principal = "neo4j") ?(credentials = "") () =
  { scheme = "basic"; principal; credentials }

let capabilities_of t = Capabilities.of_version t.major t.minor
let re_auth_of major minor = (Capabilities.of_version major minor).supports_re_auth

let timeout_of_config clock config =
  if config.connection_timeout = infinity then Eio.Time.Timeout.none
  else Eio.Time.Timeout.seconds clock config.connection_timeout

(* The bolt_agent header is sent from Bolt 5.3. *)
let bolt_agent_version major minor = major > 5 || (major = 5 && minor >= 3)

let tls_of_scheme host = function
  | Addressing.Bolt -> Ok Transport.Plain
  | Addressing.Bolt_secure -> Ok (Transport.Verify host)
  | Addressing.Bolt_self_signed -> Ok (Transport.Trust_all host)
  | Addressing.Neo4j | Addressing.Neo4j_secure | Addressing.Neo4j_self_signed ->
      Error (Errors.Service_unavailable "Routing (neo4j://) is not supported yet")

let bolt_agent user_agent =
  Packstream.Map
    [
      ("product", Packstream.String user_agent);
      ("platform", Packstream.String Sys.os_type);
      ("language", Packstream.String "OCaml");
      ("language_details", Packstream.String Sys.ocaml_version);
    ]

let auth_map (auth : auth) =
  Packstream.Map
    [
      ("scheme", Packstream.String auth.scheme);
      ("principal", Packstream.String auth.principal);
      ("credentials", Packstream.String auth.credentials);
    ]

let hello_headers (config : config) major minor =
  let base = [ ("user_agent", Packstream.String config.user_agent) ] in
  let bolt_agent =
    if bolt_agent_version major minor then [ ("bolt_agent", bolt_agent config.user_agent) ] else []
  in
  let auth =
    if re_auth_of major minor then []
    else
      [
        ("scheme", Packstream.String config.auth.scheme);
        ("principal", Packstream.String config.auth.principal);
        ("credentials", Packstream.String config.auth.credentials);
      ]
  in
  Packstream.Map (base @ bolt_agent @ auth)

let version t = (t.major, t.minor)
let server_state t = !(t.state)
let address t = t.address

(* A hydration scope for this connection's protocol version (V1 = Bolt 3/4,
   V2 = Bolt 5, V3 = Bolt 6). *)
let hydration t =
  let version =
    match t.major with 3 | 4 -> Hydration.V1 | 5 -> Hydration.V2 | _ -> Hydration.V3
  in
  Hydration.create version

(* Send a RESET and read the response; the server returns to READY. *)
let reset t =
  let* () = Bolt.send t.transport ~tag:Bolt.reset_tag [] in
  match Bolt.respond t.transport with
  | Ok _ ->
      t.state := State.Ready;
      Ok ()
  | Error _ as error -> error

(* Send [action] (a Bolt message that already reads its response) and update the
   server state. If the server is in the FAILED state, a RESET is sent first.
   [has_more result] decides whether the state stays in STREAMING after the
   message (used by PULL/DISCARD). *)
let request ?(has_more = fun _ -> false) t ~message ~re_auth action =
  let* () = if State.failed !(t.state) then reset t else Ok () in
  match action () with
  | Ok result ->
      t.state := State.server_transition ~re_auth ~has_more:(has_more result) !(t.state) message;
      Ok result
  | Error _ as error ->
      t.state := State.Failed;
      error

(* Part 1 of the connection pipeline: open a TCP (optionally TLS) transport to a
   single address. *)
(* let connect_transport net sw ~timeout ~tls address = Transport.connect net sw ~timeout ~tls address *)

(* Record the server agent reported in the HELLO response, if any. *)
let set_server_agent conn = function
  | Packstream.Map fields -> (
      match List.assoc_opt "server" fields with
      | Some (Packstream.String agent) -> conn.server_agent := Some agent
      | _ -> ())
  | _ -> ()

(* Part 3 of the connection pipeline: authenticate with HELLO (+ a separate
   LOGON for Bolt >= 5.1). On success the connection carries the token. *)
let authenticate conn config =
  let major, minor = version conn in
  let re_auth = re_auth_of major minor in
  let* hello_metadata =
    request conn ~message:State.Hello ~re_auth (fun () ->
        Bolt.hello conn.transport ~headers:(hello_headers config major minor))
  in
  set_server_agent conn hello_metadata;
  let* () =
    if re_auth then
      request conn ~message:State.Logon ~re_auth (fun () ->
          Bolt.logon conn.transport ~auth:(auth_map config.auth))
      |> Result.map (fun _ -> ())
    else Ok ()
  in
  conn.current_auth := Some config.auth;
  Ok ()

let connect ?resolver net clock sw config =
  let* tls = tls_of_scheme config.host config.scheme in
  (* [config.host] carries an IPv6 literal without brackets (the URI parser
     strips them), so bracket it again or the re-parse would split the port off
     the last colon and mistype the address as IPv4. *)
  let host_port =
    if String.contains config.host ':' then Printf.sprintf "[%s]:%d" config.host config.port
    else Printf.sprintf "%s:%d" config.host config.port
  in
  let* initial = Addressing.parse ~default_host:"localhost" ~default_port:7687 host_port in
  let* addresses = match resolver with Some resolve -> resolve initial | None -> Ok [ initial ] in
  let connect_single address =
    let* transport =
      Transport.connect net sw ~timeout:(timeout_of_config clock config) ~tls address
    in
    let* major, minor = Handshake.negotiate transport in
    Ok (transport, major, minor, address)
  in
  let rec attempt failed errors = function
    | [] ->
        let failures = { Errors.last = List.hd errors; all = List.rev errors } in
        Error
          (Errors.Service_unavailable
             (Addressing.connect_failure_message ~address:initial ~resolved:failed ~failures))
    | address :: rest -> (
        match connect_single address with
        | Ok connected -> Ok connected
        | Error error -> attempt (Addressing.to_string address :: failed) (error :: errors) rest)
  in
  let* transport, major, minor, address = attempt [] [] addresses in
  let conn =
    {
      transport;
      major;
      minor;
      state = ref State.Connected;
      server_agent = ref None;
      address;
      current_auth = ref None;
    }
  in
  let* () = authenticate conn config in
  Ok conn

let logon t auth =
  let re_auth = re_auth_of t.major t.minor in
  if not re_auth then
    Error (Errors.Service_unavailable "LOGON is not supported by this protocol version")
  else
    let* _ =
      request t ~message:State.Logon ~re_auth (fun () ->
          Bolt.logon t.transport ~auth:(auth_map auth))
    in
    Ok ()

let logoff t =
  let re_auth = re_auth_of t.major t.minor in
  if not re_auth then
    Error (Errors.Service_unavailable "LOGOFF is not supported by this protocol version")
  else
    let* _ = request t ~message:State.Logoff ~re_auth (fun () -> Bolt.logoff t.transport) in
    Ok ()

type run_metadata = {
  fields : string list;
  qid : int option;
  bookmark : string option;
  t_first : int option;
}

let map_fields key = function Packstream.Map fields -> List.assoc_opt key fields | _ -> None

let string_list = function
  | Packstream.List values ->
      List.fold_right
        (fun v acc -> match v with Packstream.String s -> s :: acc | _ -> acc)
        values []
  | _ -> []

let string_opt = function Some (Packstream.String v) -> Some v | _ -> None
let int_opt = function Some (Packstream.Int v) -> Some (Int64.to_int v) | _ -> None

let run_metadata_of metadata =
  let fields =
    match map_fields "fields" metadata with Some value -> string_list value | None -> []
  in
  let qid = map_fields "qid" metadata |> int_opt in
  let bookmark = map_fields "bookmark" metadata |> string_opt in
  let t_first = map_fields "t_first" metadata |> int_opt in
  { fields; qid; bookmark; t_first }

(* The extra map shared by BEGIN and auto-commit RUN: mode, db, impersonation,
   bookmarks, tx_metadata and tx_timeout (milliseconds). *)
let build_extra ?mode ?db ?imp_user ?bookmarks ?timeout ?metadata () =
  let items =
    List.filter_map Fun.id
      [
        Option.bind mode (function
          | Config.Read -> Some ("mode", Packstream.String "r")
          | Config.Write -> None);
        Option.map (fun db -> ("db", Packstream.String db)) db;
        Option.map (fun user -> ("imp_user", Packstream.String user)) imp_user;
        Option.map
          (fun bookmarks ->
            ("bookmarks", Packstream.List (List.map (fun b -> Packstream.String b) bookmarks)))
          bookmarks;
        Option.map
          (fun seconds -> ("tx_timeout", Packstream.Int (Int64.of_float (seconds *. 1000.0))))
          timeout;
        Option.map (fun metadata -> ("tx_metadata", Packstream.Map metadata)) metadata;
      ]
  in
  Packstream.Map items

let run ?mode ?db ?bookmarks ?timeout ?metadata t ~hydration ~query ~parameters =
  let parameters =
    Packstream.Map
      (List.map (fun (name, value) -> (name, Hydration.dehydrate hydration value)) parameters)
  in
  let metadata =
    Option.map
      (List.map (fun (name, value) -> (name, Hydration.dehydrate hydration value)))
      metadata
  in
  let* metadata_response =
    request t ~message:State.Run ~re_auth:(re_auth_of t.major t.minor) (fun () ->
        Bolt.run t.transport ~query ~parameters
          ~extra:(build_extra ?mode ?db ?bookmarks ?timeout ?metadata ()))
  in
  Ok (run_metadata_of metadata_response)

let pull_extra ?(n = -1) ?qid () =
  let extra = [ ("n", Packstream.Int (Int64.of_int n)) ] in
  let extra =
    match qid with Some qid -> ("qid", Packstream.Int (Int64.of_int qid)) :: extra | None -> extra
  in
  Packstream.Map extra

let outcome_has_more = function Ok summary -> Bolt.metadata_has_more summary | Error _ -> false

let pull ?n ?qid t ~hydration =
  let re_auth = re_auth_of t.major t.minor in
  match
    request
      ~has_more:(fun (_, outcome) -> outcome_has_more outcome)
      t ~message:State.Pull ~re_auth
      (fun () -> Bolt.pull t.transport ~extra:(pull_extra ?n ?qid ()))
  with
  | Error _ as error -> error
  | Ok (records, outcome) ->
      let records = List.map (List.map (Hydration.hydrate hydration)) records in
      (match outcome with Error _ -> t.state := State.Failed | Ok _ -> ());
      Ok (records, outcome)

let discard ?n ?qid t =
  let re_auth = re_auth_of t.major t.minor in
  let* _records, outcome =
    request
      ~has_more:(fun (_, outcome) -> outcome_has_more outcome)
      t ~message:State.Discard ~re_auth
      (fun () -> Bolt.discard t.transport ~extra:(pull_extra ?n ?qid ()))
  in
  match outcome with
  | Ok _ -> Ok ()
  | Error _ as error ->
      t.state := State.Failed;
      error

(* A lazily-streamed result on a connection: RUN is sent immediately, records
   are pulled in batches on demand. [records] is kept in reverse for O(1)
   prepend; the terminal state is a [summary] (normal end) or an [error]
   (a server failure, surfaced after the buffered records are consumed). *)
(* A lazily-streamed result on a connection: RUN is sent immediately, records
   are pulled in batches on demand. [records] is kept in reverse for O(1)
   prepend; the terminal state is a [summary] (normal end) or an [error]
   (a server failure, surfaced after the buffered records are consumed).
   [on_complete] fires with the final summary once the stream ends normally
   (e.g. to capture an auto-commit bookmark). *)
type stream = {
  conn : t;
  run_metadata : run_metadata;
  hydration : Hydration.t;
  mutable records : Values.t list list;
  mutable summary : Packstream.value option;
  mutable error : Errors.t option;
  mutable has_more : bool;
  on_complete : Packstream.value -> unit;
}

let stream ?(on_complete = fun _ -> ()) conn ~hydration ~run_metadata =
  {
    conn;
    run_metadata;
    hydration;
    records = [];
    summary = None;
    error = None;
    has_more = true;
    on_complete;
  }

let connection s = s.conn
let buffered s = List.rev s.records
let has_more s = s.has_more
let error s = s.error
let summary s = s.summary
let run_metadata s = s.run_metadata

let pull_stream ?n s =
  if not s.has_more then Ok []
  else
    let* records, outcome = pull ?n ?qid:s.run_metadata.qid s.conn ~hydration:s.hydration in
    s.records <- List.rev_append records s.records;
    match outcome with
    | Error error ->
        s.has_more <- false;
        s.error <- Some error;
        Ok records
    | Ok summary ->
        let more = Bolt.metadata_has_more summary in
        s.has_more <- more;
        if not more then begin
          s.summary <- Some summary;
          s.on_complete summary
        end;
        Ok records

(* Pull a stream to its end, best effort: a transport failure stops the drain
   (the failure is left on the stream; the connection is recovered by the next
   request's RESET). *)
let rec drain_stream s =
  if has_more s then match pull_stream s with Ok _ -> drain_stream s | Error _ -> ()

let begin_ t ~extra =
  let re_auth = re_auth_of t.major t.minor in
  let* _ = request t ~message:State.Begin ~re_auth (fun () -> Bolt.begin_ t.transport ~extra) in
  Ok ()

let commit t =
  let re_auth = re_auth_of t.major t.minor in
  let* metadata = request t ~message:State.Commit ~re_auth (fun () -> Bolt.commit t.transport) in
  Ok metadata

(* Roll back the current transaction. On a FAILED connection the server already
   discarded the transaction implicitly, so a RESET suffices (a ROLLBACK would
   be IGNORED after the RESET performed by [request]). *)
let rollback t =
  let re_auth = re_auth_of t.major t.minor in
  if State.failed !(t.state) then
    let* () = reset t in
    Ok ()
  else
    let* _ = request t ~message:State.Rollback ~re_auth (fun () -> Bolt.rollback t.transport) in
    Ok ()

let server_agent t = !(t.server_agent)
let capabilities t = capabilities_of t
let current_auth t = !(t.current_auth)

(* Re-authenticate when [auth] differs from the current token: LOGOFF then
   LOGON (Bolt >= 5.1). Returns whether the token changed. *)
let re_auth t auth =
  if !(t.current_auth) = Some auth then Ok false
  else if not (re_auth_of t.major t.minor) then
    Error (Errors.Service_unavailable "Re-authentication is not supported by this protocol version")
  else
    let* () =
      request t ~message:State.Logoff ~re_auth:true (fun () -> Bolt.logoff t.transport)
      |> Result.map (fun _ -> ())
    in
    let* () =
      request t ~message:State.Logon ~re_auth:true (fun () ->
          Bolt.logon t.transport ~auth:(auth_map auth))
      |> Result.map (fun _ -> ())
    in
    t.current_auth := Some auth;
    Ok true

let mark_unauthenticated t = t.current_auth := None
let close t = Transport.close t.transport
