(** Error taxonomy for the Neo4j driver.

    See errors.ml for the implementation. *)

type classification =
  | Client
  | Database
  | Transient
  | Unknown  (** Classification of a server-reported error, derived from its code. *)

type server_error = {
  code : string;
  message : string;
  classification : classification;
  retryable : bool;
  gql_status : string option;
}
(** A server (Neo4j) error as reported over the wire. [gql_status] is the GQL status code from the
    FAILURE metadata (Bolt >= 5.2), when the server provides one. *)

type specific =
  | Constraint
  | Cypher_syntax
  | Cypher_type
  | Forbidden
  | Forbidden_on_read_only_database
  | Auth
  | Token_expired
  | Not_a_leader
  | Database_unavailable
  | Other  (** Well-known server errors, recognised by their neo4j code. *)

type t =
  | Neo4j of server_error
  | Session_expired of string
  | Service_unavailable of string
  | Routing_service_unavailable of string
  | Write_service_unavailable of string
  | Read_service_unavailable of string
  | Incomplete_commit of string
  | Session_error of string
  | Transaction_error of string
  | Transaction_nesting_error of string
  | Result_failed_error of string
  | Result_consumed_error of string
  | Result_not_single_error of string
  | Broken_record_error of string
  | Configuration_error of string
  | Auth_configuration_error of string
  | Certificate_configuration_error of string
  | Unsupported_server_product of string
  | Connection_pool_error of string
  | Connection_acquisition_timeout of string  (** Driver and server errors. *)

type failures = { last : t; all : t list }
(** All errors from a failed multi-address connection attempt: [last] is the most recent failure and
    [all] lists every failure in order of occurrence. The OCaml analogue of the Python driver's
    exception aggregation when no resolved address can be connected. *)

val is_retryable : t -> bool
(** Whether an error is safe to retry a transaction after. *)

val make_retryable : t -> t
(** [make_retryable error] returns [error] with its retryability forced to [true] (the OCaml
    analogue of the Python driver marking a Neo4j error retryable once an auth manager handled it);
    driver errors are returned unchanged. *)

val of_neo4j_code : code:string -> message:string -> t
(** Build a server error from a neo4j code and message, applying the classification and legacy
    re-write maps. *)

val of_neo4j_code_with_gql_status : gql_status:string option -> code:string -> message:string -> t
(** Like {!of_neo4j_code}, but also records the [gql_status] from the Bolt >= 5.2 FAILURE metadata.
*)

val code : t -> string option
(** The neo4j code of a server error, or [None] for driver errors. *)

val message : t -> string
(** The message of an error. *)

val classification : t -> classification option
(** The classification of a server error, or [None] for driver errors. *)

val specific : t -> specific
(** The well-known specific error kind, if any. *)

val unauthenticates_all_connections : t -> bool
(** Whether the error invalidates the authentication of all connections (AuthorizationExpired). *)

val has_security_code : t -> bool
(** Whether the error carries a [Neo.ClientError.Security.*] code. *)

val is_fatal_during_discovery : t -> bool
(** Whether the error should fail fast during routing discovery. *)

val to_string : t -> string
(** Render an error as a human-readable string. *)

val classification_to_string : classification -> string
(** Render a classification as its neo4j string ("ClientError", ...). *)

val specific_to_string : specific -> string
(** Render a specific error kind as a string. *)
