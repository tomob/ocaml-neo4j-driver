(* Minimal Bolt connection: TCP connect (+ optional TLS) + handshake + HELLO/auth.

   A [t] represents an established, authenticated Bolt connection (transport +
   agreed protocol version). Authentication is sent inline in HELLO for Bolt
   <= 5.0, or via a separate LOGON message for Bolt >= 5.1. Routing
   (neo4j:// schemes) is handled by the Driver's routing cluster (cluster.ml). *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

type auth = Auth_manager.token

type config = {
  host : string;
  port : int;
  scheme : Addressing.scheme;
  connection_timeout : float;
  user_agent : string;
  auth : auth;
  routing_context : (string * string) list option;
  telemetry_disabled : bool;
}

type t = {
  transport : Transport.t;
  major : int;
  minor : int;
  state : State.t ref;
  server_agent : string option ref;
  address : Addressing.t;
  current_auth : auth option ref;
  auth_manager : Auth_manager.t option ref;
  on_error : (t -> Errors.t -> Errors.t) ref;
  last_database : string option ref;
  ssr_enabled : bool ref;
  telemetry_enabled : bool ref;
  pipelined_pull : bool ref;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  utc_patch : bool ref;
}

let default_user_agent = "ocaml-neo4j-driver/0.3.0"

(* The bolt_agent product: the driver's own product string (independent of the
   session user agent, like the Python driver's). *)
let bolt_agent_product = default_user_agent

(* The basic authentication token: scheme [basic] with the given principal and
   credentials. *)
let basic_auth ?(principal = "neo4j") ?(credentials = "") ?realm () =
  Auth_manager.basic_auth ~principal ~credentials ?realm ()

(* A bearer (SSO) token: only the token as credentials. *)
let bearer_auth = Auth_manager.bearer_auth
let capabilities_of t = Capabilities.of_version t.major t.minor
let re_auth_of major minor = (Capabilities.of_version major minor).supports_re_auth

let timeout_of_config clock config =
  if config.connection_timeout = infinity then Eio.Time.Timeout.none
  else Eio.Time.Timeout.seconds clock config.connection_timeout

(* The bolt_agent header is sent from Bolt 5.3. *)
let bolt_agent_version major minor = major > 5 || (major = 5 && minor >= 3)

let tls_of_scheme host = function
  | Addressing.Bolt | Addressing.Neo4j -> Ok Transport.Plain
  | Addressing.Bolt_secure | Addressing.Neo4j_secure -> Ok (Transport.Verify host)
  | Addressing.Bolt_self_signed | Addressing.Neo4j_self_signed -> Ok (Transport.Trust_all host)

let bolt_agent () =
  Packstream.Map
    [
      ("product", Packstream.String bolt_agent_product);
      ("platform", Packstream.String Sys.os_type);
      ("language", Packstream.String "OCaml");
      ("language_details", Packstream.String Sys.ocaml_version);
    ]

let auth_map (auth : auth) = Auth_manager.to_map auth

let hello_headers (config : config) major minor =
  let base = [ ("user_agent", Packstream.String config.user_agent) ] in
  let routing =
    match config.routing_context with
    | Some context when (Capabilities.of_version major minor).supports_connection_context ->
        [ ("routing", Packstream.Map (List.map (fun (k, v) -> (k, Packstream.String v)) context)) ]
    | Some _ | None -> []
  in
  let bolt_agent =
    if bolt_agent_version major minor then [ ("bolt_agent", bolt_agent ()) ] else []
  in
  let patch_bolt =
    if major = 4 && minor >= 3 then [ ("patch_bolt", Packstream.List [ Packstream.String "utc" ]) ]
    else []
  in
  let auth =
    if re_auth_of major minor then []
    else match Auth_manager.to_map config.auth with Packstream.Map fields -> fields | _ -> []
  in
  Packstream.Map (base @ routing @ patch_bolt @ bolt_agent @ auth)

let version t = (t.major, t.minor)
let server_state t = !(t.state)

(* The connection id (from the transport's [Log.next_id]) for log lines. *)
let id t = Transport.id t.transport

(* Whether the server answered the last request with a FAILURE: the connection
   is not in a clean state and needs a RESET before it can be reused. *)
let is_failed t = State.failed !(t.state)
let address t = t.address

(* The connection reports request failures to an optional callback (installed by
   the routing cluster to deactivate dead addresses, and by the pool to handle
   security errors) and logs them. The callback may return a modified error
   (e.g. one marked retryable after an auth manager handled it), which is the
   error surfaced to the caller. *)
let set_on_error t on_error = t.on_error := on_error
let on_error t = !(t.on_error)
let last_database t = !(t.last_database)
let set_last_database t database = t.last_database := database

let report t error =
  Log.debug Log.io (fun m -> m "[#%04X]  _: <CONNECTION> error: %s" (id t) (Errors.to_string error));
  !(t.on_error) t error

(* The auth manager behind the connection's current token (the pool installs it
   to handle security exceptions; see [on_neo4j_error]). *)
let set_auth_manager t manager = t.auth_manager := Some manager
let auth_manager t = !(t.auth_manager)

(* A hydration scope for this connection's protocol version (V1 = Bolt 3/4,
   V2 = Bolt 5, V3 = Bolt 6). The minor version gates Bolt 6.1-only types
   (UUID). A Bolt 4 connection whose server confirmed the [utc] patch uses the
   V2 (Bolt 5) Date/Time encoding. *)
let hydration t =
  let version =
    match t.major with
    | 3 | 4 -> if !(t.utc_patch) then Hydration.V2 else Hydration.V1
    | 5 -> Hydration.V2
    | _ -> Hydration.V3
  in
  Hydration.create version ~minor:t.minor

(* Send a RESET and read the response; the server returns to READY. *)
let reset t =
  let* () = Bolt.send t.transport ~tag:Bolt.reset_tag [] in
  match Bolt.respond t.transport with
  | Ok _ ->
      t.state := State.Ready;
      Ok ()
  | Error _ as error -> error

(* Whether a TELEMETRY notification should be sent on this connection: Bolt
   5.4+, the server advertised it in HELLO, and the driver configuration does
   not disable it. *)
let telemetry_wanted t = (capabilities_of t).supports_telemetry && !(t.telemetry_enabled)

(* Reset a connection left in the FAILED state (reporting a reset failure via
   [report]), so the next request runs on a clean connection. *)
let ensure_ready t =
  if State.failed !(t.state) then reset t |> Result.map_error (fun error -> report t error)
  else Ok ()

(* Recover a connection after a server FAILURE, like the Python driver's
   [Response.on_failure]: the RESET is sent eagerly instead of being deferred to
   the next request, so the connection is immediately reusable. Only FAILURE
   responses (an [Errors.Neo4j]) trigger it — IGNORED and transport errors do
   not (matching Python's [on_failure] vs [on_ignored]). When the server already
   dropped the connection (e.g. a stub script's [S: <EXIT>] right after the
   FAILURE), the RESET fails; the error is swallowed — the original FAILURE is
   what surfaces, and the connection stays in the FAILED state so the pool
   discards it on release. *)
let recover_after_failure t error =
  match error with
  | Errors.Neo4j _ -> (
      match reset t with
      | Ok () -> ()
      | Error reset_error ->
          Log.debug Log.io (fun m ->
              m "[#%04X]  _: <CONNECTION> RESET after FAILURE failed: %s" (id t)
                (Errors.to_string reset_error)))
  | _ -> ()

(* Drain a still-pending pipelined PULL response (Bolt 3) before the connection
   is used for something else: the PULL_ALL was already sent by [run], and its
   RECORD/SUCCESS messages must be consumed to keep the response stream in
   sync. The records are dropped — this only happens when the abandoned stream
   is not pulled again. *)
let drain_pending_pull t =
  if !(t.pipelined_pull) then begin
    t.pipelined_pull := false;
    match Bolt.collect_records [] t.transport with
    | Ok (_, outcome) -> ( match outcome with Error _ -> t.state := State.Failed | Ok _ -> ())
    | Error _ -> ()
  end

(* Send [action] (a Bolt message that already reads its response) and update the
   server state. If the server is in the FAILED state, a RESET is sent first.
   [has_more result] decides whether the state stays in STREAMING after the
   message (used by PULL/DISCARD). A pipelined PULL response pending on the
   connection (Bolt 3) is drained first, except for the PULL/DISCARD that is
   itself about to consume it. *)
let request ?(has_more = fun _ -> false) t ~message ~re_auth action =
  if !(t.pipelined_pull) && message <> State.Pull && message <> State.Discard then
    drain_pending_pull t;
  let* () = ensure_ready t in
  match action () with
  | Ok result ->
      let old = !(t.state) in
      let new_state = State.server_transition ~re_auth ~has_more:(has_more result) old message in
      if old <> new_state then
        Log.debug Log.io (fun m ->
            m "[#%04X]  _: <CONNECTION> server state: %s > %s" (id t) (State.to_string old)
              (State.to_string new_state));
      t.state := new_state;
      Ok result
  | Error error ->
      if not (State.failed !(t.state)) then
        Log.debug Log.io (fun m ->
            m "[#%04X]  _: <CONNECTION> server state: %s > %s" (id t) (State.to_string !(t.state))
              (State.to_string State.Failed));
      t.state := State.Failed;
      let error = report t error in
      recover_after_failure t error;
      Error error

(* Like [request], but batches a TELEMETRY notification for [feature] before the
   request and reads the telemetry's SUCCESS before the request's own response
   (the server answers both in order). [action] must only SEND the request
   message (no read); only RUN/BEGIN use this. The state transitions as usual
   (a RUN enters [Streaming] until the follow-up PULL/DISCARD). *)
let request_telemetry t ~message ~re_auth feature action =
  let* () = ensure_ready t in
  let outcome =
    let* () =
      Bolt.send t.transport ~tag:Bolt.telemetry_tag [ Packstream.Int (Int64.of_int feature) ]
    in
    let* () = action () in
    match Bolt.respond t.transport with
    | Error error ->
        (* TELEMETRY failed: the server IGNOREs the already-sent request, so
           its response is still on the wire — drain it to keep the message
           stream in sync for the follow-up RESET. *)
        ignore (Bolt.respond t.transport);
        Error error
    | Ok _ ->
        let* _ = Bolt.respond t.transport in
        Bolt.respond t.transport
  in
  match outcome with
  | Ok response ->
      let old = !(t.state) in
      let new_state = State.server_transition ~re_auth ~has_more:false old message in
      if old <> new_state then
        Log.debug Log.io (fun m ->
            m "[#%04X]  _: <CONNECTION> server state: %s > %s" (id t) (State.to_string old)
              (State.to_string new_state));
      t.state := new_state;
      Ok response
  | Error error ->
      if not (State.failed !(t.state)) then
        Log.debug Log.io (fun m ->
            m "[#%04X]  _: <CONNECTION> server state: %s > %s" (id t) (State.to_string !(t.state))
              (State.to_string State.Failed));
      t.state := State.Failed;
      let error = report t error in
      recover_after_failure t error;
      Error error

(* A positive [connection.recv_timeout_seconds] hint replaces the transport's
   receive timeout with that many seconds. *)
let set_recv_timeout_hint conn seconds =
  if seconds > 0.0 then
    Transport.set_read_timeout conn.transport (Eio.Time.Timeout.seconds conn.clock seconds)

(* Record the HELLO response metadata: the server agent, the confirmed [utc]
   patch (DateTimes then use the Bolt 5 encoding), and the [ssr.enabled] hint
   that turns on server-side routing (the server then sends [rt] routing tables
   in RUN responses). The [connection.recv_timeout_seconds] hint overrides the
   driver's receive timeout for this connection. *)
let set_hello_metadata conn = function
  | Packstream.Map fields -> (
      (match List.assoc_opt "server" fields with
      | Some (Packstream.String agent) -> conn.server_agent := Some agent
      | _ -> ());
      (match List.assoc_opt "patch_bolt" fields with
      | Some (Packstream.List items)
        when List.exists (function Packstream.String "utc" -> true | _ -> false) items ->
          conn.utc_patch := true
      | _ -> ());
      match List.assoc_opt "hints" fields with
      | Some (Packstream.Map hints) -> (
          (match List.assoc_opt "ssr.enabled" hints with
          | Some (Packstream.Bool true) -> conn.ssr_enabled := true
          | _ -> ());
          (* The effective telemetry flag combines the driver configuration
             (telemetry_disabled) with the server's hint, folded into
             [telemetry_enabled] at connect time: a server that does not
             advertise telemetry (or explicitly disables it) turns it off. *)
          match List.assoc_opt "telemetry.enabled" hints with
          | Some (Packstream.Bool true) -> ()
          | _ -> (
              conn.telemetry_enabled := false;
              match List.assoc_opt "connection.recv_timeout_seconds" hints with
              | Some (Packstream.Int seconds) -> set_recv_timeout_hint conn (Int64.to_float seconds)
              | Some (Packstream.Float seconds) -> set_recv_timeout_hint conn seconds
              | _ -> ()))
      | _ -> conn.telemetry_enabled := false)
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
  set_hello_metadata conn hello_metadata;
  let* () =
    if re_auth then
      request conn ~message:State.Logon ~re_auth (fun () ->
          Bolt.logon conn.transport ~auth:(auth_map config.auth))
      |> Result.map (fun _ -> ())
    else Ok ()
  in
  conn.current_auth := Some config.auth;
  Ok ()

let connect ?resolver ?domain_name_resolver net clock sw config =
  let* tls = tls_of_scheme config.host config.scheme in
  let initial = Addressing.of_host_port config.host config.port in
  let* addresses = match resolver with Some resolve -> resolve initial | None -> Ok [ initial ] in
  (* Resolve any hostnames among [addresses] through the custom domain-name
     resolver (the TestKit harness resolves the driver's fake host names this
     way); literal IPs are kept as-is. *)
  let* addresses =
    match domain_name_resolver with
    | None -> Ok addresses
    | Some resolve ->
        let rec go = function
          | [] -> Ok []
          | address :: rest ->
              let host = Addressing.host address in
              let literal =
                Result.is_ok (Ipaddr.V4.of_string host) || Result.is_ok (Ipaddr.V6.of_string host)
              in
              if literal then Result.map (List.cons address) (go rest)
              else
                let* hosts = resolve host in
                let resolved =
                  List.map (fun h -> Addressing.of_host_port h (Addressing.port address)) hosts
                in
                Result.map (fun tail -> resolved @ tail) (go rest)
        in
        go addresses
  in
  let connect_single address =
    let* transport =
      Transport.connect net sw ~timeout:(timeout_of_config clock config) ~tls address
    in
    let* major, minor = Handshake.negotiate transport in
    Ok (transport, major, minor, address)
  in
  let rec attempt failed errors = function
    | [] -> (
        (* A resolver / domain-name resolver may legitimately return no
           addresses: report it instead of crashing on an empty failure list. *)
        match errors with
        | error :: _ ->
            let failures = { Errors.last = error; all = List.rev errors } in
            Error
              (Errors.Service_unavailable
                 (Addressing.connect_failure_message ~address:initial ~resolved:failed ~failures))
        | [] ->
            Error
              (Errors.Service_unavailable
                 (Printf.sprintf "Couldn't connect to %s (no addresses resolved)"
                    (Addressing.to_string initial))))
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
      auth_manager = ref None;
      on_error = ref (fun _ error -> error);
      last_database = ref None;
      ssr_enabled = ref false;
      telemetry_enabled = ref (not config.telemetry_disabled);
      pipelined_pull = ref false;
      clock;
      utc_patch = ref false;
    }
  in
  match authenticate conn config with
  | Ok () -> Ok conn
  | Error error ->
      Log.debug Log.io (fun m ->
          m "[#%04X]  C: <OPEN FAILED> %s" (id conn) (Errors.to_string error));
      Transport.close transport;
      Error error

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
  rt : Packstream.value option;
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
  let rt = map_fields "rt" metadata in
  { fields; qid; bookmark; t_first; rt }

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
        (* Like the Python driver, an empty bookmark list is omitted from the
           extra map (the server defaults to no bookmarks). *)
        Option.bind bookmarks (function
          | [] -> None
          | bookmarks ->
              Some ("bookmarks", Packstream.List (List.map (fun b -> Packstream.String b) bookmarks)));
        Option.map
          (fun seconds -> ("tx_timeout", Packstream.Int (Int64.of_float (seconds *. 1000.0))))
          timeout;
        Option.map (fun metadata -> ("tx_metadata", Packstream.Map metadata)) metadata;
      ]
  in
  Packstream.Map items

let run ?mode ?db ?bookmarks ?timeout ?metadata ?telemetry t ~hydration ~query ~parameters =
  (* Like the Python driver, the connection's last database is only updated
     outside a transaction: inside one the BEGIN's database stays authoritative
     (a tx RUN does not carry [db]). *)
  if !(t.state) <> State.Tx_ready_or_tx_streaming then t.last_database := db;
  let* parameters =
    Result.map
      (fun items -> Packstream.Map items)
      (Hydration.dehydrate_assoc_list hydration parameters)
  in
  let* metadata =
    match metadata with
    | None -> Ok None
    | Some entries ->
        Result.map (fun items -> Some items) (Hydration.dehydrate_assoc_list hydration entries)
  in
  let re_auth = re_auth_of t.major t.minor in
  let extra = build_extra ?mode ?db ?bookmarks ?timeout ?metadata () in
  let* metadata_response =
    match telemetry with
    | Some feature when telemetry_wanted t ->
        request_telemetry t ~message:State.Run ~re_auth feature (fun () ->
            Bolt.send t.transport ~tag:Bolt.run_tag [ Packstream.String query; parameters; extra ])
    | _ when t.major = 3 ->
        request t ~message:State.Run ~re_auth (fun () ->
            let* () =
              Bolt.send t.transport ~tag:Bolt.run_tag [ Packstream.String query; parameters; extra ]
            in
            let* () = Bolt.send t.transport ~tag:Bolt.pull_tag [] in
            Bolt.respond t.transport
            |> Result.map_error (fun error ->
                (* The RUN failed: the pipelined PULL is answered with an
                   IGNORED that must be drained before the follow-up RESET. *)
                ignore (Bolt.respond t.transport);
                error))
    | _ ->
        request t ~message:State.Run ~re_auth (fun () ->
            Bolt.run t.transport ~query ~parameters ~extra)
  in
  if t.major = 3 then t.pipelined_pull := true;
  Ok (run_metadata_of metadata_response)

let pull_extra ?(n = -1) ?qid () =
  let extra = [ ("n", Packstream.Int (Int64.of_int n)) ] in
  let extra =
    match qid with Some qid -> ("qid", Packstream.Int (Int64.of_int qid)) :: extra | None -> extra
  in
  Packstream.Map extra

let outcome_has_more = function Ok summary -> Bolt.metadata_has_more summary | Error _ -> false

(* The PULL/DISCARD payload: Bolt 4+ carries the [n]/[qid] map; Bolt 3's
   PULL_ALL/DISCARD_ALL take no fields. *)
let pull_payload t ?n ?qid () = if t.major = 3 then None else Some (pull_extra ?n ?qid ())

let pull ?n ?qid t ~hydration =
  let re_auth = re_auth_of t.major t.minor in
  match
    request
      ~has_more:(fun (_, outcome) -> outcome_has_more outcome)
      t ~message:State.Pull ~re_auth
      (fun () ->
        if !(t.pipelined_pull) then begin
          (* Bolt 3: the PULL_ALL was already sent with the RUN — read it. *)
          t.pipelined_pull := false;
          Bolt.collect_records [] t.transport
        end
        else Bolt.pull ?extra:(pull_payload t ?n ?qid ()) t.transport)
  with
  | Error _ as error -> error
  | Ok (records, outcome) ->
      let records = List.map (List.map (Hydration.hydrate hydration)) records in
      let outcome =
        outcome
        |> Result.map_error (fun error ->
            t.state := State.Failed;
            let error = report t error in
            recover_after_failure t error;
            error)
      in
      Ok (records, outcome)

let discard ?n ?qid t =
  let re_auth = re_auth_of t.major t.minor in
  let* _, outcome =
    request
      ~has_more:(fun (_, outcome) -> outcome_has_more outcome)
      t ~message:State.Discard ~re_auth
      (fun () ->
        if !(t.pipelined_pull) then begin
          (* Bolt 3: the PULL_ALL was already sent with the RUN — consume its
             response instead of sending a DISCARD_ALL. *)
          t.pipelined_pull := false;
          Bolt.collect_records [] t.transport
        end
        else Bolt.discard ?extra:(pull_payload t ?n ?qid ()) t.transport)
  in
  if Result.is_error outcome then begin
    t.state := State.Failed;
    let error = Result.get_error outcome in
    let error = report t error in
    recover_after_failure t error;
    Ok (Error error)
  end
  else Ok outcome

(* A lazily-streamed result on a connection: RUN is sent immediately, records
   are pulled in batches on demand into a FIFO queue (consumed records are
   popped and freed). The terminal state is a [summary] (normal end) or an
   [error] (a server failure, surfaced after the buffered records are
   consumed). [on_complete] fires with the final summary once the stream ends
   normally (e.g. to capture an auto-commit bookmark). *)
type stream = {
  conn : t;
  run_metadata : run_metadata;
  hydration : Hydration.t;
  records : Values.t list Queue.t;
  mutable summary : Packstream.value option;
  mutable error : Errors.t option;
  mutable has_more : bool;
  mutable closed : bool;
  mutable had_record : bool;
  on_complete : Packstream.value -> unit;
  on_error : Errors.t -> unit;
}

let stream ?(on_complete = fun _ -> ()) ?(on_error = fun _ -> ()) conn ~hydration ~run_metadata =
  {
    conn;
    run_metadata;
    hydration;
    records = Queue.create ();
    summary = None;
    error = None;
    has_more = true;
    closed = false;
    had_record = false;
    on_complete;
    on_error;
  }

let connection s = s.conn
let has_more s = s.has_more
let error s = s.error
let summary s = s.summary
let had_record s = s.had_record
let run_metadata s = s.run_metadata

(* Whether the stream's transaction was closed (the stream is out of scope:
   further reads must fail, like the Python driver's ResultConsumedError). *)
let stream_closed s = s.closed
let mark_stream_closed s = s.closed <- true

(* Mark a stream as failed with [error]: further reads surface the failure
   instead of pulling (e.g. when a sibling request failed and terminated the
   stream's transaction). *)
let mark_stream_error s error =
  s.has_more <- false;
  s.error <- Some error

(* The records still buffered (not yet consumed), in order. *)
let buffered s = Queue.to_seq s.records |> List.of_seq

(* Whether a record is available without pulling. *)
let has_records s = not (Queue.is_empty s.records)

(* Pop / peek the next buffered record, if any. *)
let next_record s = Queue.take_opt s.records
let peek_record s = Queue.peek_opt s.records

let pull_stream ?n s =
  if not s.has_more then Ok []
  else
    let* records, outcome = pull ?n ?qid:s.run_metadata.qid s.conn ~hydration:s.hydration in
    if records <> [] then s.had_record <- true;
    List.iter (fun record -> Queue.push record s.records) records;
    match outcome with
    | Error error ->
        s.has_more <- false;
        s.error <- Some error;
        s.on_error error;
        Ok records
    | Ok summary ->
        let more = Bolt.metadata_has_more summary in
        s.has_more <- more;
        if not more then begin
          s.summary <- Some summary;
          s.on_complete summary
        end;
        Ok records

(* Discard the rest of a stream without pulling its records (the Python
   driver's consume semantics): the DISCARD response's metadata becomes the
   stream's final summary. No-op once the stream is finished. *)
let discard_stream s =
  if not s.has_more then Ok ()
  else
    match discard ?qid:s.run_metadata.qid s.conn with
    | Error _ as error ->
        s.has_more <- false;
        error
    | Ok (Error error) ->
        s.has_more <- false;
        s.error <- Some error;
        s.on_error error;
        Error error
    | Ok (Ok summary) ->
        s.has_more <- false;
        s.summary <- Some summary;
        s.on_complete summary;
        Ok ()

(* Pull a stream to its end, best effort: a transport failure stops the drain
   (the failure is left on the stream; the connection is recovered by the next
   request's RESET). *)
let rec drain_stream s =
  if has_more s then match pull_stream s with Ok _ -> drain_stream s | Error _ -> ()

let begin_ ?telemetry t ~extra =
  (* A transaction pins the connection to a database (its BEGIN extra's [db]).
     Like the Python driver, BEGIN records it as the connection's last
     database, so a failure inside the transaction (e.g. NotALeader) is keyed
     to the right database. *)
  (match extra with
  | Packstream.Map fields -> (
      match List.assoc_opt "db" fields with
      | Some (Packstream.String db) -> t.last_database := Some db
      | _ -> ())
  | _ -> ());
  let re_auth = re_auth_of t.major t.minor in
  let* _ =
    match telemetry with
    | Some feature when telemetry_wanted t ->
        request_telemetry t ~message:State.Begin ~re_auth feature (fun () ->
            Bolt.send t.transport ~tag:Bolt.begin_tag [ extra ])
    | _ -> request t ~message:State.Begin ~re_auth (fun () -> Bolt.begin_ t.transport ~extra)
  in
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

(* The routing-procedure query, its parameters and the RUN [extra] for the
   given Bolt version: Bolt 3 uses the cluster procedure with no [db] and no
   bookmarks; Bolt 4.0-4.2 uses the multi-db procedure on the [system]
   database (passing [$database] when one is selected). *)
let routing_procedure_request db ~routing_context ~bookmarks ~major =
  let context =
    Packstream.Map (List.map (fun (k, v) -> (k, Packstream.String v)) routing_context)
  in
  if major = 3 then
    ( "CALL dbms.cluster.routing.getRoutingTable($context)",
      Packstream.Map [ ("context", context) ],
      build_extra ~mode:Config.Read () )
  else
    match db with
    | None ->
        ( "CALL dbms.routing.getRoutingTable($context)",
          Packstream.Map [ ("context", context) ],
          build_extra ~mode:Config.Read ~db:"system" ~bookmarks () )
    | Some database ->
        ( "CALL dbms.routing.getRoutingTable($context, $database)",
          Packstream.Map [ ("context", context); ("database", Packstream.String database) ],
          build_extra ~mode:Config.Read ~db:"system" ~bookmarks () )

(* A safe zip of the RUN [fields] with the record's values: mismatched lengths
   (a server answering with an unexpected shape) become [None], not
   [invalid_arg]. *)
let rec zip_fields keys values =
  match (keys, values) with
  | [], [] -> Some []
  | key :: keys, value :: values -> (
      match zip_fields keys values with Some rest -> Some ((key, value) :: rest) | None -> None)
  | _ -> None

(* The routing-table fallback for Bolt 3 / 4.0-4.2: CALL the server's routing
   procedure and zip its [fields] with the single returned record — the same
   {ttl; servers} shape as the ROUTE message's [rt], so the caller's
   [Routing_table.parse] works unchanged. [imp_user] (no procedure supports it)
   and a [database] on Bolt 3 (no multi-db) are [Configuration_error]. *)
let route_procedure ?db ?imp_user t ~routing_context ~bookmarks =
  let major, _ = version t in
  match imp_user with
  | Some _ ->
      Error
        (Errors.Configuration_error
           "Impersonation is not supported by the routing procedure (Bolt < 4.3)")
  | None -> (
      match (major, db) with
      | 3, Some _ ->
          Error
            (Errors.Configuration_error
               "Database selection is not supported by the routing procedure on Bolt 3")
      | _ -> (
          let query, parameters, extra =
            routing_procedure_request db ~routing_context ~bookmarks ~major
          in
          (* The routing-procedure scripts (and the Python driver) pipeline the
             RUN and the PULL: the TestKit stub answers only once both messages
             have arrived, so both are sent before any response is read. *)
          let* () = ensure_ready t in
          let* () =
            Bolt.send t.transport ~tag:Bolt.run_tag [ Packstream.String query; parameters; extra ]
          in
          let* () =
            Bolt.send t.transport ~tag:Bolt.pull_tag
              (match pull_payload t () with Some extra -> [ extra ] | None -> [])
          in
          let finish run_metadata records = function
            | Error error ->
                t.state := State.Failed;
                let error = report t error in
                recover_after_failure t error;
                Error error
            | Ok _ -> (
                match records with
                | [] -> Error (Errors.Service_unavailable "routing procedure returned no records")
                | record :: _ -> (
                    match zip_fields run_metadata.fields record with
                    | Some fields ->
                        t.state := State.Ready;
                        Ok (Packstream.Map fields)
                    | None ->
                        Error
                          (Errors.Service_unavailable
                             "routing procedure returned mismatched fields and record")))
          in
          match Bolt.respond t.transport with
          | Error error ->
              (* The RUN failed: the pipelined PULL is answered with an IGNORED
                 (or another FAILURE) that must be drained before the state is
                 updated and the connection recovered with a RESET. *)
              ignore (Bolt.respond t.transport);
              t.state := State.Failed;
              let error = report t error in
              recover_after_failure t error;
              Error error
          | Ok run_response -> (
              let run_metadata = run_metadata_of run_response in
              match Bolt.collect_records [] t.transport with
              | Error error ->
                  t.state := State.Failed;
                  Error (report t error)
              | Ok (records, outcome) -> finish run_metadata records outcome)))

(* Fetch the routing table of [db] (the default database when [None]) over the
   ROUTE message (Bolt 4.3+). *)
let route_message ?db ?imp_user t ~routing_context ~bookmarks =
  let re_auth = re_auth_of t.major t.minor in
  let at_least_4_4 = t.major > 4 || (t.major = 4 && t.minor >= 4) in
  let* metadata =
    request t ~message:State.Route ~re_auth (fun () ->
        let extra =
          if at_least_4_4 then
            let fields =
              (match db with Some db -> [ ("db", Packstream.String db) ] | None -> [])
              @
              match imp_user with
              | Some user -> [ ("imp_user", Packstream.String user) ]
              | None -> []
            in
            Packstream.Map fields
          else match db with Some db -> Packstream.String db | None -> Packstream.Null
        in
        Bolt.route t.transport
          ~routing_context:
            (Packstream.Map (List.map (fun (k, v) -> (k, Packstream.String v)) routing_context))
          ~bookmarks:(Packstream.List (List.map (fun b -> Packstream.String b) bookmarks))
          ~extra)
  in
  let missing_rt =
    Error (Errors.Service_unavailable "ROUTE response is missing the routing table")
  in
  match metadata with
  | Packstream.Map fields -> (
      match List.assoc_opt "rt" fields with Some rt -> Ok rt | None -> missing_rt)
  | _ -> missing_rt

(* Fetch the routing table of [db] (the default database when [None]) over the
   ROUTE message (Bolt 4.3+) or, on older servers, by calling the routing
   procedure (see [route_procedure]). *)
let route ?db ?imp_user t ~routing_context ~bookmarks =
  if (Capabilities.of_version t.major t.minor).supports_route_message then
    route_message ?db ?imp_user t ~routing_context ~bookmarks
  else route_procedure ?db ?imp_user t ~routing_context ~bookmarks

let server_agent t = !(t.server_agent)
let ssr_enabled t = !(t.ssr_enabled)
let capabilities t = capabilities_of t
let current_auth t = !(t.current_auth)

(* Whether the connection is logged on with [token]: its current token equals
   [token], or it carries none (it was marked unauthenticated, e.g. by an
   AuthorizationExpired). The re-auth paths use this to skip a redundant
   LOGOFF+LOGON when the token did not change. *)
let same_auth t token =
  match !(t.current_auth) with Some current -> Auth_manager.eq current token | None -> false

(* The TELEMETRY notification for a feature is batched with the next request
   by [request] (which consumes its SUCCESS before the request's response);
   the session layers pass [~telemetry] to [run]/[begin_]. *)

(* Re-authenticate when [auth] differs from the current token: LOGOFF then
   LOGON (Bolt >= 5.1). [force] re-authenticates even for the same token
   (user switching). Returns whether the token changed. *)
let re_auth ?(force = false) t auth =
  if (not force) && same_auth t auth then Ok false
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

let close t =
  (* Tell the server we are closing (Bolt 4.4+), like the Python driver: the
     GOODBYE write is best-effort (no response is read) and is skipped on
     protocol versions that do not support it. *)
  if (Capabilities.of_version t.major t.minor).supports_goodbye then
    ignore (Bolt.goodbye t.transport);
  Log.debug Log.io (fun m -> m "[#%04X]  C: <CLOSE>" (id t));
  Transport.close t.transport
