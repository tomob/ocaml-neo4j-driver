(* Error taxonomy for the Neo4j driver.

   See errors.ml for the implementation. *)

type classification = Client | Database | Transient | Unknown

type server_error = {
  code : string;
  message : string;
  classification : classification;
  retryable : bool;
}

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
  | Other

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
  | Connection_acquisition_timeout of string

val is_retryable : t -> bool
val of_neo4j_code : code:string -> message:string -> t
val code : t -> string option
val message : t -> string
val classification : t -> classification option
val specific : t -> specific
val unauthenticates_all_connections : t -> bool
val has_security_code : t -> bool
val is_fatal_during_discovery : t -> bool
val to_string : t -> string
val classification_to_string : classification -> string
val specific_to_string : specific -> string
