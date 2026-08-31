open Neodriver
open Alcotest

let fields_of token =
  match Auth_manager.to_map token with
  | Packstream.Map fields -> fields
  | _ -> fail "expected a Packstream Map"

let field key fields = List.assoc_opt key fields

let to_map () =
  let basic = Auth_manager.basic_auth () in
  let fields = fields_of basic in
  check (option string) "basic scheme" (Some "basic")
    (field "scheme" fields |> Option.map (function Packstream.String s -> s | _ -> fail "scheme"));
  check (option string) "basic principal default" (Some "neo4j")
    (field "principal" fields
    |> Option.map (function Packstream.String s -> s | _ -> fail "principal"));
  check (option string) "basic credentials default" (Some "")
    (field "credentials" fields
    |> Option.map (function Packstream.String s -> s | _ -> fail "credentials"));
  check bool "basic realm absent" true (field "realm" fields = None);
  check bool "basic parameters absent" true (field "parameters" fields = None);
  let with_realm =
    Auth_manager.basic_auth ~principal:"alice" ~credentials:"pw" ~realm:"native" ()
  in
  let fields = fields_of with_realm in
  check (option string) "basic principal" (Some "alice")
    (field "principal" fields
    |> Option.map (function Packstream.String s -> s | _ -> fail "principal"));
  check (option string) "basic credentials" (Some "pw")
    (field "credentials" fields
    |> Option.map (function Packstream.String s -> s | _ -> fail "credentials"));
  check (option string) "basic realm present" (Some "native")
    (field "realm" fields |> Option.map (function Packstream.String s -> s | _ -> fail "realm"))

let bearer () =
  let token = Auth_manager.bearer_auth "tok123" in
  let fields = fields_of token in
  check (option string) "bearer scheme" (Some "bearer")
    (field "scheme" fields |> Option.map (function Packstream.String s -> s | _ -> fail "scheme"));
  check bool "bearer principal omitted" true (field "principal" fields = None);
  check (option string) "bearer credentials" (Some "tok123")
    (field "credentials" fields
    |> Option.map (function Packstream.String s -> s | _ -> fail "credentials"))

let custom () =
  let token =
    Auth_manager.custom_auth ~principal:"p" ~realm:"r"
      ~parameters:[ ("k", Packstream.String "v") ]
      "my-scheme"
  in
  let fields = fields_of token in
  check (option string) "custom scheme" (Some "my-scheme")
    (field "scheme" fields |> Option.map (function Packstream.String s -> s | _ -> fail "scheme"));
  check (option string) "custom principal" (Some "p")
    (field "principal" fields
    |> Option.map (function Packstream.String s -> s | _ -> fail "principal"));
  check bool "custom credentials absent" true (field "credentials" fields = None);
  check (option string) "custom realm" (Some "r")
    (field "realm" fields |> Option.map (function Packstream.String s -> s | _ -> fail "realm"));
  check (option string) "custom parameters"
    (Some (Packstream.to_string (Packstream.Map [ ("k", Packstream.String "v") ])))
    (field "parameters" fields |> Option.map Packstream.to_string)

let equality () =
  let a = Auth_manager.basic_auth ~principal:"neo4j" ~credentials:"pw" () in
  let b = Auth_manager.basic_auth ~principal:"neo4j" ~credentials:"pw" () in
  let c = Auth_manager.basic_auth ~principal:"neo4j" ~credentials:"other" () in
  let d = Auth_manager.basic_auth ~principal:"alice" ~credentials:"pw" () in
  check bool "same basic tokens equal" true (Auth_manager.eq a b);
  check bool "different credentials differ" false (Auth_manager.eq a c);
  check bool "different principal differs" false (Auth_manager.eq a d);
  check bool "basic vs bearer differs" false (Auth_manager.eq a (Auth_manager.bearer_auth "pw"));
  let with_params_1 =
    Auth_manager.custom_auth ~principal:"p"
      ~parameters:[ ("a", Packstream.Int 1L); ("b", Packstream.Int 2L) ]
      "custom"
  in
  let with_params_2 =
    Auth_manager.custom_auth ~principal:"p"
      ~parameters:[ ("b", Packstream.Int 2L); ("a", Packstream.Int 1L) ]
      "custom"
  in
  let without_params = Auth_manager.custom_auth ~principal:"p" "custom" in
  check bool "parameters order-independent" true (Auth_manager.eq with_params_1 with_params_2);
  check bool "parameters presence matters" false (Auth_manager.eq with_params_1 without_params)

let expiry () =
  let auth = Auth_manager.{ token = Auth_manager.bearer_auth "t"; expires_at = None } in
  check bool "no expiry never expires" false (Auth_manager.has_expired ~now:1_000_000.0 auth);
  let expiring = Auth_manager.expires_in ~now:100.0 10.0 auth in
  check bool "expires_in sets expires_at" true (Auth_manager.has_expired ~now:110.1 expiring);
  check bool "not expired before expiry" false (Auth_manager.has_expired ~now:109.0 expiring);
  check bool "not expired exactly at expiry" false (Auth_manager.has_expired ~now:110.0 expiring);
  check bool "expires_in returns a flat copy" true
    (match expiring with
    | { token; expires_at = Some 110.0 } -> Auth_manager.eq token auth.token
    | _ -> false)

