(* TestKit command handlers.

   Dispatch a request ({"name": ..., "data": {...}}) to a handler and return the
   response (name, data), or [None] for handlers that are silent (the harness
   sends no response expected, e.g. ResolverResolutionCompleted). The context
   provides the network resources and lets handlers push unsolicited messages to
   the harness and read the follow-up request (custom address resolution).

   Modeled on the Python driver's testkitbackend/_async/requests.py. *)

open Neodriver
open Neodriver_eio
open Tk_errors

let ( let* ) = Result.bind

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

type driver = {
  uri_string : string;
  auth : Conn.auth;
  user_agent : string;
  connection_timeout : float;
  max_transaction_retry_time : float;
  resolver_registered : bool;
  driver : Driver.t;
}

type session = { driver_id : int; session : Session.t }
type result = { res : Neo4jResult.t }

let drivers : (int, driver) Hashtbl.t = Hashtbl.create 16
let sessions : (int, session) Hashtbl.t = Hashtbl.create 16
let transactions : (int, int * Tx.t) Hashtbl.t = Hashtbl.create 16
let results : (int, result) Hashtbl.t = Hashtbl.create 16
let custom_resolutions : (int, string list) Hashtbl.t = Hashtbl.create 16
let errors : (int, Errors.t) Hashtbl.t = Hashtbl.create 16
let auth_managers : (int, Auth_manager.t) Hashtbl.t = Hashtbl.create 16
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

(* --- Auth tokens and managers (phase A8) --- *)

(* The auth token managers created by NewAuthTokenManager /
   NewBasicAuthTokenManager / NewBearerAuthTokenManager, keyed by id (the
   shared id space). NewDriver's authTokenManagerId refers to one of them. *)

(* Seconds on a consistent scale (an arbitrary epoch) for the bearer managers'
   expiry checks. *)
let now_seconds clock () =
  Int64.to_float (Mtime.to_uint64_ns (Eio.Time.Mono.now clock)) /. 1_000_000_000.

let rec value_of_json = function
  | `Null -> Packstream.Null
  | `Bool b -> Packstream.Bool b
  | `Int n -> Packstream.Int (Int64.of_int n)
  | `Intlit s -> (
      match Int64.of_string_opt s with Some n -> Packstream.Int n | None -> Packstream.String s)
  | `Float f -> Packstream.Float f
  | `String s -> Packstream.String s
  | `List items -> Packstream.List (List.map value_of_json items)
  | `Assoc fields -> Packstream.Map (List.map (fun (k, v) -> (k, value_of_json v)) fields)

let rec value_json = function
  | Packstream.Null -> `Null
  | Packstream.Bool b -> `Bool b
  | Packstream.Int n -> `Intlit (Int64.to_string n)
  | Packstream.Float f -> `Float f
  | Packstream.String s -> `String s
  | Packstream.Bytes b -> `String (Bytes.to_string b)
  | Packstream.List items -> `List (List.map value_json items)
  | Packstream.Map fields -> `Assoc (List.map (fun (k, v) -> (k, value_json v)) fields)
  | Packstream.Uuid uuid -> `String uuid
  | Packstream.Structure (tag, fields) ->
      `Assoc [ ("tag", `Int tag); ("fields", `List (List.map value_json fields)) ]

(* Parse an AuthorizationToken ({"name": "AuthorizationToken", "data": {...}})
   into a driver token. *)
let token_of_json = function
  | `Assoc token_fields -> (
      match List.assoc_opt "data" token_fields with
      | Some (`Assoc data) -> (
          let scheme = string "scheme" data in
          let principal = opt_string "principal" data in
          let credentials = opt_string "credentials" data in
          let realm = opt_string "realm" data in
          let parameters =
            match List.assoc_opt "parameters" data with
            | Some (`Assoc fields) -> List.map (fun (k, v) -> (k, value_of_json v)) fields
            | _ -> []
          in
          match scheme with
          | "basic" ->
              Ok
                (Conn.basic_auth
                   ~principal:(Option.value ~default:"neo4j" principal)
                   ~credentials:(Option.value ~default:"" credentials)
                   ?realm ())
          | "bearer" -> Ok (Conn.bearer_auth (Option.value ~default:"" credentials))
          | "kerberos" ->
              Ok
                (Auth_manager.custom_auth ~principal:""
                   ~credentials:(Option.value ~default:"" credentials)
                   "kerberos")
          | scheme ->
              Ok (Auth_manager.custom_auth ?principal ?credentials ?realm ~parameters scheme))
      | _ -> Error (Errors.Configuration_error "authorizationToken has no data"))
  | _ -> Error (Errors.Configuration_error "bad authorizationToken")

(* Serialise a token as an AuthorizationToken for the harness. *)
let token_json (token : Auth_manager.token) =
  let data =
    ("scheme", `String token.scheme)
    :: (match token.principal with Some p -> [ ("principal", `String p) ] | None -> [])
    @ (match token.credentials with Some c -> [ ("credentials", `String c) ] | None -> [])
    @ (match token.realm with Some r -> [ ("realm", `String r) ] | None -> [])
    @
    if token.parameters = [] then []
    else [ ("parameters", `Assoc (List.map (fun (k, v) -> (k, value_json v)) token.parameters)) ]
  in
  `Assoc [ ("name", `String "AuthorizationToken"); ("data", `Assoc data) ]

(* Whether a requestId JSON value equals [key] (an int or a numeric string). *)
let request_id_eq key = function
  | Some (`Int n) -> n = key
  | Some (`Intlit s) -> ( match int_of_string_opt s with Some n -> n = key | None -> false)
  | _ -> false

(* Push a request to the harness and read the follow-up Completed request (like
   the resolver): the exchange is synchronous. Returns the Completed's [data]
   fields, or [None] when the harness closed. *)
let read_completed ctx name data =
  ctx.send name data;
  match ctx.read () with
  | None -> None
  | Some json -> (
      match Yojson.Safe.from_string json with
      | `Assoc fields -> (
          match List.assoc_opt "data" fields with Some (`Assoc data) -> Some data | _ -> None)
      | _ -> None)

(* The token of a Completed auth token supply whose requestId matches [key]. *)
let completed_token key data =
  if request_id_eq key (List.assoc_opt "requestId" data) then
    match List.assoc_opt "auth" data with
    | Some auth -> token_of_json auth
    | None -> raise (Backend_error "bad completed auth token")
  else raise (Backend_error "bad requestId in completed auth token")

(* The get_auth of a custom NewAuthTokenManager: push
   AuthTokenManagerGetAuthRequest and await AuthTokenManagerGetAuthCompleted. *)
let auth_manager_get_auth ctx id () =
  let key = new_id () in
  match
    read_completed ctx "AuthTokenManagerGetAuthRequest"
      (`Assoc [ ("id", `Int key); ("authTokenManagerId", `Int id) ])
  with
  | Some data -> completed_token key data
  | None -> Error (Errors.Service_unavailable "harness closed during auth token supply")

(* The handle_security_exception of a custom manager: push
   AuthTokenManagerHandleSecurityExceptionRequest and await the Completed. *)
let auth_manager_handle_security_exception ctx id auth error =
  let key = new_id () in
  let error_code = match Errors.code error with Some code -> code | None -> "" in
  match
    read_completed ctx "AuthTokenManagerHandleSecurityExceptionRequest"
      (`Assoc
         [
           ("id", `Int key);
           ("authTokenManagerId", `Int id);
           ("auth", token_json auth);
           ("errorCode", `String error_code);
         ])
  with
  | Some data when request_id_eq key (List.assoc_opt "requestId" data) -> (
      match List.assoc_opt "handled" data with
      | Some (`Bool handled) -> Ok handled
      | _ -> raise (Backend_error "bad security exception completed"))
  | Some _ -> raise (Backend_error "bad requestId in security exception completed")
  | None -> Error (Errors.Service_unavailable "harness closed during security exception")

(* The token provider of a NewBasicAuthTokenManager: push
   BasicAuthTokenProviderRequest and await BasicAuthTokenProviderCompleted. *)
let basic_auth_token_provider ctx id () =
  let key = new_id () in
  match
    read_completed ctx "BasicAuthTokenProviderRequest"
      (`Assoc [ ("id", `Int key); ("basicAuthTokenManagerId", `Int id) ])
  with
  | Some data -> completed_token key data
  | None -> Error (Errors.Service_unavailable "harness closed during basic auth token supply")

(* The token provider of a NewBearerAuthTokenManager: push
   BearerAuthTokenProviderRequest and await BearerAuthTokenProviderCompleted
   (an AuthTokenAndExpiration with the token and its validity in ms). *)
let bearer_auth_token_provider ctx id () =
  let key = new_id () in
  match
    read_completed ctx "BearerAuthTokenProviderRequest"
      (`Assoc [ ("id", `Int key); ("bearerAuthTokenManagerId", `Int id) ])
  with
  | Some data when request_id_eq key (List.assoc_opt "requestId" data) -> (
      match List.assoc_opt "auth" data with
      | Some (`Assoc wrapper) -> (
          match List.assoc_opt "data" wrapper with
          | Some (`Assoc inner) -> (
              match List.assoc_opt "auth" inner with
              | Some auth ->
                  let* token = token_of_json auth in
                  let expires_in_ms =
                    match List.assoc_opt "expiresInMs" inner with
                    | Some (`Int ms) -> Some (float_of_int ms /. 1000.0)
                    | Some (`Intlit s) -> (
                        match float_of_string_opt s with
                        | Some f -> Some (f /. 1000.0)
                        | None -> None)
                    | _ -> None
                  in
                  let expires_at =
                    Option.map (fun seconds -> now_seconds ctx.clock () +. seconds) expires_in_ms
                  in
                  Ok { Auth_manager.token; expires_at }
              | _ -> raise (Backend_error "bad AuthTokenAndExpiration auth"))
          | _ -> raise (Backend_error "bad AuthTokenAndExpiration"))
      | _ -> raise (Backend_error "bad BearerAuthTokenProviderCompleted"))
  | Some _ -> raise (Backend_error "bad requestId in bearer completed")
  | None -> Error (Errors.Service_unavailable "harness closed during bearer auth token supply")

let auth_of fields =
  match List.assoc_opt "authorizationToken" fields with
  | Some token -> (
      match token_of_json token with
      | Ok auth -> auth
      | Error error -> raise (Backend_error (Errors.to_string error)))
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

(* The session's connection (created lazily by the Session itself). *)
let session_conn (session : session) =
  match Session.conn session.session with
  | Ok conn -> conn
  | Error error -> raise (Driver_error error)

(* The connection of the session's in-flight explicit transaction, without
   re-authentication (the transaction owns it). *)
let session_conn_for_tx (session : session) =
  match Session.tx_conn session.session with
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
  let user_agent = Option.value ~default:Conn.default_user_agent (opt_string "userAgent" fields) in
  (* A driver may authenticate with a fixed token (authorizationToken) or with
     an auth token manager (authTokenManagerId); the two are mutually
     exclusive. *)
  let auth, auth_manager =
    match List.assoc_opt "authTokenManagerId" fields with
    | Some (`Int id) -> (
        match Hashtbl.find_opt auth_managers id with
        | Some manager -> (Conn.basic_auth (), Some manager)
        | None -> raise (Backend_error "unknown auth token manager"))
    | Some (`Intlit s) -> (
        match int_of_string_opt s with
        | Some id -> (
            match Hashtbl.find_opt auth_managers id with
            | Some manager -> (Conn.basic_auth (), Some manager)
            | None -> raise (Backend_error "unknown auth token manager"))
        | None -> raise (Backend_error "bad authTokenManagerId"))
    | _ -> (auth_of fields, None)
  in
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
  let pool_config =
    let max_connection_pool_size =
      match List.assoc_opt "maxConnectionPoolSize" fields with
      | Some (`Int n) -> n
      | Some (`Intlit n) -> ( match int_of_string_opt n with Some n -> n | None -> 100)
      | _ -> Config.default_pool_config.max_connection_pool_size
    in
    let connection_acquisition_timeout =
      match List.assoc_opt "connectionAcquisitionTimeoutMs" fields with
      | Some (`Int ms) -> float_of_int ms /. 1000.0
      | Some (`Intlit ms) -> (
          match float_of_string_opt ms with Some f -> f /. 1000.0 | None -> 60.0)
      | _ -> Config.default_pool_config.connection_acquisition_timeout
    in
    let telemetry_disabled =
      match List.assoc_opt "telemetryDisabled" fields with Some (`Bool b) -> b | _ -> false
    in
    match
      Config.make_pool_config ~max_connection_pool_size ~connection_acquisition_timeout
        ~telemetry_disabled ()
    with
    | Ok pool_config -> pool_config
    | Error error -> raise (Driver_error error)
  in
  match
    Driver.connect ?resolver:custom ?domain_name_resolver:custom_domain_name ~uri:uri_string ~auth
      ?auth_manager ~user_agent ~connection_timeout ~pool_config ctx.net ctx.clock ctx.sw
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
        };
      ("Driver", `Assoc [ ("id", `Int id) ])

let driver_close fields =
  let id = int "driverId" fields in
  Hashtbl.iter
    (fun _ session -> if session.driver_id = id then close_session_conns session)
    sessions;
  (match Hashtbl.find_opt drivers id with Some driver -> Driver.close driver.driver | None -> ());
  Hashtbl.remove drivers id;
  ("Driver", `Assoc [ ("id", `Int id) ])

