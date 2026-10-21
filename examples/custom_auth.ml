(* Custom authentication: build a token for an arbitrary scheme with an optional
   realm and extra parameters, then hand it to Driver.connect. The defaults
   (basic scheme, NEO4J_USER/NEO4J_PASSWORD) behave like basic auth. Override
   with AUTH_SCHEME, AUTH_PRINCIPAL, AUTH_CREDENTIALS, AUTH_REALM,
   AUTH_PARAM_KEY and AUTH_PARAM_VALUE. *)

open Neodriver

let env = Common.env
let scheme = env "AUTH_SCHEME" "basic"
let principal = env "AUTH_PRINCIPAL" Common.user
let credentials = env "AUTH_CREDENTIALS" Common.password

let realm =
  match Sys.getenv_opt "AUTH_REALM" with Some value when value <> "" -> Some value | _ -> None

let parameters =
  match (Sys.getenv_opt "AUTH_PARAM_KEY", Sys.getenv_opt "AUTH_PARAM_VALUE") with
  | Some key, Some value when key <> "" && value <> "" -> [ (key, Packstream.String value) ]
  | _ -> []

let or_fail = function Ok value -> value | Error error -> failwith (Errors.to_string error)

let () =
  let auth = Auth_manager.custom_auth ~principal ~credentials ?realm ~parameters scheme in
  Common.with_session ~auth (fun session ->
      let result = Session.run session ~query:"RETURN 1 AS n" ~parameters:[] |> or_fail in
      match Neo4jResult.values result |> or_fail with
      | [ [ Values.Int _ ] ] -> Printf.printf "authenticated with scheme '%s'\n" scheme
      | _ -> failwith "expected a single integer")
