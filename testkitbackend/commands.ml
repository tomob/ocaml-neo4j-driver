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
exception Driver_error of Errors.t

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

(* The [errorId] of a RetryableNegative: a JSON integer, a numeric string, an
   empty string (no driver error) or absent. *)
let opt_error_id fields =
  match List.assoc_opt "errorId" fields with
  | Some (`Int n) -> Some n
  | Some (`String s) when s <> "" -> int_of_string_opt s
  | _ -> None

(* --- Backend state --- *)

type auth = { scheme : string; principal : string; credentials : string }

type driver = {
  uri_string : string;
  auth : auth;
  user_agent : string;
  connection_timeout : float;
  max_transaction_retry_time : float;
  resolver_registered : bool;
  driver : Driver.t;
  conn : Conn.t option ref;
}

type session = { driver_id : int; session : Session.t }
type result = { res : Neo4jResult.t }

let drivers : (int, driver) Hashtbl.t = Hashtbl.create 16
let sessions : (int, session) Hashtbl.t = Hashtbl.create 16
let transactions : (int, int * Tx.t) Hashtbl.t = Hashtbl.create 16
let results : (int, result) Hashtbl.t = Hashtbl.create 16
let custom_resolutions : (int, string list) Hashtbl.t = Hashtbl.create 16
let errors : (int, Errors.t) Hashtbl.t = Hashtbl.create 16
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

let get_transaction id =
  match Hashtbl.find_opt transactions id with
  | Some (session_id, tx) -> (session_id, tx)
  | None -> raise (Backend_error "unknown transaction")

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

(* Ask the harness to resolve a domain name (custom domain-name resolver) and
   return the literal addresses to try. The follow-up
   DomainNameResolutionCompleted request is consumed and processed here. *)
let domain_name_resolver ctx name =
  let id = new_id () in
  ctx.send "DomainNameResolutionRequired" (`Assoc [ ("id", `Int id); ("name", `String name) ]);
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
  match resolution with
  | Some addresses -> Ok addresses
  | None -> Error (Errors.Service_unavailable "no domain-name resolution received")

(* A connection for driver-level operations (acquired from the pool on first
   use, returned to it on DriverClose). *)
let ensure_conn (driver : driver) =
  match !(driver.conn) with
  | Some conn -> Ok conn
  | None -> (
      match Driver.acquire driver.driver with
      | Error error -> Error error
      | Ok conn ->
          driver.conn := Some conn;
          Ok conn)

let conn_of (driver : driver) =
  match ensure_conn driver with Ok conn -> conn | Error error -> raise (Driver_error error)

(* The session's connection (created lazily by the Session itself). *)
let session_conn (session : session) =
  match Session.conn session.session with
  | Ok conn -> conn
  | Error error -> raise (Driver_error error)

(* Close the session's open transaction (if any) and its connection. *)
let close_session_conns (session : session) = Session.close session.session

(* --- Handlers --- *)

let start_test _fields = ("RunTest", `Assoc [])

