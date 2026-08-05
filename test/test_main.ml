open Alcotest
module _ = Neodriver.Packstream
module _ = Neodriver.Errors
module _ = Neodriver.Config
module _ = Neodriver.Driver

let () =
  run "neodriver"
    (Test_errors.tests @ Test_config.tests @ Test_addressing.tests
   @ Test_deadline.tests @ Test_packstream.tests @ Test_temporal.tests
   @ Test_values.tests @ Test_hydration.tests)
