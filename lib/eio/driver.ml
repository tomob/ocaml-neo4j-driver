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

(* The routing cluster for a [neo4j://] URI: its address is the initial router
   and routing tables are fetched from it on demand. *)
let make_cluster ~(parsed : Addressing.uri) ~pool_config ~connection_timeout ~user_agent ~auth net
    clock sw =
  let initial = Addressing.of_host_port parsed.host parsed.port in
  let connect addr =
    let config =
      Conn.
        {
          host = Addressing.host addr;
          port = Addressing.port addr;
          scheme = parsed.scheme;
          connection_timeout;
          user_agent;
          auth;
        }
    in
    Conn.connect net clock sw config
  in
  let cluster =
    Cluster.create ~pool_config ~connect ~routing_context:parsed.routing_context ~initial clock
  in
  Ok (Cluster cluster)

(* The connection pool for a direct [bolt://] URI. *)
let make_pool ?resolver ~(parsed : Addressing.uri) ~pool_config ~connection_timeout ~user_agent
    ~auth net clock sw =
  let conn_config =
    Conn.
      {
        host = parsed.host;
        port = parsed.port;
        scheme = parsed.scheme;
        connection_timeout;
        user_agent;
        auth;
      }
  in
  let connect () = Conn.connect ?resolver net clock sw conn_config in
  let pool = Pool.create ~pool_config ~connect clock in
  Ok (Pool pool)

let connect ?resolver ~uri ~auth ?user_agent ?connection_timeout
    ?(pool_config = Config.default_pool_config) net clock sw =
  let* parsed = Addressing.parse_uri uri in
  let connection_timeout = Option.value ~default:default_connection_timeout connection_timeout in
  let user_agent = Option.value ~default:Conn.default_user_agent user_agent in
  let* connection =
    match parsed.scheme with
    | Addressing.Neo4j | Addressing.Neo4j_secure | Addressing.Neo4j_self_signed ->
        make_cluster ~parsed ~pool_config ~connection_timeout ~user_agent ~auth net clock sw
    | _ ->
        make_pool ?resolver ~parsed ~pool_config ~connection_timeout ~user_agent ~auth net clock sw
  in
  Ok { clock; connection }

let session ?config t =
  let config = match config with Some config -> config | None -> Session.default_config in
  let connect ~mode ~database =
    match t.connection with
    | Cluster cluster -> Cluster.acquire cluster ~mode ~database
    | Pool pool -> Pool.acquire pool
  in
  let release conn =
    match t.connection with
    | Cluster cluster -> Cluster.release cluster conn
    | Pool pool -> Pool.release pool conn
  in
  Session.create config ~clock:t.clock ~connect ~release ()

(* A connection for driver-level operations (e.g. verify connectivity); return
   it with [release]. *)
let acquire t =
  match t.connection with
  | Cluster cluster -> Cluster.acquire cluster ~mode:Config.Write ~database:None
  | Pool pool -> Pool.acquire pool

let release t conn =
  match t.connection with
  | Cluster cluster -> Cluster.release cluster conn
  | Pool pool -> Pool.release pool conn

let close t =
  match t.connection with Cluster cluster -> Cluster.close cluster | Pool pool -> Pool.close pool