(* A custom NewAuthTokenManager: get_auth and handle_security_exception both
   round-trip to the harness. *)
let new_auth_token_manager ctx _fields =
  let id = new_id () in
  let manager : Auth_manager.t =
    {
      get_auth = auth_manager_get_auth ctx id;
      handle_security_exception = auth_manager_handle_security_exception ctx id;
    }
  in
  Hashtbl.add auth_managers id manager;
  ("AuthTokenManager", `Assoc [ ("id", `Int id) ])

(* NewBasicAuthTokenManager: a basic manager whose provider asks the harness for
   the fresh password (refreshed on Unauthorized). *)
let new_basic_auth_token_manager ctx _fields =
  let id = new_id () in
  let manager = Auth_manager.basic ~provider:(basic_auth_token_provider ctx id) in
  Hashtbl.add auth_managers id manager;
  ("BasicAuthTokenManager", `Assoc [ ("id", `Int id) ])

(* NewBearerAuthTokenManager: a bearer manager whose provider asks the harness
   for a fresh token and its validity. *)
let new_bearer_auth_token_manager ctx _fields =
  let id = new_id () in
  let manager =
    Auth_manager.bearer ~now:(now_seconds ctx.clock) ~provider:(bearer_auth_token_provider ctx id)
  in
  Hashtbl.add auth_managers id manager;
  ("BearerAuthTokenManager", `Assoc [ ("id", `Int id) ])

