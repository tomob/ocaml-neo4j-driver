(* Server addresses and URI parsing for the Neo4j driver.

   Modelled on the Neo4j Python driver's _addressing.py and _api.py. Addresses
   are normalised to integer ports at parse time. [resolved] carries the
   original (unresolved) host name so that TLS SNI and pool deactivation can
   use the user-supplied host even after DNS resolution. *)

let ( let* ) = Result.bind

type t = IPv4 of string * int | IPv6 of string * int * int * int
type resolved = { address : t; unresolved_host : string }
type scheme = Bolt | Bolt_secure | Bolt_self_signed | Neo4j | Neo4j_secure | Neo4j_self_signed
type uri = { scheme : scheme; host : string; port : int; routing_context : (string * string) list }

let default_host = "localhost"
let default_port = 7687
let default_routing_targets = [ ":"; ":17601"; ":17687" ]

let config_error fmt =
  Printf.ksprintf (fun message -> Error (Errors.Configuration_error message)) fmt

let host = function IPv4 (host, _) | IPv6 (host, _, _, _) -> host
let port = function IPv4 (_, port) | IPv6 (_, port, _, _) -> port

let to_string = function
  | IPv4 (host, port) -> Printf.sprintf "%s:%d" host port
  | IPv6 (host, port, _, _) -> Printf.sprintf "[%s]:%d" host port

let parse_port ~default_port port =
  if port = "" then Ok default_port
  else
    match int_of_string_opt port with
    | Some port when port >= 0 -> Ok port
    | _ -> config_error "Invalid port %S" port

let split_host_port s =
  match String.rindex_opt s ':' with
  | Some i ->
      let host = String.sub s 0 i in
      let port = String.sub s (i + 1) (String.length s - i - 1) in
      (host, port)
  | None -> (s, "")

let parse_ipv4 ?(default_host = default_host) ?(default_port = default_port) s =
  let raw_host, raw_port = split_host_port s in
  let host = if raw_host = "" then default_host else raw_host in
  let* port = parse_port ~default_port raw_port in
  Ok (IPv4 (host, port))

let parse_ipv6 ?(default_host = default_host) ?(default_port = default_port) s =
  let rest = String.sub s 1 (String.length s - 1) in
  match String.index_opt rest ']' with
  | None -> config_error "Invalid IPv6 address %S" s
  | Some close ->
      let host = String.sub rest 0 close in
      let after = String.trim (String.sub rest (close + 1) (String.length rest - close - 1)) in
      let host = if host = "" then default_host else host in
      let* port =
        if after = "" then Ok default_port
        else if String.starts_with ~prefix:":" after then
          parse_port ~default_port (String.sub after 1 (String.length after - 1))
        else config_error "Invalid IPv6 address %S" s
      in
      Ok (IPv6 (host, port, 0, 0))

(* Parse a "host:port" or "[host]:port" string into an address. Empty host and

   port parts fall back to the provided defaults. *)
let parse ?(default_host = default_host) ?(default_port = default_port) s =
  if String.starts_with ~prefix:"[" s then parse_ipv6 ~default_host ~default_port s
  else parse_ipv4 ~default_host ~default_port s

(* Parse a whitespace-separated list of targets into addresses. *)
let parse_list ?(default_host = default_host) ?(default_port = default_port) targets =
  let rec go = function
    | [] -> Ok []
    | target :: rest ->
        let* address = parse ~default_host ~default_port target in
        let* addresses = go rest in
        Ok (address :: addresses)
  in
  targets |> List.concat_map (String.split_on_char ' ') |> List.filter (fun s -> s <> "") |> go

let make_resolved address unresolved_host = { address; unresolved_host }

(* The host name to use for TLS SNI / hostname verification. *)
let resolved_host_name resolved = resolved.unresolved_host

(* Reconstruct the address using the unresolved host name, as used for pool
   deactivation and routing. *)
let unresolved resolved =
  match resolved.address with
  | IPv4 (_, port) -> IPv4 (resolved.unresolved_host, port)
  | IPv6 (_, port, _, _) -> IPv6 (resolved.unresolved_host, port, 0, 0)

