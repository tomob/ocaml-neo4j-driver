(* User-facing entry point of the Eio backend: parse a driver URI, build the
   connection and session configuration and wire the Eio resources into a
   ready (lazily connecting) session.

   There is no connection pool yet: a [Driver.connect] produces a single
   [Session.t] that owns its own (lazily established) connection. Routing
   ([neo4j://] schemes) is rejected by [Conn.connect] on first use until
   routing is implemented. *)

open Neodriver_core

let ( let* ) = Result.bind
let default_connection_timeout = 30.0

let connect ?resolver ~uri ~auth ?user_agent ?connection_timeout ?config net clock sw =
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
  let session_config = match config with Some config -> config | None -> Session.default_config in
  let connect () = Conn.connect ?resolver net clock sw conn_config in
  Ok (Session.create session_config ~clock ~connect)
