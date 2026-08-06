(* TestKit command handlers.

   Dispatch a request ({"name": ..., "data": {...}}) to a handler and return the
   response (name, data), or [None] for handlers that are silent (the harness
   sends no response expected, e.g. ResolverResolutionCompleted). The context
   provides the network resources and lets handlers push unsolicited messages to
   the harness and read the follow-up request (custom address resolution).

   Modeled on the Python driver's testkitbackend/_async/requests.py. *)

open Neodriver
open Neodriver_eio

exception Backend_error of string

(* --- Connection context --- *)

type 'tag ctx = {
  net : [ `Network | `Platform of 'tag ] Eio.Resource.t;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  sw : Eio.Switch.t;
  send : string -> Yojson.Safe.t -> unit;
  read : unit -> string option;
}

(* --- JSON helpers --- *)

let member key fields = List.assoc_opt key fields

let string key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> s
  | _ -> raise (Backend_error ("missing string " ^ key))

let int key fields =
  match List.assoc_opt key fields with
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some n -> n
      | None -> raise (Backend_error ("bad int " ^ key)))
  | _ -> raise (Backend_error ("missing int " ^ key))

let opt_string key fields =
  match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None

(* --- Backend state --- *)

type auth = { scheme : string; principal : string; credentials : string }

type driver = {
  uri : Addressing.uri;
  auth : auth;
  user_agent : string;
  connection_timeout : float;
  resolver_registered : bool;
  conn : Conn.t option ref;
}

type session = { driver_id : int; database : string option; access_mode : string option }

type result = {
  fields : string list;
  records : Values.t list list;
  cursor : int ref;
  summary : Packstream.value;
  query : string;
  parameters : (string * Values.t) list;
  conn : Conn.t;
}

let drivers : (int, driver) Hashtbl.t = Hashtbl.create 16
let sessions : (int, session) Hashtbl.t = Hashtbl.create 16
let results : (int, result) Hashtbl.t = Hashtbl.create 16
let custom_resolutions : (int, string list) Hashtbl.t = Hashtbl.create 16
let next_id = ref 0

let new_id () =
  incr next_id;
  !next_id

let get_driver id =
  match Hashtbl.find_opt drivers id with
  | Some driver -> driver
  | None -> raise (Backend_error "unknown driver")

let get_session id =
  match Hashtbl.find_opt sessions id with
  | Some session -> session
  | None -> raise (Backend_error "unknown session")

let get_result id =
  match Hashtbl.find_opt results id with
  | Some result -> result
  | None -> raise (Backend_error "unknown result")

let auth_of fields =
  match List.assoc_opt "authorizationToken" fields with
  | Some (`Assoc token) -> (
      match List.assoc_opt "data" token with
      | Some (`Assoc data) ->
          let scheme = string "scheme" data in
          if scheme <> "basic" then
            raise (Backend_error (Printf.sprintf "unsupported auth scheme %S" scheme));
          { scheme; principal = string "principal" data; credentials = string "credentials" data }
      | _ -> raise (Backend_error "authorizationToken has no data"))
  | _ -> raise (Backend_error "authorizationToken is required")

let conn_config driver =
  Conn.
    {
      host = driver.uri.host;
      port = driver.uri.port;
      scheme = driver.uri.scheme;
      connection_timeout = driver.connection_timeout;
      user_agent = driver.user_agent;
      auth =
        {
          scheme = driver.auth.scheme;
          principal = driver.auth.principal;
          credentials = driver.auth.credentials;
        };
    }

(* Ask the harness to resolve an address (custom resolver) and return the
   addresses to try. The follow-up ResolverResolutionCompleted request is
   consumed and processed here (it is not dispatched through the normal loop). *)
