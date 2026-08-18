(* Configuration records for the Neo4j driver.

   Modelled on the Neo4j Python driver's config.py / _conf.py. Only
   transport-agnostic numeric and pool settings live here; TLS, auth,
   bookmarks and notification settings are added in later phases.

   The [make_*] constructors validate their inputs and return a
   [Errors.Configuration_error] for out-of-range values. *)

type access_mode = Read | Write

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

let default_access_mode = Write

let default_workspace_config =
  {
    max_transaction_retry_time = 30.0;
    initial_retry_delay = 1.0;
    retry_delay_multiplier = 2.0;
    retry_delay_jitter_factor = 0.2;
    fetch_size = 1000;
    database = None;
    impersonated_user = None;
    disable_auto_commit_retries = false;
  }

let default_pool_config =
  {
    max_connection_lifetime = 3600.0;
    liveness_check_timeout = None;
    max_connection_pool_size = 100;
    connection_acquisition_timeout = 60.0;
    connection_timeout = 30.0;
    connection_write_timeout = 30.0;
    keep_alive = true;
    telemetry_disabled = false;
    (* The home-database cache is off by default (the Optimisation:HomeDatabaseCache
       feature is not advertised): a default-database acquire always re-resolves
       the home database over ROUTE, like the Python driver without the feature. *)
    home_db_cache_ttl = 0.0;
  }

let make_workspace_config
    ?(max_transaction_retry_time = default_workspace_config.max_transaction_retry_time)
    ?(initial_retry_delay = default_workspace_config.initial_retry_delay)
    ?(retry_delay_multiplier = default_workspace_config.retry_delay_multiplier)
    ?(retry_delay_jitter_factor = default_workspace_config.retry_delay_jitter_factor)
    ?(fetch_size = default_workspace_config.fetch_size)
    ?(database = default_workspace_config.database)
    ?(impersonated_user = default_workspace_config.impersonated_user)
    ?(disable_auto_commit_retries = default_workspace_config.disable_auto_commit_retries) () =
  let invalid =
    List.filter_map
      (fun (name, valid) -> if valid then None else Some name)
      [
        ("max_transaction_retry_time", max_transaction_retry_time >= 0.0);
        ("initial_retry_delay", initial_retry_delay >= 0.0);
        ("retry_delay_multiplier", retry_delay_multiplier >= 1.0);
        ("retry_delay_jitter_factor", retry_delay_jitter_factor >= 0.0);
        ("fetch_size", fetch_size >= 1);
      ]
  in
  match invalid with
  | [] ->
      Ok
        {
          max_transaction_retry_time;
          initial_retry_delay;
          retry_delay_multiplier;
          retry_delay_jitter_factor;
          fetch_size;
          database;
          impersonated_user;
          disable_auto_commit_retries;
        }
  | names ->
      Error (Errors.Configuration_error ("Invalid workspace config: " ^ String.concat ", " names))

let make_pool_config ?(max_connection_lifetime = default_pool_config.max_connection_lifetime)
    ?(liveness_check_timeout = default_pool_config.liveness_check_timeout)
    ?(max_connection_pool_size = default_pool_config.max_connection_pool_size)
    ?(connection_acquisition_timeout = default_pool_config.connection_acquisition_timeout)
    ?(connection_timeout = default_pool_config.connection_timeout)
    ?(connection_write_timeout = default_pool_config.connection_write_timeout)
    ?(keep_alive = default_pool_config.keep_alive)
    ?(telemetry_disabled = default_pool_config.telemetry_disabled)
    ?(home_db_cache_ttl = default_pool_config.home_db_cache_ttl) () =
  let invalid =
    List.filter_map
      (fun (name, valid) -> if valid then None else Some name)
      [
        ("max_connection_lifetime", max_connection_lifetime >= 0.0);
        ("max_connection_pool_size", max_connection_pool_size <> 0);
        ("connection_acquisition_timeout", connection_acquisition_timeout >= 0.0);
        ("connection_timeout", connection_timeout >= 0.0);
        ("connection_write_timeout", connection_write_timeout >= 0.0);
        ("home_db_cache_ttl", home_db_cache_ttl >= 0.0);
      ]
  in
  match invalid with
  | [] ->
      Ok
        {
          max_connection_lifetime;
          liveness_check_timeout;
          max_connection_pool_size;
          connection_acquisition_timeout;
          connection_timeout;
          connection_write_timeout;
          keep_alive;
          telemetry_disabled;
          home_db_cache_ttl;
        }
  | names -> Error (Errors.Configuration_error ("Invalid pool config: " ^ String.concat ", " names))
