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

type pool_config = {
  max_connection_lifetime : float;
  liveness_check_timeout : float option;
  max_connection_pool_size : int;
  connection_acquisition_timeout : float;
  connection_timeout : float;
  connection_write_timeout : float;
  keep_alive : bool;
  telemetry_disabled : bool;
  home_db_cache_ttl : float;
}
(** Connection pool settings. [home_db_cache_ttl] is how long a routed driver remembers a resolved
    home database (default [0.0], i.e. the cache is off); after it elapses the next default-database
    session re-fetches it over ROUTE. *)

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
  ?telemetry_disabled:bool ->
  ?home_db_cache_ttl:float ->
  unit ->
  (pool_config, Errors.t) result
(** Build a [pool_config] from the given overrides (defaults from {!default_pool_config}),
    validating the numeric settings.
    @return [Error (Errors.Configuration_error _)] on out-of-range values. *)