let resolver ctx address =
  let id = new_id () in
  ctx.send "ResolverResolutionRequired"
    (`Assoc [ ("id", `Int id); ("address", `String (Addressing.to_string address)) ]);
  let resolution =
    match ctx.read () with
    | None -> None
    | Some json -> (
        match Yojson.Safe.from_string json with
        | `Assoc fields -> (
            match List.assoc_opt "data" fields with
            | Some (`Assoc data) -> (
                match (List.assoc_opt "requestId" data, List.assoc_opt "addresses" data) with
                | Some (`Int request_id), Some (`List addresses) when request_id = id ->
                    Some
                      (List.map
                         (function `String s -> s | _ -> raise (Backend_error "bad address"))
                         addresses)
                | Some (`Intlit request_id), Some (`List addresses)
                  when match int_of_string_opt request_id with Some n -> n = id | None -> false ->
                    Some
                      (List.map
                         (function `String s -> s | _ -> raise (Backend_error "bad address"))
                         addresses)
                | _ -> None)
            | _ -> None)
        | _ -> None)
  in
  let rec parse = function
    | [] -> Ok []
    | s :: rest -> (
        match Addressing.parse s with
        | Error _ -> Error (Errors.Service_unavailable ("bad resolved address " ^ s))
        | Ok address -> (
            match parse rest with Ok addresses -> Ok (address :: addresses) | Error _ as e -> e))
  in
  match resolution with
  | Some addresses -> parse addresses
  | None -> Error (Errors.Service_unavailable "no resolver resolution received")

(* Open the driver's connection on first use. *)
let ensure_conn ctx (driver : driver) =
  match !(driver.conn) with
  | Some conn -> Ok conn
  | None -> (
      let custom = if driver.resolver_registered then Some (resolver ctx) else None in
      match Conn.connect ?resolver:custom ctx.net ctx.clock ctx.sw (conn_config driver) with
      | Error error -> Error error
      | Ok conn ->
          driver.conn := Some conn;
          Ok conn)

let conn_of ctx (driver : driver) =
  match ensure_conn ctx driver with
  | Ok conn -> conn
  | Error error -> raise (Backend_error (Errors.to_string error))

(* --- Handlers --- *)

let start_test _fields = ("RunTest", `Assoc [])

let get_features _fields =
  ("FeatureList", `Assoc [ ("features", `List (List.map (fun f -> `String f) Features.features)) ])

let new_driver fields =
  let uri_string = string "uri" fields in
  let user_agent = Option.value ~default:"ocaml-neo4j-driver" (opt_string "userAgent" fields) in
  let auth = auth_of fields in
  let resolver_registered =
    match List.assoc_opt "resolverRegistered" fields with Some (`Bool b) -> b | _ -> false
  in
  let connection_timeout =
    match List.assoc_opt "connectionTimeoutMs" fields with
    | Some (`Int ms) -> float_of_int ms /. 1000.0
    | Some (`Intlit ms) -> (
        match float_of_string_opt ms with Some f -> f /. 1000.0 | None -> 30.0)
    | _ -> 30.0
  in
  match Addressing.parse_uri uri_string with
  | Error error -> raise (Backend_error (Errors.to_string error))
  | Ok uri ->
      let id = new_id () in
      Hashtbl.add drivers id
        { uri; auth; user_agent; connection_timeout; resolver_registered; conn = ref None };
      ("Driver", `Assoc [ ("id", `Int id) ])

let driver_close fields =
  let id = int "driverId" fields in
  (match Hashtbl.find_opt drivers id with
  | Some driver -> ( match !(driver.conn) with Some conn -> Conn.close conn | None -> ())
  | None -> ());
  Hashtbl.remove drivers id;
  ("Driver", `Assoc [ ("id", `Int id) ])

let new_session fields =
  let driver_id = int "driverId" fields in
  let database = opt_string "database" fields in
  let access_mode = opt_string "accessMode" fields in
  if not (Hashtbl.mem drivers driver_id) then raise (Backend_error "unknown driver");
  let id = new_id () in
  Hashtbl.add sessions id { driver_id; database; access_mode };
  ("Session", `Assoc [ ("id", `Int id) ])

let session_close fields =
  let id = int "sessionId" fields in
  Hashtbl.remove sessions id;
  ("Session", `Assoc [ ("id", `Int id) ])

