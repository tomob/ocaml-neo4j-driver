module _ = Neodriver.Packstream
module _ = Neodriver.Errors
module _ = Neodriver.Config
module _ = Neodriver.Driver

let () = Alcotest.run "neodriver" (Test_errors.tests @ Test_config.tests)