(* Render a message for a connection attempt that failed on every resolved
   address, mirroring the Python driver's _bolt_socket.py. [resolved] are the
   rendered resolved addresses that failed and [failures] aggregates the
   individual errors. *)
let connect_failure_message ~address ~resolved ~(failures : Errors.failures) =
  let address_strs = String.concat ", " resolved in
  match failures.all with
  | [] -> Printf.sprintf "Couldn't connect to %s (resolved to %s)" (to_string address) address_strs
  | errors ->
      let error_strs = String.concat "\n" (List.map Errors.to_string errors) in
      Printf.sprintf "Couldn't connect to %s (resolved to %s):\n%s" (to_string address) address_strs
        error_strs

let scheme_to_string = function
  | Bolt -> "bolt"
  | Bolt_secure -> "bolt+s"
  | Bolt_self_signed -> "bolt+ssc"
  | Neo4j -> "neo4j"
  | Neo4j_secure -> "neo4j+s"
  | Neo4j_self_signed -> "neo4j+ssc"

let supported_schemes = [ "bolt"; "bolt+s"; "bolt+ssc"; "neo4j"; "neo4j+s"; "neo4j+ssc" ]

let scheme_of_string = function
  | "bolt" -> Some Bolt
  | "bolt+s" -> Some Bolt_secure
  | "bolt+ssc" -> Some Bolt_self_signed
  | "neo4j" -> Some Neo4j
  | "neo4j+s" -> Some Neo4j_secure
  | "neo4j+ssc" -> Some Neo4j_self_signed
  | _ -> None

(* Decode percent-encoded octets and '+' as space, as used in query strings.
   The percent-decoding is delegated to Uri.pct_decode; '+' is only special in
   the query component. *)
let url_decode s = Uri.pct_decode (String.map (fun c -> if c = '+' then ' ' else c) s)

(* Parse the query portion of a URI into a routing context. Values must be
   non-empty and keys must not be duplicated. *)
let parse_routing_context query =
  String.split_on_char '&' query
  |> List.fold_left
       (fun acc pair ->
         let* context = acc in
         match String.index_opt pair '=' with
         | None -> config_error "Invalid parameter %S in query string '%s'" pair query
         | Some i ->
             let key = String.sub pair 0 i in
             let value = String.sub pair (i + 1) (String.length pair - i - 1) in
             let key = url_decode key in
             let value = url_decode value in
             if value = "" then
               config_error "Invalid parameter '%s=%s' in query string '%s'" key value query
             else if List.mem_assoc key context then
               config_error "Duplicated query parameter '%s' in query string '%s'" key query
             else Ok ((key, value) :: context))
       (Ok [])
  |> Result.map List.rev

(* Parse a driver URI: "bolt://host[:port]", "neo4j://host[:port][?routing]"
   and their "+s" / "+ssc" variants. Usernames/passwords are not supported.
   The URI structure is parsed by Uri (RFC 3986); only the driver-specific
   policy (supported schemes, no userinfo, routing context) is verified here,
   mirroring the Python driver's parse_neo4j_uri. *)
let parse_uri uri_string =
  let parsed = Uri.of_string (String.trim uri_string) in
  let* scheme =
    match Uri.scheme parsed with
    | None -> config_error "URI %S is missing a scheme" uri_string
    | Some scheme_str -> (
        match scheme_of_string (String.lowercase_ascii scheme_str) with
        | Some scheme -> Ok scheme
        | None ->
            config_error "URI scheme %S is not supported. Supported URI schemes are %s" scheme_str
              (String.concat ", " supported_schemes))
  in
  let* () =
    match Uri.userinfo parsed with
    | None -> Ok ()
    | Some _ -> config_error "Username and password are not supported in the URI %S" uri_string
  in
  let host = match Uri.host parsed with Some h when h <> "" -> h | _ -> default_host in
  let port = match Uri.port parsed with Some p -> p | None -> default_port in
  let* routing_context =
    match Uri.verbatim_query parsed with
    | None | Some "" -> Ok []
    | Some query -> parse_routing_context query
  in
  Ok { scheme; host; port; routing_context }
