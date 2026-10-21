(* TLS: the URI scheme selects encryption and trust (bolt+s / neo4j+s use the
   system CAs; the +ssc variants trust any certificate). To trust custom CA
   files, point NEO4J_TLS_CA at comma-separated PEM files and use a plain
   bolt:// URI: explicit encryption/trust is only allowed with a plain scheme.
   Combining it with a secure (+s/+ssc) scheme is a configuration error. *)

open Neodriver

let custom_cas =
  match Sys.getenv_opt "NEO4J_TLS_CA" with
  | Some paths when paths <> "" ->
      Some (Config.Custom (String.split_on_char ',' paths |> List.map String.trim))
  | _ -> None

let pool_config =
  match custom_cas with
  | None -> None
  | Some trusted_certificates ->
      Some
        ( Config.make_pool_config ~encryption:Config.Enabled
            ~trusted_certificates:(Some trusted_certificates) ()
        |> function
          | Ok config -> config
          | Error error -> failwith (Errors.to_string error) )

let or_fail = function Ok value -> value | Error error -> failwith (Errors.to_string error)

let () =
  Common.with_session ?pool_config (fun session ->
      let result = Session.run session ~query:"RETURN 1 AS n" ~parameters:[] |> or_fail in
      match Neo4jResult.values result |> or_fail with
      | [ [ Values.Int _ ] ] ->
          Printf.printf "connected to %s%s\n" Common.uri
            (match custom_cas with
            | Some _ -> " with custom trusted certificates"
            | None -> " using the URI scheme's TLS settings")
      | _ -> failwith "expected a single integer")
