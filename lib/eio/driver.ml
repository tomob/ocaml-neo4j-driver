(* User-facing entry point of the Eio backend: parse a driver URI, build the
   connection/pool (or routing cluster) configuration and wire the Eio
   resources into a pool-backed driver. Sessions borrow a connection from the
   pool (or the routing cluster) on first use and return it (RESET) on close.

   [bolt://] drivers use a single connection pool for the URI's address;
   [neo4j://] drivers use a routing cluster (minimal routing — see
   cluster.ml). *)

open Neodriver_core

let ( let* ) = Result.bind
let default_connection_timeout = 30.0

(* How the driver provides connections: a routing cluster for [neo4j://] URIs,
   or a single-address pool for [bolt://] and its TLS variants. *)
type cluster_or_pool = Cluster of Cluster.t | Pool of Pool.t
type t = { clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t; connection : cluster_or_pool }

(* The target connection configuration for a single address. *)
let conn_config ~(parsed : Addressing.uri) ~(pool_config : Config.pool_config) ~connection_timeout
    ~user_agent ~auth ~routing_context addr =
  Conn.
    {
      host = Addressing.host addr;
      port = Addressing.port addr;
      scheme = parsed.scheme;
      connection_timeout;
      user_agent;
      auth;
      routing_context;
      telemetry_disabled = pool_config.telemetry_disabled;
    }

(* The routing cluster for a [neo4j://] URI: its address is the initial router
   and routing tables are fetched from it on demand. Data and routing
   connections open with a session auth token when one is provided, otherwise
   with the manager's current token; the manager is also passed to the
   per-address data pools for re-authentication and security-error handling. *)
let make_cluster ?resolver ?domain_name_resolver ~(parsed : Addressing.uri)
    ~(pool_config : Config.pool_config) ~connection_timeout ~user_agent
    ~(auth_manager : Auth_manager.t) net clock sw =
  let initial = Addressing.of_host_port parsed.host parsed.port in
  (* The routing context carries the cluster's own address (like the Python
     driver, which prepends "address" at pool creation): the server uses it for
     routing policies and it is echoed back on ROUTE. *)
  let routing_context = ("address", Addressing.to_string initial) :: parsed.routing_context in
  (* The address resolver is applied by the cluster's fetch (fetch_routers),
     which turns each seed into concrete addresses; the routing connection only
     resolves hostnames among those via the domain-name resolver. Data-pool
     connections (readers/writers) do resolve addresses, since a routing table
     may list addresses a custom resolver maps to real servers. *)
  let config auth addr =
    conn_config ~parsed ~pool_config ~connection_timeout ~user_agent ~auth
      ~routing_context:(Some routing_context) addr
  in
  let with_token ~session_auth connect addr =
    let* auth =
      match session_auth with Some token -> Ok token | None -> auth_manager.get_auth ()
    in
    connect (config auth addr)
  in
  let connect_routing ~session_auth addr =
    with_token ~session_auth (Conn.connect ?domain_name_resolver net clock sw) addr
  in
  let connect ~session_auth addr =
    with_token ~session_auth (Conn.connect ?resolver ?domain_name_resolver net clock sw) addr
  in
  let cluster =
    Cluster.create ?resolver ~pool_config ~connect ~connect_routing ~routing_context ~initial
      ~auth_manager:(Some auth_manager) clock
  in
  Ok (Cluster cluster)

(* The connection pool for a direct [bolt://] URI. New connections open with a
   session auth token when one is provided, otherwise with the manager's
   current token, so a rotated (or switched) token is used by freshly created
   connections without a LOGOFF+LOGON. *)
let make_pool ?resolver ?domain_name_resolver ~(parsed : Addressing.uri)
    ~(pool_config : Config.pool_config) ~connection_timeout ~user_agent
    ~(auth_manager : Auth_manager.t) net clock sw =
  let connect session_auth =
    let* auth =
      match session_auth with Some token -> Ok token | None -> auth_manager.get_auth ()
    in
    let config =
      conn_config ~parsed ~pool_config ~connection_timeout ~user_agent ~auth ~routing_context:None
        (Addressing.of_host_port parsed.host parsed.port)
    in
    Conn.connect ?resolver ?domain_name_resolver net clock sw config
  in
  let pool = Pool.create ~pool_config ~connect ~auth_manager:(Some auth_manager) clock in
  Ok (Pool pool)

let connect ?resolver ?domain_name_resolver ~uri ~auth ?auth_manager ?user_agent ?connection_timeout
    ?(pool_config = Config.default_pool_config) net clock sw =
  let* parsed = Addressing.parse_uri uri in
  let connection_timeout = Option.value ~default:default_connection_timeout connection_timeout in
  let user_agent = Option.value ~default:Conn.default_user_agent user_agent in
  (* A plain token is wrapped in a static auth manager, like the Python driver
     ([auth_manager] lets a TestKit backend supply a rotating one). *)
  let auth_manager = Option.value ~default:(Auth_manager.static auth) auth_manager in
  let* connection =
    match parsed.scheme with
    | Addressing.Neo4j | Addressing.Neo4j_secure | Addressing.Neo4j_self_signed ->
        make_cluster ?resolver ?domain_name_resolver ~parsed ~pool_config ~connection_timeout
          ~user_agent ~auth_manager net clock sw
    | _ ->
        make_pool ?resolver ?domain_name_resolver ~parsed ~pool_config ~connection_timeout
          ~user_agent ~auth_manager net clock sw
  in
  Ok { clock; connection }

let session ?config t =
  let config = Option.value ~default:Session.default_config config in
  let connect ~mode ~database ~bookmarks ~auth =
    match t.connection with
    | Cluster cluster ->
        Cluster.acquire cluster ~mode ~database ~imp_user:config.impersonated_user ~bookmarks
          ~session_auth:auth ~force_liveness:false
    | Pool pool ->
        Result.map
          (fun conn -> (conn, database))
          (Pool.acquire ~session_auth:auth ~force_liveness:false pool)
  in
  let release conn =
    match t.connection with
    | Cluster cluster -> Cluster.release cluster conn
    | Pool pool -> Pool.release pool conn
  in
  let on_rt =
    match t.connection with
    | Cluster cluster ->
        fun database rt ->
          Cluster.update_table cluster ~database ~imp_user:config.impersonated_user rt
    | Pool _ -> fun _ _ -> ()
  in
  Session.create config ~clock:t.clock ~connect ~release ~on_rt ()

(* A connection for driver-level operations (e.g. verify connectivity); return
   it with [release]. [mode] selects the connection role for routed drivers
   (default [Write]; [Read] for read-only checks). *)
let acquire ?(mode = Config.Write) t =
  match t.connection with
  | Cluster cluster ->
      Result.map fst
        (Cluster.acquire cluster ~mode ~database:None ~imp_user:None ~bookmarks:[]
           ~session_auth:None ~force_liveness:true)
  | Pool pool -> Pool.acquire ~session_auth:None ~force_liveness:true pool

let release t conn =
  match t.connection with
  | Cluster cluster -> Cluster.release cluster conn
  | Pool pool -> Pool.release pool conn

(* Whether the server the driver connects to supports re-authentication (Bolt
   >= 5.1), i.e. session-level auth (user switching): connect and check the
   negotiated protocol. Test-support API for the TestKit CheckSessionAuthSupport. *)
let supports_session_auth t =
  let* conn = acquire t in
  let supported = (Conn.capabilities conn).supports_re_auth in
  release t conn;
  Ok supported

(* Authentication errors meaning the supplied token is simply not valid: the
   Python driver's verify_authentication returns [false] for them (and raises
   for any other error). *)
let invalid_auth_codes =
  [
    "Neo.ClientError.Security.CredentialsExpired";
    "Neo.ClientError.Security.Forbidden";
    "Neo.ClientError.Security.TokenExpired";
    "Neo.ClientError.Security.Unauthorized";
  ]

(* Verify [auth] like the Python driver: open (or force re-authenticate) a read
   connection for the [system] database with [auth] and check it is accepted.
   Requires a server that supports re-authentication (Bolt >= 5.1). *)
let verify_authentication t ~auth =
  let attempt =
    match t.connection with
    | Cluster cluster ->
        Result.map fst
          (Cluster.acquire ~force_auth:true cluster ~mode:Config.Read ~database:(Some "system")
             ~imp_user:None ~bookmarks:[] ~session_auth:(Some auth) ~force_liveness:false)
    | Pool pool ->
        Pool.acquire ~force_auth:true ~session_auth:(Some auth) ~force_liveness:false pool
  in
  match attempt with
  | Error (Errors.Neo4j { code; _ }) when List.mem code invalid_auth_codes -> Ok false
  | Error error -> Error error
  | Ok conn ->
      let supported = (Conn.capabilities conn).supports_re_auth in
      release t conn;
      if not supported then
        Error
          (Errors.Configuration_error "Re-authentication is not supported by this protocol version")
      else Ok true

let close t =
  match t.connection with Cluster cluster -> Cluster.close cluster | Pool pool -> Pool.close pool

(* Test-support API for the TestKit backend. *)
let get_routing_table t ~database =
  match t.connection with
  | Cluster cluster -> Cluster.routing_table_of cluster ~database
  | Pool _ -> None

let force_routing_table_update t ~database ~bookmarks =
  match t.connection with
  | Cluster cluster -> Cluster.force_routing_table_update cluster ~database ~bookmarks
  | Pool _ -> Error (Errors.Service_unavailable "routing requires a neo4j:// URI")
