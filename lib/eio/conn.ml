(* Minimal Bolt connection: TCP connect (+ optional TLS) + handshake + HELLO/auth.

   A [t] represents an established, authenticated Bolt connection (transport +
   agreed protocol version). Authentication is sent inline in HELLO for Bolt
   <= 5.0, or via a separate LOGON message for Bolt >= 5.1. Routing
   (neo4j:// schemes) is not implemented yet. *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

type auth = { scheme : string; principal : string; credentials : string }

type config = {
  host : string;
  port : int;
  scheme : Addressing.scheme;
  connection_timeout : float;
  user_agent : string;
  auth : auth;
}

type t = { transport : Transport.t; major : int; minor : int }

let default_user_agent = "ocaml-neo4j-driver/0.1.0"

(* LOGON/LOGOFF are available from Bolt 5.1 (the Python driver's
   supports_re_auth gate). *)
let supports_re_auth major minor = major > 5 || (major = 5 && minor >= 1)

(* The bolt_agent header is sent from Bolt 5.3. *)
let bolt_agent_version major minor = major > 5 || (major = 5 && minor >= 3)

let tls_of_scheme host = function
  | Addressing.Bolt -> Ok Transport.Plain
  | Addressing.Bolt_secure -> Ok (Transport.Verify host)
  | Addressing.Bolt_self_signed -> Ok (Transport.Trust_all host)
  | Addressing.Neo4j | Addressing.Neo4j_secure | Addressing.Neo4j_self_signed ->
      Error (Errors.Service_unavailable "Routing (neo4j://) is not supported yet")

let bolt_agent user_agent =
  Packstream.Map
    [
      ("product", Packstream.String user_agent);
      ("platform", Packstream.String Sys.os_type);
      ("language", Packstream.String "OCaml");
      ("language_details", Packstream.String Sys.ocaml_version);
    ]

let auth_map (auth : auth) =
  Packstream.Map
    [
      ("scheme", Packstream.String auth.scheme);
      ("principal", Packstream.String auth.principal);
      ("credentials", Packstream.String auth.credentials);
    ]

let hello_headers (config : config) major minor =
  let headers = [ ("user_agent", Packstream.String config.user_agent) ] in
  let headers =
    if bolt_agent_version major minor then ("bolt_agent", bolt_agent config.user_agent) :: headers
    else headers
  in
  let headers =
    if supports_re_auth major minor then headers
    else
      headers
      @ [
          ("scheme", Packstream.String config.auth.scheme);
          ("principal", Packstream.String config.auth.principal);
          ("credentials", Packstream.String config.auth.credentials);
        ]
  in
  Packstream.Map headers

let connect net clock sw config =
  let* tls = tls_of_scheme config.host config.scheme in
  let* address =
    Addressing.parse ~default_host:"localhost" ~default_port:7687
      (Printf.sprintf "%s:%d" config.host config.port)
  in
  let timeout =
    if config.connection_timeout = infinity then Eio.Time.Timeout.none
    else Eio.Time.Timeout.seconds clock config.connection_timeout
  in
  let* transport = Transport.connect net sw ~timeout ~tls address in
  let* major, minor = Handshake.negotiate transport in
  let* _ = Bolt.hello transport ~headers:(hello_headers config major minor) in
  let* () =
    if supports_re_auth major minor then
      let* _ = Bolt.logon transport ~auth:(auth_map config.auth) in
      Ok ()
    else Ok ()
  in
  Ok { transport; major; minor }

let logon t auth =
  if not (supports_re_auth t.major t.minor) then
    Error (Errors.Service_unavailable "LOGON is not supported by this protocol version")
  else
    let* _ = Bolt.logon t.transport ~auth:(auth_map auth) in
    Ok ()

let logoff t =
  if not (supports_re_auth t.major t.minor) then
    Error (Errors.Service_unavailable "LOGOFF is not supported by this protocol version")
  else
    let* _ = Bolt.logoff t.transport in
    Ok ()

let close t = Transport.close t.transport