let get_features _fields =
  ("FeatureList", `Assoc [ ("features", `List (List.map (fun f -> `String f) Features.features)) ])

let new_driver ctx fields =
  let uri_string = string "uri" fields in
  let user_agent = Option.value ~default:"ocaml-neo4j-driver" (opt_string "userAgent" fields) in
  let auth = auth_of fields in
  let resolver_registered =
    match List.assoc_opt "resolverRegistered" fields with Some (`Bool b) -> b | _ -> false
  in
  let domain_name_resolver_registered =
    match List.assoc_opt "domainNameResolverRegistered" fields with
    | Some (`Bool b) -> b
    | _ -> false
  in
  let connection_timeout =
    match List.assoc_opt "connectionTimeoutMs" fields with
    | Some (`Int ms) -> float_of_int ms /. 1000.0
    | Some (`Intlit ms) -> (
        match float_of_string_opt ms with Some f -> f /. 1000.0 | None -> 30.0)
    | _ -> 30.0
  in
  let max_transaction_retry_time =
    match List.assoc_opt "maxTxRetryTimeMs" fields with
    | Some (`Int ms) -> float_of_int ms /. 1000.0
    | Some (`Intlit ms) -> (
        match float_of_string_opt ms with Some f -> f /. 1000.0 | None -> 30.0)
    | _ -> 30.0
  in
  let custom = if resolver_registered then Some (resolver ctx) else None in
  let custom_domain_name =
    if domain_name_resolver_registered then Some (domain_name_resolver ctx) else None
  in
  let conn_auth =
    Conn.{ scheme = auth.scheme; principal = auth.principal; credentials = auth.credentials }
  in
  match
    Driver.connect ?resolver:custom ?domain_name_resolver:custom_domain_name ~uri:uri_string
      ~auth:conn_auth ~user_agent ~connection_timeout ctx.net ctx.clock ctx.sw
  with
  | Error error -> raise (Driver_error error)
  | Ok driver ->
      let id = new_id () in
      Hashtbl.add drivers id
        {
          uri_string;
          auth;
          user_agent;
          connection_timeout;
          max_transaction_retry_time;
          resolver_registered;
          driver;
          conn = ref None;
        };
      ("Driver", `Assoc [ ("id", `Int id) ])

let driver_close fields =
  let id = int "driverId" fields in
  Hashtbl.iter
    (fun _ session -> if session.driver_id = id then close_session_conns session)
    sessions;
  (match Hashtbl.find_opt drivers id with
  | Some driver ->
      (match !(driver.conn) with Some conn -> Driver.release driver.driver conn | None -> ());
      Driver.close driver.driver
  | None -> ());
  Hashtbl.remove drivers id;
  ("Driver", `Assoc [ ("id", `Int id) ])

let new_session fields =
  let driver_id = int "driverId" fields in
  let driver = get_driver driver_id in
  let database = opt_string "database" fields in
  let access_mode =
    match opt_string "accessMode" fields with Some "r" -> Config.Read | _ -> Config.Write
  in
  let impersonated_user = opt_string "impersonatedUser" fields in
  let fetch_size =
    match List.assoc_opt "fetchSize" fields with Some (`Int n) -> Some n | _ -> None
  in
  let bookmarks =
    match List.assoc_opt "bookmarks" fields with
    | Some (`List bookmarks) ->
        List.map (function `String b -> b | _ -> raise (Backend_error "bad bookmark")) bookmarks
    | _ -> []
  in
  let config =
    Session.
      {
        database;
        access_mode;
        impersonated_user;
        fetch_size;
        bookmarks;
        max_transaction_retry_time = driver.max_transaction_retry_time;
        initial_retry_delay = 1.0;
        retry_delay_multiplier = 2.0;
        retry_delay_jitter_factor = 0.2;
      }
  in
  let id = new_id () in
  Hashtbl.add sessions id { driver_id; session = Driver.session ~config driver.driver };
  ("Session", `Assoc [ ("id", `Int id) ])

let session_close fields =
  let id = int "sessionId" fields in
  (match Hashtbl.find_opt sessions id with
  | Some session -> Session.close session.session
  | None -> ());
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

let verify_connectivity fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  ignore (conn_of driver);
  ("Driver", `Assoc [ ("id", `Int id) ])

let get_server_info fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  let conn = conn_of driver in
  let major, minor = Conn.version conn in
  let agent = Option.value ~default:"" (Conn.server_agent conn) in
  ( "ServerInfo",
    `Assoc
      [
        ("address", `String (Addressing.to_string (Conn.address conn)));
        ("agent", `String agent);
        ("protocolVersion", `String (Printf.sprintf "%d.%d" major minor));
      ] )

