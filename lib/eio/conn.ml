(* Minimal Bolt connection: TCP connect (+ optional TLS) + handshake.

   A [t] represents an established Bolt connection (transport + agreed
   protocol version). HELLO, authentication and queries belong to later
   phases. Routing (neo4j:// schemes) is not implemented yet. *)

open Neodriver_core

let ( let* ) = Result.bind

type config = { host : string; port : int; scheme : Addressing.scheme; connection_timeout : float }
type t = { transport : Transport.t; major : int; minor : int }

let tls_of_scheme host = function
  | Addressing.Bolt -> Ok Transport.Plain
  | Addressing.Bolt_secure -> Ok (Transport.Verify host)
  | Addressing.Bolt_self_signed -> Ok (Transport.Trust_all host)
  | Addressing.Neo4j | Addressing.Neo4j_secure | Addressing.Neo4j_self_signed ->
      Error (Errors.Service_unavailable "Routing (neo4j://) is not supported yet")

let connect net clock sw config =
  let* tls = tls_of_scheme config.host config.scheme in
  let* address =
    Addressing.parse ~default_host:"localhost" ~default_port:7687
      (Printf.sprintf "%s:%d" config.host config.port)
  in
  let* transport = Transport.connect net clock sw ~timeout:config.connection_timeout ~tls address in
  let* major, minor = Handshake.negotiate transport in
  Ok { transport; major; minor }

let close t = Transport.close t.transport
