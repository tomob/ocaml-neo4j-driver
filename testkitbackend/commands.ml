(* TestKit command handlers.

   Dispatch a request ({"name": ..., "data": {...}}) to a handler and return the
   response (name, data). B0b adds the query path: drivers hold a lazily created
   connection (Conn), sessions run queries, and results stream records and a
   minimal summary. Transactions and routing are still unsupported.

   Modeled on the Python driver's testkitbackend/_async/requests.py. *)

open Neodriver
open Neodriver_eio

exception Backend_error of string

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
  address : string;
}

let drivers : (int, driver) Hashtbl.t = Hashtbl.create 16
let sessions : (int, session) Hashtbl.t = Hashtbl.create 16
let results : (int, result) Hashtbl.t = Hashtbl.create 16
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

(* Open the driver's connection on first use. *)
let ensure_conn net clock sw (driver : driver) =
  match !(driver.conn) with
  | Some conn -> Ok conn
  | None -> (
      match Conn.connect net clock sw (conn_config driver) with
      | Error error -> Error error
      | Ok conn ->
          driver.conn := Some conn;
          Ok conn)

let conn_of net clock sw (driver : driver) =
  match ensure_conn net clock sw driver with
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
      Hashtbl.add drivers id { uri; auth; user_agent; connection_timeout; conn = ref None };
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

let verify_connectivity net clock sw fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  ignore (conn_of net clock sw driver);
  ("Driver", `Assoc [ ("id", `Int id) ])

let get_server_info net clock sw fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  let conn = conn_of net clock sw driver in
  let major, minor = Conn.version conn in
  let agent = Option.value ~default:"" (Conn.server_agent conn) in
  ( "ServerInfo",
    `Assoc
      [
        ("address", `String (Printf.sprintf "%s:%d" driver.uri.host driver.uri.port));
        ("agent", `String agent);
        ("protocolVersion", `String (Printf.sprintf "%d.%d" major minor));
      ] )

let decode_params fields =
  match List.assoc_opt "params" fields with
  | Some (`Assoc params) -> List.map (fun (k, v) -> (k, Testkit_values.of_yojson v)) params
  | _ -> []

let session_run net clock sw fields =
  let session = get_session (int "sessionId" fields) in
  let driver = get_driver session.driver_id in
  let conn = conn_of net clock sw driver in
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
          let address = Printf.sprintf "%s:%d" driver.uri.host driver.uri.port in
          Hashtbl.add results id
            {
              fields = run_metadata.fields;
              records;
              cursor = ref 0;
              summary;
              query = cypher;
              parameters;
              conn;
              address;
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
            ("address", `String r.address);
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

let handle net clock sw name data =
  let fields =
    match data with `Assoc fields -> fields | _ -> raise (Backend_error "data is not an object")
  in
  match name with
  | "StartTest" -> start_test fields
  | "GetFeatures" -> get_features fields
  | "NewDriver" -> new_driver fields
  | "DriverClose" -> driver_close fields
  | "NewSession" -> new_session fields
  | "SessionClose" -> session_close fields
  | "VerifyConnectivity" -> verify_connectivity net clock sw fields
  | "GetServerInfo" -> get_server_info net clock sw fields
  | "SessionRun" -> session_run net clock sw fields
  | "ResultNext" -> result_next fields
  | "ResultPeek" -> result_peek fields
  | "ResultList" -> result_list fields
  | "ResultConsume" -> result_consume fields
  | _ -> raise (Backend_error ("No request handler for " ^ name))

(* Parse a request JSON and dispatch it. *)
let dispatch net clock sw json =
  try
    match Yojson.Safe.from_string json with
    | `Assoc fields ->
        let name = string "name" fields in
        let data =
          match List.assoc_opt "data" fields with Some data -> data | None -> `Assoc []
        in
        handle net clock sw name data
    | _ -> raise (Backend_error "Request is not an object")
  with
  | Backend_error message -> ("BackendError", `Assoc [ ("msg", `String message) ])
  | exn -> ("BackendError", `Assoc [ ("msg", `String (Printexc.to_string exn)) ])
