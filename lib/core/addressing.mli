(** Server addresses and URI parsing for the Neo4j driver.

    See addressing.ml for the implementation. *)

type t =
  | IPv4 of string * int
  | IPv6 of string * int * int * int
      (** An address: [IPv4 (host, port)] or [IPv6 (host, port, flowinfo, scope_id)]. *)

type resolved = { address : t; unresolved_host : string }
(** A resolved address carrying the original (unresolved) host name, used for TLS SNI and pool
    deactivation. *)

type scheme =
  | Bolt
  | Bolt_secure
  | Bolt_self_signed
  | Neo4j
  | Neo4j_secure
  | Neo4j_self_signed  (** URI schemes: [bolt://], [neo4j://] and their [+s] / [+ssc] variants. *)

type uri = { scheme : scheme; host : string; port : int; routing_context : (string * string) list }
(** A parsed driver URI. *)

val default_host : string
(** Default host used when parsing addresses. *)

val default_port : int
(** Default port used when parsing addresses. *)

val default_routing_targets : string list
(** Default routing targets for a cluster URI. *)

val host : t -> string
(** The host part of an address. *)

val port : t -> int
(** The port part of an address. *)

val of_host_port : string -> int -> t
(** An address from a host and port. A host containing [':'] (an IPv6 literal without brackets, as
    carried by a parsed URI) becomes an [IPv6] address. *)

val to_string : t -> string
(** Render an address as "host:port" (IPv6 host in brackets). *)

val connect_failure_message :
  address:t -> resolved:string list -> failures:Errors.failures -> string
(** Render the message for a connection attempt that failed on every resolved address, mirroring the
    Python driver ("Couldn't connect to <address> (resolved to <addrs>):\n<errors>"). [resolved] are
    the rendered addresses that failed and [failures] aggregates the individual errors. *)

val parse : ?default_host:string -> ?default_port:int -> string -> (t, Errors.t) result
(** Parse a "host:port" or "[host]:port" string, applying the given defaults to empty host/port
    parts. *)

val parse_list :
  ?default_host:string -> ?default_port:int -> string list -> (t list, Errors.t) result
(** Parse a whitespace-separated list of targets into addresses. *)

val make_resolved : t -> string -> resolved
(** Build a [resolved] address with the given unresolved host name. *)

val resolved_host_name : resolved -> string
(** The host name to use for TLS SNI / hostname verification. *)

val unresolved : resolved -> t
(** Rebuild the address using the unresolved host name (used for pool deactivation). *)

val scheme_to_string : scheme -> string
(** Render a scheme as its URI string (e.g. "bolt+ssc"). *)

val parse_routing_context : string -> ((string * string) list, Errors.t) result
(** Parse the query part of a URI into a routing context, decoding percent escapes. Empty values and
    duplicate keys are rejected. *)

val parse_uri : string -> (uri, Errors.t) result
(** Parse a driver URI ([bolt://], [neo4j://] and their [+s] / [+ssc] variants). Usernames/passwords
    are not supported. *)
