open Neodriver
open Alcotest

let defaults () =
  let workspace = Config.default_workspace_config in
  check (float 1e-9) "connection acquisition timeout" 60.0
    workspace.connection_acquisition_timeout;
  check (float 1e-9) "max transaction retry time" 30.0
    workspace.max_transaction_retry_time;
  check (float 1e-9) "initial retry delay" 1.0 workspace.initial_retry_delay;
  check (float 1e-9) "retry delay multiplier" 2.0
    workspace.retry_delay_multiplier;
  check (float 1e-9) "retry delay jitter factor" 0.2
    workspace.retry_delay_jitter_factor;
  check int "fetch size" 1000 workspace.fetch_size;
  check (option string) "database default" None workspace.database;
  check (option string) "impersonated user default" None
    workspace.impersonated_user;
  check bool "auto commit retries enabled" false
    workspace.disable_auto_commit_retries;
  let pool = Config.default_pool_config in
  check (float 1e-9) "max connection lifetime" 3600.0
    pool.max_connection_lifetime;
  check
    (option (float 1e-9))
    "liveness check timeout default" None pool.liveness_check_timeout;
  check int "max connection pool size" 100 pool.max_connection_pool_size;
  check (float 1e-9) "connection timeout" 30.0 pool.connection_timeout;
  check (float 1e-9) "connection write timeout" 30.0
    pool.connection_write_timeout;
  check bool "keep alive" true pool.keep_alive;
  check bool "telemetry enabled" false pool.telemetry_disabled

let access_mode () =
  check bool "default access mode is write" true
    (Config.default_access_mode = Config.Write)

let validation () =
  (match Config.make_workspace_config ~fetch_size:0 () with
  | Error _ -> ()
  | Ok _ -> fail "fetch_size = 0 should be rejected");
  (match Config.make_workspace_config ~retry_delay_multiplier:0.5 () with
  | Error _ -> ()
  | Ok _ -> fail "retry_delay_multiplier < 1 should be rejected");
  (match
     Config.make_workspace_config ~connection_acquisition_timeout:(-1.0) ()
   with
  | Error _ -> ()
  | Ok _ -> fail "negative timeout should be rejected");
  (match Config.make_pool_config ~max_connection_pool_size:0 () with
  | Error _ -> ()
  | Ok _ -> fail "max_connection_pool_size = 0 should be rejected");
  (match Config.make_workspace_config ~fetch_size:50 () with
  | Ok workspace -> check int "custom fetch size" 50 workspace.fetch_size
  | Error error -> fail (Errors.to_string error));
  match Config.make_pool_config ~max_connection_lifetime:(-5.0) () with
  | Error error ->
      check bool "validation error is a configuration error" true
        (match error with Errors.Configuration_error _ -> true | _ -> false)
  | Ok _ -> fail "negative lifetime should be rejected"

let tests =
  [
    ("[Config] defaults", [ test_case "default values" `Quick defaults ]);
    ( "[Config] access_mode",
      [ test_case "default access mode" `Quick access_mode ] );
    ("[Config] validation", [ test_case "validation" `Quick validation ]);
  ]