(* Stores a custom resolution; the harness sends no response is expected. *)
let resolver_resolution_completed fields =
  let request_id = int "requestId" fields in
  let addresses =
    match List.assoc_opt "addresses" fields with
    | Some (`List l) ->
        List.map (function `String s -> s | _ -> raise (Backend_error "bad address")) l
    | _ -> raise (Backend_error "missing addresses")
  in
  Hashtbl.add custom_resolutions request_id addresses;
  None

let verify_connectivity ctx fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  ignore (conn_of ctx driver);
  ("Driver", `Assoc [ ("id", `Int id) ])

let get_server_info ctx fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  let conn = conn_of ctx driver in
  let major, minor = Conn.version conn in
  let agent = Option.value ~default:"" (Conn.server_agent conn) in
  ( "ServerInfo",
    `Assoc
      [
        ("address", `String (Addressing.to_string (Conn.address conn)));
        ("agent", `String agent);
        ("protocolVersion", `String (Printf.sprintf "%d.%d" major minor));
      ] )

let decode_params fields =
  match List.assoc_opt "params" fields with
  | Some (`Assoc params) -> List.map (fun (k, v) -> (k, Testkit_values.of_yojson v)) params
  | _ -> []

let session_run ctx fields =
  let session = get_session (int "sessionId" fields) in
  let driver = get_driver session.driver_id in
  let conn = conn_of ctx driver in
  let cypher = string "cypher" fields in
  let parameters = decode_params fields in
  let metadata =
    match List.assoc_opt "txMeta" fields with
    | Some (`Assoc tx_meta) ->
        Some (List.map (fun (k, v) -> (k, Testkit_values.of_yojson v)) tx_meta)
    | _ -> None
  in
  let hydration = Conn.hydration conn in
  match Conn.run conn ~hydration ~query:cypher ~parameters ?metadata () with
  | Error error -> raise (Backend_error (Errors.to_string error))
  | Ok run_metadata -> (
      match Conn.pull conn ~hydration () with
      | Error error -> raise (Backend_error (Errors.to_string error))
      | Ok (records, summary) ->
          let id = new_id () in
          Hashtbl.add results id
            {
              fields = run_metadata.fields;
              records;
              cursor = ref 0;
              summary;
              query = cypher;
              parameters;
              conn;
            };
          ( "Result",
            `Assoc
              [
                ("id", `Int id); ("keys", `List (List.map (fun f -> `String f) run_metadata.fields));
              ] ))

let record_json record = `Assoc [ ("values", `List (List.map Testkit_values.to_yojson record)) ]

let result_next fields =
  let r = get_result (int "resultId" fields) in
  if !(r.cursor) < List.length r.records then begin
    let record = List.nth r.records !(r.cursor) in
    r.cursor := !(r.cursor) + 1;
    ("Record", record_json record)
  end
  else ("NullRecord", `Assoc [])

let result_peek fields =
  let r = get_result (int "resultId" fields) in
  if !(r.cursor) < List.length r.records then
    ("Record", record_json (List.nth r.records !(r.cursor)))
  else ("NullRecord", `Assoc [])

let result_list fields =
  let r = get_result (int "resultId" fields) in
  let remaining = List.filteri (fun i _ -> i >= !(r.cursor)) r.records |> List.map record_json in
  r.cursor := List.length r.records;
  ("RecordList", `Assoc [ ("records", `List remaining) ])

(* --- Summary --- *)

let stat key stats =
  match List.assoc_opt key stats with Some (Packstream.Int n) -> Int64.to_int n | _ -> 0

