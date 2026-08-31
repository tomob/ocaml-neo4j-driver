(** Authentication tokens for the Neo4j driver.

    See auth_manager.ml for the implementation. *)

open Neodriver_packstream

type token = {
  scheme : string;
  principal : string option;
  credentials : string option;
  realm : string option;
  parameters : (string * Packstream.value) list;
}
(** An authentication token sent in HELLO (Bolt <= 5.0) or LOGON (Bolt >= 5.1). Absent fields are
    omitted on the wire: a [bearer] token sends only [scheme] and [credentials]; a custom token may
    add [realm] and [parameters]. *)

val basic_auth : ?principal:string -> ?credentials:string -> ?realm:string -> unit -> token
(** The basic authentication token ([scheme = "basic"]) with the given [principal] (default
    [neo4j]), [credentials] (default empty) and optional [realm]. *)

val bearer_auth : string -> token
(** A bearer (SSO) token: [scheme = "bearer"], only the token as [credentials]. *)

val custom_auth :
  ?principal:string ->
  ?credentials:string ->
  ?realm:string ->
  ?parameters:(string * Packstream.value) list ->
  string ->
  token
(** A custom authentication token for arbitrary schemes, with optional [principal] / [credentials] /
    [realm] and extra [parameters] sent as a map. *)

val eq : token -> token -> bool
(** Whether two tokens carry the same authentication information (parameters compared
    order-independently). *)

val to_map : token -> Packstream.value
(** Serialise a token for HELLO / LOGON, omitting absent fields. *)

type expiring_auth = { token : token; expires_at : float option }
(** Potentially expiring authentication information: [expires_at] is an absolute timestamp (seconds
    since the epoch); [None] means the token never expires in time. *)

val expires_in : now:float -> float -> expiring_auth -> expiring_auth
(** A (flat) copy of [auth] expiring [seconds] from [now]. *)

val has_expired : now:float -> expiring_auth -> bool
(** Whether [auth] has passed its expiry time ([None] never expires). *)

type t = {
  get_auth : unit -> (token, Errors.t) result;
  handle_security_exception : token -> Errors.t -> (bool, Errors.t) result;
}
(** An authentication manager. [get_auth] returns the current token (called frequently, so the
    manager caches it). [handle_security_exception] is called when the server returns a
    [Neo.ClientError.Security.*] error, with the token that was used when the server rejected it:
    [Ok true] means the error was handled (the driver then marks it retryable), [Ok false] leaves it
    untouched, and [Error _] propagates a failure of the token provider. *)

val static : token -> t
(** A manager that always returns the same token and never handles security exceptions (the OCaml
    analogue of the Python [AuthManagers.static]). *)

val basic : provider:(unit -> (token, Errors.t) result) -> t
(** A manager for basic-auth password rotation: the provider is called once and the token cached
    until the server rejects it with [Neo.ClientError.Security.Unauthorized], which triggers a
    refresh (the OCaml analogue of the Python [AuthManagers.basic]). *)

val bearer : now:(unit -> float) -> provider:(unit -> (expiring_auth, Errors.t) result) -> t
(** A manager for potentially expiring bearer tokens: the provider is called once and the token
    cached until either its [expires_at] passes ([now] supplies the current timestamp) or the server
    rejects it with [Neo.ClientError.Security.TokenExpired] / [Unauthorized] (the OCaml analogue of
    the Python [AuthManagers.bearer]). *)
