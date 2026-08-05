(* Server addresses and URI parsing for the Neo4j driver.

   See addressing.ml for the implementation. *)

type t = IPv4 of string * int | IPv6 of string * int * int * int
type resolved = { address : t; unresolved_host : string }

type scheme =
  | Bolt
  | Bolt_secure
  | Bolt_self_signed
  | Neo4j
  | Neo4j_secure
  | Neo4j_self_signed

type uri = {
  scheme : scheme;
  host : string;
  port : int;
  routing_context : (string * string) list;
}

val default_host : string
val default_port : int
val default_routing_targets : string list
val host : t -> string
val port : t -> int
val to_string : t -> string

val parse :
  ?default_host:string -> ?default_port:int -> string -> (t, Errors.t) result

val parse_list :
  ?default_host:string ->
  ?default_port:int ->
  string list ->
  (t list, Errors.t) result

val make_resolved : t -> string -> resolved
val resolved_host_name : resolved -> string
val unresolved : resolved -> t
val scheme_to_string : scheme -> string
val parse_routing_context : string -> ((string * string) list, Errors.t) result
val parse_uri : string -> (uri, Errors.t) result
