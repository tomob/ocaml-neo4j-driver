(** Configuration records for the Neo4j driver.

    See config.ml for the implementation. *)

type access_mode = Read | Write  (** Access mode for a session: [Read] or [Write]. *)

type workspace_config = {
  max_transaction_retry_time : float;
  initial_retry_delay : float;
  retry_delay_multiplier : float;
  retry_delay_jitter_factor : float;
  fetch_size : int;
  database : string option;
  impersonated_user : string option;
  disable_auto_commit_retries : bool;
}
(** Session workspace settings: retry policy, fetch size and database selection. *)

(** The explicit encryption setting (the deprecated alternative to the URI schemes). *)
type encryption =
  | Default
      (** The URI scheme decides: plain for [bolt]/[neo4j], TLS for the [+s]/[+ssc] variants. *)
  | Enabled  (** Force TLS (only valid with a plain scheme, otherwise a [Configuration_error]). *)
  | Disabled  (** Force no TLS. *)

(** The explicit [trusted_certificates] configuration (the deprecated alternative to the URI
    schemes). [Custom] holds file paths; they are loaded when the driver is connected. *)
type trusted_certificates = System | Trust_all | Custom of string list

type pool_config = {
  max_connection_lifetime : float;
  liveness_check_timeout : float option;
  max_connection_pool_size : int;
  connection_acquisition_timeout : float;
  connection_timeout : float;
  connection_write_timeout : float;
  keep_alive : bool;
  encryption : encryption;
  trusted_certificates : trusted_certificates option;
  telemetry_disabled : bool;
  notifications_min_severity : string option;
  notifications_disabled_categories : string list option;
  home_db_cache_ttl : float;
}
(** Connection pool settings. [encryption] overrides the URI scheme's TLS choice ([Default] keeps
    the scheme default: off for [bolt]/[neo4j], on for the [+s]/[+ssc] variants);
    [trusted_certificates] overrides which certificates are trusted. The two are the deprecated
    explicit security config, only allowed with a plain scheme; conflicting values (explicit config
    with a secure scheme, or trust anchors without encryption) are rejected when the driver is
    connected. [home_db_cache_ttl] is how long a routed driver remembers a resolved home database
    (default [Float.infinity], i.e. the cache is on — a default-database session guesses the cached
    home database only when a server-side-routing capable connection has been seen); a TTL <= [0.0]
    disables the cache and every default-database session re-fetches the home database over ROUTE.
    [notifications_min_severity] and [notifications_disabled_categories] are the driver-level
    notification filtering settings sent in HELLO (Bolt >= 5.2; [None] omits the field, [Some []]
    sends an empty category list). *)

val default_access_mode : access_mode
(** Default access mode ([Write]). *)

val default_workspace_config : workspace_config
(** Default workspace configuration. *)

val default_pool_config : pool_config
(** Default pool configuration. *)

val make_workspace_config :
  ?max_transaction_retry_time:float ->
  ?initial_retry_delay:float ->
  ?retry_delay_multiplier:float ->
  ?retry_delay_jitter_factor:float ->
  ?fetch_size:int ->
  ?database:string option ->
  ?impersonated_user:string option ->
  ?disable_auto_commit_retries:bool ->
  unit ->
  (workspace_config, Errors.t) result
(** Build a [workspace_config] from the given overrides (defaults from {!default_workspace_config}),
    validating the numeric settings.
    @return [Error (Errors.Configuration_error _)] on out-of-range values. *)

val make_pool_config :
  ?max_connection_lifetime:float ->
  ?liveness_check_timeout:float option ->
  ?max_connection_pool_size:int ->
  ?connection_acquisition_timeout:float ->
  ?connection_timeout:float ->
  ?connection_write_timeout:float ->
  ?keep_alive:bool ->
  ?encryption:encryption ->
  ?trusted_certificates:trusted_certificates option ->
  ?telemetry_disabled:bool ->
  ?notifications_min_severity:string option ->
  ?notifications_disabled_categories:string list option ->
  ?home_db_cache_ttl:float ->
  unit ->
  (pool_config, Errors.t) result
(** Build a [pool_config] from the given overrides (defaults from {!default_pool_config}),
    validating the numeric settings.
    @return [Error (Errors.Configuration_error _)] on out-of-range values. *)
