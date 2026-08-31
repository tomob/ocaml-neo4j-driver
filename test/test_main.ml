open Alcotest
module _ = Neodriver.Packstream
module _ = Neodriver.Errors
module _ = Neodriver.Config
module _ = Neodriver.Driver

let () =
  run "neodriver"
    (Test_errors.tests @ Test_config.tests @ Test_addressing.tests @ Test_deadline.tests
   @ Test_packstream.tests @ Test_temporal.tests @ Test_values.tests @ Test_hydration.tests
   @ Test_handshake.tests @ Test_transport.tests @ Test_conn.tests @ Test_tls.tests
   @ Test_state.tests @ Test_capabilities.tests @ Test_query.tests @ Test_tx.tests
   @ Test_session.tests @ Test_driver.tests @ Test_pool.tests @ Test_routing_table.tests
   @ Test_cluster.tests @ Test_log.tests @ Test_integration.Test_handshake.tests
   @ Test_integration.Test_tls.tests @ Test_integration.Test_query.tests
   @ Test_integration.Test_pool.tests @ Test_integration.Test_session.tests
   @ Test_integration.Test_values.tests @ Test_integration.Test_routing.tests)
