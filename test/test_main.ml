open Alcotest
module _ = Neodriver.Packstream
module _ = Neodriver.Errors
module _ = Neodriver.Config
module _ = Neodriver.Driver

let () =
  run "neodriver"
    (Test_errors.tests @ Test_config.tests @ Test_addressing.tests @ Test_deadline.tests
   @ Test_packstream.tests @ Test_temporal.tests @ Test_values.tests @ Test_hydration.tests
   @ Test_handshake.tests @ Test_transport.tests @ Test_conn.tests
   @ Test_integration.Test_handshake.tests)