let static_manager () =
  let token = Auth_manager.basic_auth () in
  let manager = Auth_manager.static token in
  check bool "static get_auth returns the token" true
    (match manager.get_auth () with Ok t -> Auth_manager.eq t token | Error _ -> false);
  let unauthorized =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.Unauthorized" ~message:""
  in
  check bool "static never handles security exceptions" true
    (match manager.handle_security_exception token unauthorized with
    | Ok false -> true
    | _ -> false)

let basic_manager () =
  let count = ref 0 in
  let provider () =
    incr count;
    Ok (Auth_manager.basic_auth ~credentials:(Printf.sprintf "pw%d" !count) ())
  in
  let manager = Auth_manager.basic ~provider in
  let token1 = match manager.get_auth () with Ok t -> t | Error _ -> fail "get_auth failed" in
  check int "provider called once on first get_auth" 1 !count;
  let token1b = match manager.get_auth () with Ok t -> t | Error _ -> fail "get_auth failed" in
  check int "cached, provider not called again" 1 !count;
  check bool "same cached token" true (Auth_manager.eq token1 token1b);
  let unauthorized =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.Unauthorized" ~message:""
  in
  check bool "unauthorized handled" true
    (match manager.handle_security_exception token1 unauthorized with
    | Ok true -> true
    | _ -> false);
  check int "refresh on unauthorized" 2 !count;
  let syntax = Errors.of_neo4j_code ~code:"Neo.ClientError.Statement.SyntaxError" ~message:"" in
  check bool "non-handled code not handled" true
    (match manager.handle_security_exception token1 syntax with Ok false -> true | _ -> false);
  check int "no refresh on non-handled code" 2 !count;
  let driver_error = Errors.Service_unavailable "x" in
  check bool "driver error not handled" true
    (match manager.handle_security_exception token1 driver_error with
    | Ok false -> true
    | _ -> false);
  let stale = Auth_manager.basic_auth ~credentials:"pw1" () in
  check bool "stale token still handled" true
    (match manager.handle_security_exception stale unauthorized with Ok true -> true | _ -> false);
  check int "no refresh on stale token" 2 !count;
  let failing =
    Auth_manager.basic ~provider:(fun () -> Error (Errors.Service_unavailable "boom"))
  in
  check bool "provider failure surfaces from get_auth" true
    (match failing.get_auth () with
    | Error (Errors.Service_unavailable "boom") -> true
    | _ -> false)

let bearer_manager () =
  let now_ref = ref 1000.0 in
  let now () = !now_ref in
  let count = ref 0 in
  let provider () =
    incr count;
    let token = Auth_manager.bearer_auth (Printf.sprintf "token%d" !count) in
    Ok (Auth_manager.expires_in ~now:(now ()) 10.0 { token; expires_at = None })
  in
  let manager = Auth_manager.bearer ~now ~provider in
  let token1 = match manager.get_auth () with Ok t -> t | Error _ -> fail "get_auth failed" in
  check int "bearer provider called once" 1 !count;
  now_ref := 1005.0;
  let token1b = match manager.get_auth () with Ok t -> t | Error _ -> fail "get_auth failed" in
  check int "cached before expiry" 1 !count;
  check bool "same token before expiry" true (Auth_manager.eq token1 token1b);
  now_ref := 1010.5;
  let token2 = match manager.get_auth () with Ok t -> t | Error _ -> fail "get_auth failed" in
  check int "refreshed once expiry passed" 2 !count;
  check bool "refreshed token differs" false (Auth_manager.eq token1 token2);
  let token_expired =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.TokenExpired" ~message:""
  in
  check bool "token expired handled" true
    (match manager.handle_security_exception token2 token_expired with
    | Ok true -> true
    | _ -> false);
  check int "refresh on token expired" 3 !count;
  let unauthorized =
    Errors.of_neo4j_code ~code:"Neo.ClientError.Security.Unauthorized" ~message:""
  in
  let token3 = match manager.get_auth () with Ok t -> t | Error _ -> fail "get_auth failed" in
  check bool "unauthorized handled for bearer" true
    (match manager.handle_security_exception token3 unauthorized with
    | Ok true -> true
    | _ -> false);
  check int "refresh on unauthorized for bearer" 4 !count

let tests =
  [
    ("[Auth_manager] to_map basic", [ test_case "basic token map" `Quick to_map ]);
    ("[Auth_manager] to_map bearer", [ test_case "bearer token map" `Quick bearer ]);
    ("[Auth_manager] to_map custom", [ test_case "custom token map" `Quick custom ]);
    ("[Auth_manager] equality", [ test_case "token equality" `Quick equality ]);
    ("[Auth_manager] expiry", [ test_case "expiring auth" `Quick expiry ]);
    ("[Auth_manager] static", [ test_case "static manager" `Quick static_manager ]);
    ("[Auth_manager] basic", [ test_case "basic manager" `Quick basic_manager ]);
    ("[Auth_manager] bearer", [ test_case "bearer manager" `Quick bearer_manager ]);
  ]
