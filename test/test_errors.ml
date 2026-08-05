open Neodriver

let check_classification code expected =
  let error = Errors.of_neo4j_code ~code ~message:"msg" in
  let actual =
    Errors.classification error |> Option.map Errors.classification_to_string
  in
  Alcotest.(check (option string)) code expected actual

let classification () =
  check_classification "Neo.ClientError.Statement.SyntaxError"
    (Some "ClientError");
  check_classification "Neo.TransientError.General.DatabaseUnavailable"
    (Some "TransientError");
  check_classification "Neo.DatabaseError.General.UnknownError"
    (Some "DatabaseError");
  check_classification "Neo.UnknownClassification.Foo.Bar" (Some "UnknownError");
  check_classification "garbage" (Some "DatabaseError")

let retryable () =
  let transient =
    Errors.of_neo4j_code ~code:"Neo.TransientError.General.DatabaseUnavailable"
      ~message:""
  in
  Alcotest.(check bool)
    "transient is retryable" true
    (Errors.is_retryable transient);
  let client =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Statement.SyntaxError"
      ~message:""
  in
  Alcotest.(check bool)
    "client is not retryable" false
    (Errors.is_retryable client);
  let authz_expired =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.AuthorizationExpired"
      ~message:""
  in
  Alcotest.(check bool)
    "authorization expired is retryable" true
    (Errors.is_retryable authz_expired);
  Alcotest.(check bool)
    "session expired is retryable" true
    (Errors.is_retryable (Errors.Session_expired "x"));
  Alcotest.(check bool)
    "service unavailable is retryable" true
    (Errors.is_retryable (Errors.Service_unavailable "x"));
  Alcotest.(check bool)
    "read service unavailable is retryable" true
    (Errors.is_retryable (Errors.Read_service_unavailable "x"));
  Alcotest.(check bool)
    "incomplete commit is not retryable" false
    (Errors.is_retryable (Errors.Incomplete_commit "x"));
  Alcotest.(check bool)
    "configuration error is not retryable" false
    (Errors.is_retryable (Errors.Configuration_error "x"));
  Alcotest.(check bool)
    "pool timeout is not retryable" false
    (Errors.is_retryable (Errors.Connection_acquisition_timeout "x"))

let rewrite () =
  let terminated =
    Errors.of_neo4j_code ~code:"Neo.TransientError.Transaction.Terminated"
      ~message:""
  in
  Alcotest.(check (option string))
    "terminated code rewritten" (Some "Neo.ClientError.Transaction.Terminated")
    (Errors.code terminated);
  Alcotest.(check (option string))
    "terminated reclassified as client" (Some "ClientError")
    (Errors.classification terminated
    |> Option.map Errors.classification_to_string);
  let lock_client_stopped =
    Errors.of_neo4j_code
      ~code:"Neo.TransientError.Transaction.LockClientStopped" ~message:""
  in
  Alcotest.(check (option string))
    "lock client stopped rewritten"
    (Some "Neo.ClientError.Transaction.LockClientStopped")
    (Errors.code lock_client_stopped)

let security () =
  let token_expired =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.TokenExpired"
      ~message:""
  in
  Alcotest.(check bool)
    "token expired has security code" true
    (Errors.has_security_code token_expired);
  let syntax =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Statement.SyntaxError"
      ~message:""
  in
  Alcotest.(check bool)
    "syntax has no security code" false
    (Errors.has_security_code syntax);
  Alcotest.(check bool)
    "driver error has no security code" false
    (Errors.has_security_code (Errors.Service_unavailable "x"))

let fatal_during_discovery () =
  let fatal_codes =
    [
      "Neo.ClientError.Database.DatabaseNotFound";
      "Neo.ClientError.Transaction.InvalidBookmark";
      "Neo.ClientError.Transaction.InvalidBookmarkMixture";
      "Neo.ClientError.Statement.TypeError";
      "Neo.ClientError.Statement.ArgumentError";
      "Neo.ClientError.Request.Invalid";
      "Neo.ClientError.Security.Forbidden";
    ]
  in
  List.iter
    (fun code ->
      let error = Errors.of_neo4j_code ~code ~message:"" in
      Alcotest.(check bool) code true (Errors.is_fatal_during_discovery error))
    fatal_codes;
  let authz_expired =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.AuthorizationExpired"
      ~message:""
  in
  Alcotest.(check bool)
    "authorization expired is not fatal" false
    (Errors.is_fatal_during_discovery authz_expired);
  let syntax =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Statement.SyntaxError"
      ~message:""
  in
  Alcotest.(check bool)
    "syntax is not fatal" false
    (Errors.is_fatal_during_discovery syntax)

let specific () =
  let check code expected =
    let error = Errors.of_neo4j_code ~code ~message:"" in
    Alcotest.(check string)
      code expected
      (Errors.specific_to_string (Errors.specific error))
  in
  check "Neo.ClientError.Statement.SyntaxError" "CypherSyntax";
  check "Neo.ClientError.Statement.TypeError" "CypherType";
  check "Neo.ClientError.Schema.ConstraintValidationFailed" "Constraint";
  check "Neo.ClientError.Security.Unauthorized" "Auth";
  check "Neo.ClientError.Security.TokenExpired" "TokenExpired";
  check "Neo.ClientError.Security.Forbidden" "Forbidden";
  check "Neo.ClientError.General.ForbiddenOnReadOnlyDatabase"
    "ForbiddenOnReadOnlyDatabase";
  check "Neo.ClientError.Cluster.NotALeader" "NotALeader";
  check "Neo.TransientError.General.DatabaseUnavailable" "DatabaseUnavailable";
  check "Neo.ClientError.General.UnknownThing" "Other"

let to_string () =
  let error =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Statement.SyntaxError"
      ~message:"bad query"
  in
  Alcotest.(check string)
    "server error string"
    "{neo4j_code: Neo.ClientError.Statement.SyntaxError} {message: bad query}"
    (Errors.to_string error);
  Alcotest.(check string)
    "driver error string" "boom"
    (Errors.to_string (Errors.Service_unavailable "boom"))

let tests =
  [
    ("classification", [ Alcotest.test_case "codes" `Quick classification ]);
    ("retryable", [ Alcotest.test_case "retryability" `Quick retryable ]);
    ("rewrite", [ Alcotest.test_case "rewrite map" `Quick rewrite ]);
    ("security", [ Alcotest.test_case "security codes" `Quick security ]);
    ( "fatal_discovery",
      [
        Alcotest.test_case "fatal during discovery" `Quick
          fatal_during_discovery;
      ] );
    ("specific", [ Alcotest.test_case "specific mapping" `Quick specific ]);
    ("to_string", [ Alcotest.test_case "string rendering" `Quick to_string ]);
  ]