let check_multi_db_support fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  (* A lightweight connectivity check: acquire a connection for the default
     database (a routed driver fetches a routing table and connects to a
     reader); multi-db support is a Bolt 4+ protocol capability. *)
  match Driver.acquire ~mode:Config.Read driver.driver with
  | Ok conn ->
      let major, _minor = Conn.version conn in
      Driver.release driver.driver conn;
      ("MultiDBSupport", `Assoc [ ("id", `Int id); ("available", `Bool (major >= 4)) ])
  | Error error -> raise (Driver_error error)

let decode_params fields =
  match List.assoc_opt "params" fields with
  | Some (`Assoc params) -> List.map (fun (k, v) -> (k, Testkit_values.of_yojson v)) params
  | _ -> []

(* The [txMeta] and [timeout] (milliseconds) of a transaction request. *)
let tx_config fields =
  let metadata =
    match List.assoc_opt "txMeta" fields with
    | Some (`Assoc tx_meta) ->
        Some (List.map (fun (k, v) -> (k, Testkit_values.of_yojson v)) tx_meta)
    | _ -> None
  in
  let timeout =
    match List.assoc_opt "timeout" fields with
    | Some (`Int ms) -> Some (float_of_int ms /. 1000.0)
    | Some (`Intlit ms) -> Option.map (fun f -> f /. 1000.0) (float_of_string_opt ms)
    | _ -> None
  in
  (metadata, timeout)

let session_run _ctx fields =
  let session = get_session (int "sessionId" fields) in
  let cypher = string "cypher" fields in
  let parameters = decode_params fields in
  let metadata, timeout = tx_config fields in
  match Session.run session.session ~query:cypher ~parameters ?timeout ?metadata with
  | Error error -> raise (Driver_error error)
  | Ok result ->
      let id = new_id () in
      Hashtbl.add results id { res = result };
      ( "Result",
        `Assoc
          [
            ("id", `Int id);
            ("keys", `List (List.map (fun f -> `String f) (Neo4jResult.keys result)));
          ] )

(* --- Transactions --- *)

let session_begin_transaction _ctx fields =
  let session_id = int "sessionId" fields in
  let session = get_session session_id in
  let metadata, timeout = tx_config fields in
  match Session.begin_transaction ?metadata ?timeout session.session with
  | Error error -> raise (Driver_error error)
  | Ok tx ->
      let id = new_id () in
      Hashtbl.add transactions id (session_id, tx);
      ("Transaction", `Assoc [ ("id", `Int id) ])

(* Update the session after the transaction ends (bookmark from a successful
   commit, no bookmark otherwise). *)
let end_transaction session_id bookmark =
  match Hashtbl.find_opt sessions session_id with
  | Some session -> Session.mark_tx_ended session.session ~bookmark
  | None -> ()

(* A failed transaction leaves the session without a current transaction (the
   transaction object itself stays usable for a follow-up rollback). *)
let tx_failed session_id = end_transaction session_id None

let transaction_run _ctx fields =
  let session_id, tx = get_transaction (int "txId" fields) in
  let session = get_session session_id in
  let conn = session_conn session in
  let cypher = string "cypher" fields in
  let parameters = decode_params fields in
  let hydration = Conn.hydration conn in
  match Tx.run tx ~hydration ~query:cypher ~parameters with
  | Error error ->
      tx_failed session_id;
      raise (Driver_error error)
  | Ok result ->
      let id = new_id () in
      Hashtbl.add results id { res = result };
      ( "Result",
        `Assoc
          [
            ("id", `Int id);
            ("keys", `List (List.map (fun f -> `String f) (Neo4jResult.keys result)));
          ] )

let transaction_commit _ctx fields =
  let id = int "txId" fields in
  let session_id, tx = get_transaction id in
  match Tx.commit tx with
  | Error error ->
      tx_failed session_id;
      raise (Driver_error error)
  | Ok bookmark ->
      end_transaction session_id bookmark;
      ("Transaction", `Assoc [ ("id", `Int id) ])

let transaction_rollback _ctx fields =
  let id = int "txId" fields in
  let session_id, tx = get_transaction id in
  match Tx.rollback tx with
  | Error error -> raise (Driver_error error)
  | Ok () ->
      end_transaction session_id None;
      ("Transaction", `Assoc [ ("id", `Int id) ])

let transaction_close _ctx fields =
  let id = int "txId" fields in
  let session_id, tx = get_transaction id in
  match Tx.close tx with
  | Error error -> raise (Driver_error error)
  | Ok () ->
      end_transaction session_id None;
      ("Transaction", `Assoc [ ("id", `Int id) ])

let session_last_bookmarks fields =
  let session = get_session (int "sessionId" fields) in
  let bookmarks = Session.last_bookmarks session.session in
  ("Bookmarks", `Assoc [ ("bookmarks", `List (List.map (fun b -> `String b) bookmarks)) ])

let record_json record = `Assoc [ ("values", `List (List.map Testkit_values.to_yojson record)) ]

(* --- Result streaming --- *)

let result_next fields =
  let r = get_result (int "resultId" fields) in
  match Neo4jResult.next r.res with
  | Error error -> raise (Driver_error error)
  | Ok None -> ("NullRecord", `Assoc [])
  | Ok (Some record) -> ("Record", record_json record)

let result_peek fields =
  let r = get_result (int "resultId" fields) in
  match Neo4jResult.peek r.res with
  | Error error -> raise (Driver_error error)
  | Ok None -> ("NullRecord", `Assoc [])
  | Ok (Some record) -> ("Record", record_json record)

let result_list fields =
  let r = get_result (int "resultId" fields) in
  match Neo4jResult.values r.res with
  | Error error -> raise (Driver_error error)
  | Ok records -> ("RecordList", `Assoc [ ("records", `List (List.map record_json records)) ])

(* --- Summary --- *)

(* Render a hydrated [Values.t] as JSON for the summary's plan/profile/notification
   subtrees. *)
let rec values_to_plain = function
  | Values.Null -> `Null
  | Values.Bool b -> `Bool b
  | Values.Int n -> `Intlit (Int64.to_string n)
  | Values.Float f -> `Float f
  | Values.String s -> `String s
  | Values.Bytes _ -> `String "<bytes>"
  | Values.List l -> `List (List.map values_to_plain l)
  | Values.Map m -> `Assoc (List.map (fun (k, v) -> (k, values_to_plain v)) m)
  | _ -> `Null

let counters_json c =
  `Assoc
    [
      ("constraintsAdded", `Int c.Summary.constraints_added);
      ("constraintsRemoved", `Int c.Summary.constraints_removed);
      ("containsSystemUpdates", `Bool c.Summary.contains_system_updates);
      ("containsUpdates", `Bool c.Summary.contains_updates);
      ("indexesAdded", `Int c.Summary.indexes_added);
      ("indexesRemoved", `Int c.Summary.indexes_removed);
      ("labelsAdded", `Int c.Summary.labels_added);
      ("labelsRemoved", `Int c.Summary.labels_removed);
      ("nodesCreated", `Int c.Summary.nodes_created);
      ("nodesDeleted", `Int c.Summary.nodes_deleted);
      ("propertiesSet", `Int c.Summary.properties_set);
      ("relationshipsCreated", `Int c.Summary.relationships_created);
      ("relationshipsDeleted", `Int c.Summary.relationships_deleted);
      ("systemUpdates", `Int c.Summary.system_updates);
    ]

(* The GQL status objects of a summary, serialized for the TestKit Summary
   response (every field is required by the harness's GqlStatusObject). *)
let gql_status_json = function
  | Values.Map fields ->
      let string key fields =
        match List.assoc_opt key fields with Some (Values.String s) -> s | _ -> ""
      in
      let diagnostic =
        match List.assoc_opt "diagnostic_record" fields with Some (Values.Map d) -> d | _ -> []
      in
      let position =
        match List.assoc_opt "_position" diagnostic with
        | Some (Values.Map pos) -> (
            match
              (List.assoc_opt "column" pos, List.assoc_opt "line" pos, List.assoc_opt "offset" pos)
            with
            | Some (Values.Int column), Some (Values.Int line), Some (Values.Int offset) ->
                `Assoc
                  [
                    ("column", `Int (Int64.to_int column));
                    ("line", `Int (Int64.to_int line));
                    ("offset", `Int (Int64.to_int offset));
                  ]
            | _ -> `Null)
        | _ -> `Null
      in
      let is_notification = List.assoc_opt "neo4j_code" fields <> None in
      `Assoc
        [
          ("isNotification", `Bool is_notification);
          ("gqlStatus", `String (string "gql_status" fields));
          ("statusDescription", `String (string "status_description" fields));
          ("rawClassification", `Null);
          ("classification", `String (string "_classification" diagnostic));
          ("rawSeverity", `Null);
          ("severity", `String (string "_severity" diagnostic));
          ( "diagnosticRecord",
            match List.assoc_opt "diagnostic_record" fields with
            | Some value -> values_to_plain value
            | None -> `Assoc [] );
          ("position", position);
        ]
  | _ -> `Null

let summary_json s =
  let major, minor = s.Summary.server_info.protocol_version in
  let agent = Option.value ~default:"" s.Summary.server_info.agent in
  let int_or_null = function Some n -> `Int n | None -> `Null in
  let value_or_null = function Some v -> values_to_plain v | None -> `Null in
  `Assoc
    [
      ( "serverInfo",
        `Assoc
          [
            ("address", `String (Addressing.to_string s.Summary.server_info.address));
            ("agent", `String agent);
            ("protocolVersion", `String (Printf.sprintf "%d.%d" major minor));
          ] );
      ("counters", counters_json s.Summary.counters);
      ("database", match s.Summary.database with Some d -> `String d | None -> `Null);
      ( "notifications",
        match s.Summary.notifications with
        | [] -> `Null
        | items -> `List (List.map values_to_plain items) );
      ("gqlStatusObjects", `List (List.map gql_status_json s.Summary.gql_status_objects));
      ("plan", value_or_null s.Summary.plan);
      ("profile", value_or_null s.Summary.profile);
      ( "query",
        `Assoc
          [
            ("text", `String s.Summary.query);
            ( "parameters",
              `Assoc (List.map (fun (k, v) -> (k, Testkit_values.to_yojson v)) s.Summary.parameters)
            );
          ] );
      ("queryType", `String s.Summary.query_type);
      ("resultAvailableAfter", int_or_null s.Summary.result_available_after);
      ("resultConsumedAfter", int_or_null s.Summary.result_consumed_after);
    ]

let result_consume fields =
  let id = int "resultId" fields in
  let r = get_result id in
  match Neo4jResult.consume r.res with
  | Error error -> raise (Driver_error error)
  | Ok summary ->
      (* Keep the result registered: a second consume returns the cached
         summary again (like the Python driver). *)
      ("Summary", summary_json summary)

(* Expect exactly one record in the result stream. *)
let result_single fields =
  let r = get_result (int "resultId" fields) in
  match Neo4jResult.single r.res with
  | Error error -> raise (Driver_error error)
  | Ok record -> ("Record", record_json record)

(* Expect at most one record in the result stream. *)
let result_single_optional fields =
  let r = get_result (int "resultId" fields) in
  let record =
    match Neo4jResult.single_optional r.res with
    | Error error -> raise (Driver_error error)
    | Ok None -> `Null
    | Ok (Some record) -> record_json record
  in
  ("RecordOptional", `Assoc [ ("record", record); ("warnings", `List []) ])

(* --- Routing table (test-support) --- *)

(* The driver's cached routing table for a database, or the empty shape for a
   direct [bolt://] driver / before the first fetch (like the Python backend). *)
let get_routing_table fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  let database = opt_string "database" fields in
  let table = Driver.get_routing_table driver.driver ~database in
  let db_json = function Some d -> `String d | None -> `Null in
  let addresses =
   fun addresses -> `List (List.map (fun a -> `String (Addressing.to_string a)) addresses)
  in
  match table with
  | None ->
      ( "RoutingTable",
        `Assoc
          [
            ("database", db_json database);
            ("ttl", `Int 0);
            ("routers", `List []);
            ("readers", `List []);
            ("writers", `List []);
          ] )
  | Some table ->
      ( "RoutingTable",
        `Assoc
          [
            ("database", db_json (Routing_table.database table));
            ("ttl", `Int (Routing_table.ttl_seconds table));
            ("routers", addresses (Routing_table.routers table));
            ("readers", addresses (Routing_table.readers table));
            ("writers", addresses (Routing_table.writers table));
          ] )

(* Force a fresh fetch of the routing table for a database (bookmarks optional)
   and report the driver; a failed fetch is a driver error. *)
let forced_routing_table_update fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  let database = opt_string "database" fields in
  let bookmarks =
    match List.assoc_opt "bookmarks" fields with
    | Some (`List bookmarks) ->
        List.map (function `String b -> b | _ -> raise (Backend_error "bad bookmark")) bookmarks
    | _ -> []
  in
  match Driver.force_routing_table_update driver.driver ~database ~bookmarks with
  | Ok () -> ("Driver", `Assoc [ ("id", `Int id) ])
  | Error error -> raise (Driver_error error)

let handle ctx name data =
  let fields =
    match data with `Assoc fields -> fields | _ -> raise (Backend_error "data is not an object")
  in
  match name with
  | "StartTest" -> Some (start_test fields)
  | "StartSubTest" -> Some (start_test fields)
  | "GetFeatures" -> Some (get_features fields)
  | "NewDriver" -> Some (new_driver ctx fields)
  | "DriverClose" -> Some (driver_close fields)
  | "NewSession" -> Some (new_session fields)
  | "SessionClose" -> Some (session_close fields)
  | "VerifyConnectivity" -> Some (verify_connectivity fields)
  | "GetServerInfo" -> Some (get_server_info fields)
  | "CheckMultiDBSupport" -> Some (check_multi_db_support fields)
  | "SessionRun" -> Some (session_run ctx fields)
  | "ResultNext" -> Some (result_next fields)
  | "ResultPeek" -> Some (result_peek fields)
  | "ResultList" -> Some (result_list fields)
  | "ResultConsume" -> Some (result_consume fields)
  | "ResultSingle" -> Some (result_single fields)
  | "ResultSingleOptional" -> Some (result_single_optional fields)
  | "SessionBeginTransaction" -> Some (session_begin_transaction ctx fields)
  | "TransactionRun" -> Some (transaction_run ctx fields)
  | "TransactionCommit" -> Some (transaction_commit ctx fields)
  | "TransactionRollback" -> Some (transaction_rollback ctx fields)
  | "TransactionClose" -> Some (transaction_close ctx fields)
  | "SessionLastBookmarks" -> Some (session_last_bookmarks fields)
  | "GetRoutingTable" -> Some (get_routing_table fields)
  | "ForcedRoutingTableUpdate" -> Some (forced_routing_table_update fields)
  | "ResolverResolutionCompleted" -> resolver_resolution_completed fields
  | _ -> raise (Backend_error ("No request handler for " ^ name))

(* A driver error surfaced to the harness (analog of the Python driver_exc): a
   Neo4j error carries its [code]; other driver errors carry just a message. The
   error is stored under an [id] so the harness can reference it back (e.g. the
   [errorId] of a RetryableNegative). *)
let driver_error_json error =
  let id = new_id () in
  Hashtbl.add errors id error;
  let retryable = Errors.is_retryable error in
  match error with
  | Errors.Neo4j server ->
      let fields =
        [
          ("id", `Int id);
          ("retryable", `Bool retryable);
          ("errorType", `String "neodriver.Neo4jError");
          ("msg", `String server.message);
          ("code", `String server.code);
        ]
      in
      let fields =
        match server.gql_status with
        | Some status -> ("gqlStatus", `String status) :: fields
        | None -> fields
      in
      ("DriverError", `Assoc fields)
  | _ ->
      ( "DriverError",
        `Assoc
          [
            ("id", `Int id);
            ("retryable", `Bool retryable);
            ("errorType", `String "neodriver.DriverError");
            ("msg", `String (Errors.to_string error));
          ] )

(* Dispatch a single (non-managed) request JSON to the [handle] table. *)
let dispatch_plain ctx json =
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
  | Driver_error error -> Some (driver_error_json error)
  | exn -> Some ("BackendError", `Assoc [ ("msg", `String (Printexc.to_string exn)) ])

(* --- Managed transactions --- *)

(* The unit of work of a managed transaction: announce a new attempt with
   RetryableTry and then serve requests until the harness says the work finished
   (RetryablePositive) or failed (RetryableNegative, referencing a driver error
   by id, or absent for an application error). *)
let rec managed_work ctx session_id tx =
  let id = new_id () in
  Hashtbl.add transactions id (session_id, tx);
  ctx.send "RetryableTry" (`Assoc [ ("id", `Int id) ]);
  let rec loop () =
    match ctx.read () with
    | None -> Error (Session.Driver (Errors.Service_unavailable "harness closed mid-transaction"))
    | Some json -> (
        match Yojson.Safe.from_string json with
        | `Assoc request_fields -> (
            match List.assoc_opt "name" request_fields with
            | Some (`String "RetryablePositive") -> Ok ()
            | Some (`String "RetryableNegative") -> (
                let data =
                  match List.assoc_opt "data" request_fields with
                  | Some data -> data
                  | None -> `Assoc []
                in
                match opt_error_id (match data with `Assoc f -> f | _ -> []) with
                | Some error_id -> (
                    match Hashtbl.find_opt errors error_id with
                    | Some error -> Error (Session.Driver error)
                    | None -> Error (Session.Driver (Errors.Service_unavailable "unknown error id"))
                    )
                | None -> Error Session.Client)
            | _ -> (
                match dispatch ctx json with
                | None -> loop ()
                | Some (name, data) ->
                    ctx.send name data;
                    loop ()))
        | _ -> Error (Session.Driver (Errors.Service_unavailable "malformed request")))
  in
  loop ()

and managed_transaction ctx fields ~mode =
  let session_id = int "sessionId" fields in
  let session = get_session session_id in
  let metadata, timeout = tx_config fields in
  let work tx = managed_work ctx session_id tx in
  match Session.execute session.session ~mode ?metadata ?timeout work with
  | Ok () -> Some ("RetryableDone", `Assoc [])
  | Error (Session.Driver error) -> Some (driver_error_json error)
  | Error Session.Client -> Some ("FrontendError", `Assoc [ ("msg", `String "Client said no") ])

(* Parse a request JSON and dispatch it (managed transaction requests are routed
   to the managed flow first). *)
and dispatch ctx json =
  try
    match Yojson.Safe.from_string json with
    | `Assoc fields -> (
        let data = match List.assoc_opt "data" fields with Some (`Assoc data) -> data | _ -> [] in
        match string "name" fields with
        | "SessionReadTransaction" -> managed_transaction ctx data ~mode:Config.Read
        | "SessionWriteTransaction" -> managed_transaction ctx data ~mode:Config.Write
        | _ -> dispatch_plain ctx json)
    | _ -> raise (Backend_error "Request is not an object")
  with
  | Backend_error message -> Some ("BackendError", `Assoc [ ("msg", `String message) ])
  | Driver_error error -> Some (driver_error_json error)
  | exn -> Some ("BackendError", `Assoc [ ("msg", `String (Printexc.to_string exn)) ])
