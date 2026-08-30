(* Error taxonomy for the Neo4j driver.

   Modelled on the Neo4j Python driver's exceptions.py. Errors are the anchor
   for the retry / deactivation / re-authentication logic:

   - [Neo4j] (server-reported) errors carry a neo4j code, message,
     classification and retryability.
   - The remaining constructors cover client-side driver failure modes
     (connection, session, transaction, result, configuration, pool).

   In later phases the driver-error constructors will carry references to the
   offending session / transaction / result objects. *)

type classification = Client | Database | Transient | Unknown

type server_error = {
  code : string;
  message : string;
  classification : classification;
  retryable : bool;
  gql_status : string option;
}

(* Well-known server errors, recognised by their neo4j code. *)
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
  (* Server (Neo4j) errors. *)
  | Neo4j of server_error
  (* Driver errors. *)
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

type failures = { last : t; all : t list }
(** All errors from a failed multi-address connection attempt: [last] is the most recent failure and
    [all] lists every failure in order of occurrence. The OCaml analogue of the Python driver's
    exception aggregation when no resolved address can be connected. *)

let is_retryable = function
  | Neo4j server -> server.retryable
  | Session_expired _ | Service_unavailable _ | Routing_service_unavailable _
  | Write_service_unavailable _ | Read_service_unavailable _ ->
      true
  | Incomplete_commit _ | Session_error _ | Transaction_error _ | Transaction_nesting_error _
  | Result_failed_error _ | Result_consumed_error _ | Result_not_single_error _
  | Broken_record_error _ | Configuration_error _ | Auth_configuration_error _
  | Certificate_configuration_error _ | Unsupported_server_product _ | Connection_pool_error _
  | Connection_acquisition_timeout _ ->
      false

let unknown_code = "Neo.DatabaseError.General.UnknownError"

let classification_to_string = function
  | Client -> "ClientError"
  | Database -> "DatabaseError"
  | Transient -> "TransientError"
  | Unknown -> "UnknownError"

let specific_to_string = function
  | Constraint -> "Constraint"
  | Cypher_syntax -> "CypherSyntax"
  | Cypher_type -> "CypherType"
  | Forbidden -> "Forbidden"
  | Forbidden_on_read_only_database -> "ForbiddenOnReadOnlyDatabase"
  | Auth -> "Auth"
  | Token_expired -> "TokenExpired"
  | Not_a_leader -> "NotALeader"
  | Database_unavailable -> "DatabaseUnavailable"
  | Other -> "Other"

(* Classification derived from the neo4j code structure:
   "Neo.<Classification>.<Category>.<Title>". Codes that do not follow this
   shape fall back to [Database]; codes with an unrecognised classification
   component map to [Unknown]. *)
let classification_of_code code =
  match String.split_on_char '.' code with
  | [ _; "ClientError"; _; _ ] -> Client
  | [ _; "TransientError"; _; _ ] -> Transient
  | [ _; "DatabaseError"; _; _ ] -> Database
  | [ _; _; _; _ ] -> Unknown
  | _ -> Database

(* Backwards-compatibility re-classification of errors whose meaning changed
   across server versions (mirrors _ERROR_REWRITE_MAP). *)
let rewrite code classification =
  match code with
  | "Neo.ClientError.Security.AuthorizationExpired" -> (Transient, code)
  | "Neo.ClientError.Cluster.NotALeader" -> (Transient, code)
  | "Neo.TransientError.Transaction.Terminated" -> (Client, "Neo.ClientError.Transaction.Terminated")
  | "Neo.TransientError.Transaction.LockClientStopped" ->
      (Client, "Neo.ClientError.Transaction.LockClientStopped")
  | _ -> (classification, code)

let specific_of_code = function
  | "Neo.ClientError.Schema.ConstraintValidationFailed"
  | "Neo.ClientError.Schema.ConstraintViolation"
  | "Neo.ClientError.Statement.ConstraintVerificationFailed"
  | "Neo.ClientError.Statement.ConstraintViolation" ->
      Constraint
  | "Neo.ClientError.Statement.InvalidSyntax" | "Neo.ClientError.Statement.SyntaxError" ->
      Cypher_syntax
  | "Neo.ClientError.Procedure.TypeError" | "Neo.ClientError.Statement.InvalidType"
  | "Neo.ClientError.Statement.TypeError" ->
      Cypher_type
  | "Neo.ClientError.General.ForbiddenOnReadOnlyDatabase" -> Forbidden_on_read_only_database
  | "Neo.ClientError.General.ReadOnly" | "Neo.ClientError.Schema.ForbiddenOnConstraintIndex"
  | "Neo.ClientError.Schema.IndexBelongsToConstraint" | "Neo.ClientError.Security.Forbidden"
  | "Neo.ClientError.Transaction.ForbiddenDueToTransactionType" ->
      Forbidden
  | "Neo.ClientError.Security.AuthorizationFailed" | "Neo.ClientError.Security.Unauthorized" -> Auth
  | "Neo.ClientError.Security.TokenExpired" -> Token_expired
  | "Neo.ClientError.Cluster.NotALeader" -> Not_a_leader
  | "Neo.TransientError.General.DatabaseUnavailable" -> Database_unavailable
  | _ -> Other

(* Build a [Neo4j] error from a server-provided code, message and GQL status. *)
let of_neo4j_code_with_gql_status ~gql_status ~code ~message =
  let code = if code = "" then unknown_code else code in
  let classification = classification_of_code code in
  let classification, code = rewrite code classification in
  let retryable = classification = Transient in
  Neo4j { code; message; classification; retryable; gql_status }

let of_neo4j_code ~code ~message = of_neo4j_code_with_gql_status ~gql_status:None ~code ~message
let code = function Neo4j server -> Some server.code | _ -> None

let message = function
  | Neo4j server -> server.message
  | Session_expired m
  | Service_unavailable m
  | Routing_service_unavailable m
  | Write_service_unavailable m
  | Read_service_unavailable m
  | Incomplete_commit m
  | Session_error m
  | Transaction_error m
  | Transaction_nesting_error m
  | Result_failed_error m
  | Result_consumed_error m
  | Result_not_single_error m
  | Broken_record_error m
  | Configuration_error m
  | Auth_configuration_error m
  | Certificate_configuration_error m
  | Unsupported_server_product m
  | Connection_pool_error m
  | Connection_acquisition_timeout m ->
      m

let classification = function Neo4j server -> Some server.classification | _ -> None
let specific = function Neo4j server -> specific_of_code server.code | _ -> Other

let unauthenticates_all_connections = function
  | Neo4j { code; _ } -> code = "Neo.ClientError.Security.AuthorizationExpired"
  | _ -> false

let has_security_code = function
  | Neo4j { code; _ } -> String.starts_with ~prefix:"Neo.ClientError.Security." code
  | _ -> false

let is_fatal_during_discovery = function
  | Neo4j { code; _ } -> (
      match code with
      | "Neo.ClientError.Database.DatabaseNotFound" | "Neo.ClientError.Transaction.InvalidBookmark"
      | "Neo.ClientError.Transaction.InvalidBookmarkMixture" | "Neo.ClientError.Statement.TypeError"
      | "Neo.ClientError.Statement.ArgumentError" | "Neo.ClientError.Request.Invalid" ->
          true
      | _ ->
          String.starts_with ~prefix:"Neo.ClientError.Security." code
          && code <> "Neo.ClientError.Security.AuthorizationExpired")
  | _ -> false

let to_string = function
  | Neo4j server -> Printf.sprintf "{neo4j_code: %s} {message: %s}" server.code server.message
  | error -> message error
