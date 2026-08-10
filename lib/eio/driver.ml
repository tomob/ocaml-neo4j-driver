(* User-facing entry point of the Eio backend: parse a driver URI, build the
   connection and pool configuration and wire the Eio resources into a
   pool-backed driver. Sessions borrow a connection from the pool on first use
   and return it (RESET) on close.

   Routing ([neo4j://] schemes) is rejected by [Conn.connect] on first use until
   routing is implemented. *)

open Neodriver_core

let ( let* ) = Result.bind
let default_connection_timeout = 30.0

type t = { pool : Pool.t; clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t }

let connect ?resolver ~uri ~auth ?user_agent ?connection_timeout
    ?(pool_config = Config.default_pool_config) net clock sw =
  let* parsed = Addressing.parse_uri uri in
  let conn_config =
    Conn.
      {
        host = parsed.host;
        port = parsed.port;
        scheme = parsed.scheme;
        connection_timeout = Option.value ~default:default_connection_timeout connection_timeout;
        user_agent = Option.value ~default:Conn.default_user_agent user_agent;
        auth;
      }
  in
  let connect () = Conn.connect ?resolver net clock sw conn_config in
  let pool = Pool.create ~pool_config ~connect clock in
  Ok { pool; clock }

let session ?config t =
  let config = match config with Some config -> config | None -> Session.default_config in
  let connect () = Pool.acquire t.pool in
  let release conn = Pool.release t.pool conn in
  Session.create config ~clock:t.clock ~connect ~release ()

(* A connection for driver-level operations (e.g. verify connectivity); return
   it with [release]. *)
let acquire t = Pool.acquire t.pool
let release t conn = Pool.release t.pool conn
let close t = Pool.close t.pool