let counters_of metadata =
  let stats =
    match metadata with
    | Packstream.Map fields -> (
        match List.assoc_opt "stats" fields with Some (Packstream.Map s) -> s | _ -> [])
    | _ -> []
  in
  let n key = stat key stats in
  `Assoc
    [
      ("constraintsAdded", `Int (n "constraints-added"));
      ("constraintsRemoved", `Int (n "constraints-removed"));
      ("containsSystemUpdates", `Int (n "contains-system-updates"));
      ("containsUpdates", `Int (n "contains-updates"));
      ("indexesAdded", `Int (n "indexes-added"));
      ("indexesRemoved", `Int (n "indexes-removed"));
      ("labelsAdded", `Int (n "labels-added"));
      ("labelsRemoved", `Int (n "labels-removed"));
      ("nodesCreated", `Int (n "nodes-created"));
      ("nodesDeleted", `Int (n "nodes-deleted"));
      ("propertiesSet", `Int (n "properties-set"));
      ("relationshipsCreated", `Int (n "relationships-created"));
      ("relationshipsDeleted", `Int (n "relationships-deleted"));
      ("systemUpdates", `Int (n "system-updates"));
    ]

let metadata_string key metadata =
  match metadata with
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with Some (Packstream.String s) -> Some s | _ -> None)
  | _ -> None

let metadata_int key metadata =
  match metadata with
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with
      | Some (Packstream.Int n) -> Some (Int64.to_int n)
      | _ -> None)
  | _ -> None

let summary_of r =
  let metadata = r.summary in
  let major, minor = Conn.version r.conn in
  let agent = Option.value ~default:"" (Conn.server_agent r.conn) in
  let query_type =
    match metadata_string "type" metadata with Some t -> `String t | None -> `String "r"
  in
  let database = match metadata_string "db" metadata with Some d -> `String d | None -> `Null in
  let available = match metadata_int "t_first" metadata with Some n -> `Int n | None -> `Null in
  let consumed = match metadata_int "t_last" metadata with Some n -> `Int n | None -> `Null in
  `Assoc
    [
      ( "serverInfo",
        `Assoc
          [
            ("address", `String (Addressing.to_string (Conn.address r.conn)));
            ("agent", `String agent);
            ("protocolVersion", `String (Printf.sprintf "%d.%d" major minor));
          ] );
      ("counters", counters_of metadata);
      ("database", database);
      ("notifications", `Null);
      ("gqlStatusObjects", `List []);
      ("plan", `Null);
      ("profile", `Null);
      ( "query",
        `Assoc
          [
            ("text", `String r.query);
            ( "parameters",
              `Assoc (List.map (fun (k, v) -> (k, Testkit_values.to_yojson v)) r.parameters) );
          ] );
      ("queryType", query_type);
      ("resultAvailableAfter", available);
      ("resultConsumedAfter", consumed);
    ]

let result_consume fields =
  let id = int "resultId" fields in
  let r = get_result id in
  let summary = summary_of r in
  Hashtbl.remove results id;
  ("Summary", summary)

let handle ctx name data =
  let fields =
    match data with `Assoc fields -> fields | _ -> raise (Backend_error "data is not an object")
  in
  match name with
  | "StartTest" -> Some (start_test fields)
  | "GetFeatures" -> Some (get_features fields)
  | "NewDriver" -> Some (new_driver fields)
  | "DriverClose" -> Some (driver_close fields)
  | "NewSession" -> Some (new_session fields)
  | "SessionClose" -> Some (session_close fields)
  | "VerifyConnectivity" -> Some (verify_connectivity ctx fields)
  | "GetServerInfo" -> Some (get_server_info ctx fields)
  | "SessionRun" -> Some (session_run ctx fields)
  | "ResultNext" -> Some (result_next fields)
  | "ResultPeek" -> Some (result_peek fields)
  | "ResultList" -> Some (result_list fields)
  | "ResultConsume" -> Some (result_consume fields)
  | "ResolverResolutionCompleted" -> resolver_resolution_completed fields
  | _ -> raise (Backend_error ("No request handler for " ^ name))

(* Parse a request JSON and dispatch it. *)
let dispatch ctx json =
  try
    match Yojson.Safe.from_string json with
    | `Assoc fields ->
        let name = string "name" fields in
        let data =
          match List.assoc_opt "data" fields with Some data -> data | None -> `Assoc []
        in
        handle ctx name data
    | _ -> raise (Backend_error "Request is not an object")
  with
  | Backend_error message -> Some ("BackendError", `Assoc [ ("msg", `String message) ])
  | exn -> Some ("BackendError", `Assoc [ ("msg", `String (Printexc.to_string exn)) ])