(* AuthTokenManagerClose: drop the manager (also covers the basic / bearer
   variants) and echo the id. *)
let auth_token_manager_close fields =
  let id = int "id" fields in
  Hashtbl.remove auth_managers id;
  ("AuthTokenManager", `Assoc [ ("id", `Int id) ])

(* CheckSessionAuthSupport: whether the server supports re-authentication
   (Bolt >= 5.1), i.e. session-level auth (user switching). A driver connection
   is made and the negotiated protocol checked. *)
let check_session_auth_support fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  let available =
    match Driver.supports_session_auth driver.driver with
    | Ok available -> available
    | Error _ -> false
  in
  ("SessionAuthSupport", `Assoc [ ("id", `Int id); ("available", `Bool available) ])

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
  (* A session may carry its own auth token (user switching, Bolt >= 5.1): it is
     used instead of the driver's auth for this session's connections. *)
  let auth =
    match List.assoc_opt "authorizationToken" fields with
    | Some token -> (
        match token_of_json token with
        | Ok auth -> Some auth
        | Error error -> raise (Backend_error (Errors.to_string error)))
    | _ -> None
  in
  let config =
    Session.
      {
        database;
        access_mode;
        impersonated_user;
        fetch_size;
        bookmarks;
        auth;
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
  (* Acquire a fresh connection for the default database (a routed driver
     fetches a routing table and connects to a reader); re-acquired on every
     call so a changed cluster is re-discovered. *)
  match Driver.acquire ~mode:Config.Read driver.driver with
  | Ok conn ->
      Driver.release driver.driver conn;
      ("Driver", `Assoc [ ("id", `Int id) ])
  | Error error -> raise (Driver_error error)

let get_server_info fields =
  let id = int "driverId" fields in
  let driver = get_driver id in
  match Driver.acquire ~mode:Config.Read driver.driver with
  | Ok conn ->
      let major, minor = Conn.version conn in
      let agent = Option.value ~default:"" (Conn.server_agent conn) in
      let address = Addressing.to_string (Conn.address conn) in
      Driver.release driver.driver conn;
      ( "ServerInfo",
        `Assoc
          [
            ("address", `String address);
            ("agent", `String agent);
            ("protocolVersion", `String (Printf.sprintf "%d.%d" major minor));
          ] )
  | Error error -> raise (Driver_error error)

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
  let conn = session_conn_for_tx session in
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

(* Closing a transaction is best-effort (like the Python driver's [close]):
   a connection already terminated by the server (e.g. the stub's [S: <EXIT>]
   after a FAILURE) makes the rollback fail with "Connection closed"; the
   transaction is closed anyway. *)
let transaction_close _ctx fields =
  let id = int "txId" fields in
  let session_id, tx = get_transaction id in
  (match Tx.close tx with Ok () -> () | Error _ -> ());
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

(* The parsed notification severity/category levels: the raw string is mapped to
   the known enum values; anything else is UNKNOWN (like the Python driver's
   _SEVERITY_LOOKUP/_CATEGORY_LOOKUP). *)
let parsed_severity = function ("WARNING" | "INFORMATION") as s -> s | _ -> "UNKNOWN"

let parsed_category = function
  | ( "HINT" | "UNRECOGNIZED" | "UNSUPPORTED" | "PERFORMANCE" | "DEPRECATION" | "GENERIC"
    | "SECURITY" | "TOPOLOGY" | "SCHEMA" ) as c ->
      c
  | _ -> "UNKNOWN"

(* The position of a notification/status: [column]/[offset]/[line]. *)
let position_json = function
  | Some (Values.Map pos) -> (
      let int key =
        match List.assoc_opt key pos with Some (Values.Int n) -> Int64.to_int n | _ -> 0
      in
      match List.assoc_opt "column" pos with
      | None -> `Null
      | Some _ ->
          `Assoc
            [
              ("column", `Int (int "column"));
              ("offset", `Int (int "offset"));
              ("line", `Int (int "line"));
            ])
  | _ -> `Null

(* A summary notification, serialized for the TestKit Summary response. From
   Bolt 5.0 the parsed severity and category levels are added
   (rawSeverityLevel/severityLevel/rawCategory/category), like the Python
   driver's SummaryNotification; a legacy Bolt 4.x notification passes the raw
   fields through, dropping the raw [severity] only when a [position] is
   present (the legacy TestKit shape). *)
let notification_json major = function
  | Values.Map fields ->
      let full = major >= 5 in
      if not full then
        let has_position = List.mem_assoc "position" fields in
        `Assoc
          (List.filter_map
             (fun (k, v) ->
               if k = "severity" && has_position then None else Some (k, values_to_plain v))
             fields)
      else
        let string key =
          match List.assoc_opt key fields with Some (Values.String s) -> s | _ -> ""
        in
        let position =
          match List.assoc_opt "position" fields with
          | Some _ as pos -> position_json pos
          | None -> `Null
        in
        let base =
          [ ("description", `String (string "description")); ("code", `String (string "code")) ]
          @ (match List.assoc_opt "position" fields with
            | Some _ -> [ ("position", position) ]
            | None -> [])
          @ [ ("title", `String (string "title")) ]
        in
        let severity = string "severity" in
        let category = string "category" in
        `Assoc
          ([
             ("rawSeverityLevel", `String severity);
             ("severityLevel", `String (parsed_severity severity));
             ("rawCategory", `String category);
             ("category", `String (parsed_category category));
           ]
          @ base)
  | _ -> `Null

(* The default diagnostic-record values the driver fills in when the server
   omitted them. *)
let default_diagnostic_entries =
  [
    ("OPERATION", Values.String "");
    ("OPERATION_CODE", Values.String "0");
    ("CURRENT_SCHEMA", Values.String "/");
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
      let raw_classification =
        match List.assoc_opt "_classification" diagnostic with
        | Some (Values.String s) -> `String s
        | _ -> `Null
      in
      let raw_severity =
        match List.assoc_opt "_severity" diagnostic with
        | Some (Values.String s) -> `String s
        | _ -> `Null
      in
      let is_notification = List.assoc_opt "neo4j_code" fields <> None in
      `Assoc
        [
          ("isNotification", `Bool is_notification);
          ("gqlStatus", `String (string "gql_status" fields));
          ("statusDescription", `String (string "status_description" fields));
          ("rawClassification", raw_classification);
          ("classification", `String (parsed_category (string "_classification" diagnostic)));
          ("rawSeverity", raw_severity);
          ("severity", `String (parsed_severity (string "_severity" diagnostic)));
          ( "diagnosticRecord",
            match List.assoc_opt "diagnostic_record" fields with
            | Some (Values.Map d) ->
                let d =
                  List.fold_left
                    (fun acc (k, v) -> if List.mem_assoc k acc then acc else (k, v) :: acc)
                    d default_diagnostic_entries
                in
                `Assoc (List.map (fun (k, v) -> (k, Testkit_values.to_yojson v)) d)
            | Some value -> `Assoc [ ("value", Testkit_values.to_yojson value) ]
            | None ->
                `Assoc
                  (List.map
                     (fun (k, v) -> (k, Testkit_values.to_yojson v))
                     (List.rev default_diagnostic_entries)) );
          ("position", position_json (List.assoc_opt "_position" diagnostic));
        ]
  | _ -> `Null

(* The default status for a Bolt < 5.6 summary (the server sent no [statuses]):
   Success when records were pulled, No Data when the query had keys but no
   records, Omitted Result otherwise (like the Python driver). *)
let default_legacy_status s =
  let gql_status, description =
    if s.Summary.had_records then ("00000", "note: successful completion")
    else if s.Summary.had_keys then ("02000", "note: no data")
    else ("00001", "note: successful completion - omitted result")
  in
  Values.Map
    [
      ("gql_status", Values.String gql_status);
      ("status_description", Values.String description);
      ("diagnostic_record", Values.Map (List.rev default_diagnostic_entries));
    ]

(* A Bolt < 5.6 notification converted into a GQL status object: warning
   notifications get [01N42], information [03N42] (the Python driver's
   _from_notification_metadata). A missing description falls back to the
   Python driver's "warn: unknown warning" / "info: unknown notification". *)
let legacy_notification_status = function
  | Values.Map fields ->
      let string key =
        match List.assoc_opt key fields with Some (Values.String s) -> s | _ -> ""
      in
      let severity = string "severity" in
      let description = string "description" in
      let diagnostic =
        List.rev default_diagnostic_entries
        @ (match severity with "" -> [] | s -> [ ("_severity", Values.String s) ])
        @ (match string "category" with "" -> [] | c -> [ ("_classification", Values.String c) ])
        @
        match List.assoc_opt "position" fields with
        | Some value -> [ ("_position", value) ]
        | None -> []
      in
      let gql_status = if severity = "WARNING" then "01N42" else "03N42" in
      let status_description =
        if description <> "" then description
        else if severity = "WARNING" then "warn: unknown warning"
        else "info: unknown notification"
      in
      Values.Map
        [
          ("gql_status", Values.String gql_status);
          ("status_description", Values.String status_description);
          ("neo4j_code", Values.String (string "code"));
          ("diagnostic_record", Values.Map diagnostic);
        ]
  | _ -> Values.Null

(* The GQL status precedence of the Python driver: no data (02xxx) > warning
   (01xxx) > success (00xxx) > informational (03xxx). *)
let legacy_status_order = function
  | Values.Map fields -> (
      match List.assoc_opt "gql_status" fields with
      | Some (Values.String s) when String.length s >= 2 -> (
          match String.sub s 0 2 with "02" -> 3 | "01" -> 2 | "00" -> 1 | _ -> 0)
      | _ -> 0)
  | _ -> 0

(* The GQL status objects of a summary. From Bolt 5.6 the server sends a
   [statuses] field; on older versions the driver synthesizes them from the
   summary's notifications and whether records were seen. *)
let gql_status_objects_json s =
  match s.Summary.gql_status_objects with
  | [] ->
      let statuses =
        List.map legacy_notification_status s.Summary.notifications @ [ default_legacy_status s ]
      in
      let statuses =
        List.sort (fun a b -> compare (legacy_status_order b) (legacy_status_order a)) statuses
      in
      List.map gql_status_json statuses
  | statuses -> List.map gql_status_json statuses

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
        | items -> `List (List.map (notification_json major) items) );
      ("gqlStatusObjects", `List (gql_status_objects_json s));
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
      ("queryType", match s.Summary.query_type with Some t -> `String t | None -> `Null);
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

(* Expect at most one record in the result stream: more than one yields the
   first record with a warning. *)
let result_single_optional fields =
  let r = get_result (int "resultId" fields) in
  let record, warnings =
    match Neo4jResult.single_optional r.res with
    | Error error -> raise (Driver_error error)
    | Ok (None, warnings) -> (`Null, warnings)
    | Ok (Some record, warnings) -> (record_json record, warnings)
  in
  ( "RecordOptional",
    `Assoc [ ("record", record); ("warnings", `List (List.map (fun w -> `String w) warnings)) ] )

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
  | "NewAuthTokenManager" -> Some (new_auth_token_manager ctx fields)
  | "NewBasicAuthTokenManager" -> Some (new_basic_auth_token_manager ctx fields)
  | "NewBearerAuthTokenManager" -> Some (new_bearer_auth_token_manager ctx fields)
  | "AuthTokenManagerClose" -> Some (auth_token_manager_close fields)
  | "CheckSessionAuthSupport" -> Some (check_session_auth_support fields)
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
