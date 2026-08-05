(* Configuration records for the Neo4j driver.

   See config.ml for the implementation. *)

type access_mode = Read | Write

type workspace_config = {
  connection_acquisition_timeout : float;
  max_transaction_retry_time : float;
  initial_retry_delay : float;
  retry_delay_multiplier : float;
  retry_delay_jitter_factor : float;
  fetch_size : int;
  database : string option;
  impersonated_user : string option;
  disable_auto_commit_retries : bool;
}

type pool_config = {
  max_connection_lifetime : float;
  liveness_check_timeout : float option;
  max_connection_pool_size : int;
  connection_timeout : float;
  connection_write_timeout : float;
  keep_alive : bool;
  telemetry_disabled : bool;
}

val default_access_mode : access_mode
val default_workspace_config : workspace_config
val default_pool_config : pool_config

val make_workspace_config :
  ?connection_acquisition_timeout:float ->
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

val make_pool_config :
  ?max_connection_lifetime:float ->
  ?liveness_check_timeout:float option ->
  ?max_connection_pool_size:int ->
  ?connection_timeout:float ->
  ?connection_write_timeout:float ->
  ?keep_alive:bool ->
  ?telemetry_disabled:bool ->
  unit ->
  (pool_config, Errors.t) result
