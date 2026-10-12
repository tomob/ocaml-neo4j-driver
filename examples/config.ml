(* Driver-level configuration: tune the connection pool and the default
   workspace settings (retry policy, fetch size, database) once for the driver,
   instead of per session. Every session the driver creates inherits the
   workspace defaults; a session's own [~config] overrides them. *)

open Neodriver

let or_fail = function Ok value -> value | Error error -> failwith (Errors.to_string error)

let pool_config () =
  Config.make_pool_config ~max_connection_pool_size:50 ~max_connection_lifetime:1800.
    ~connection_acquisition_timeout:120. ()
  |> or_fail

let workspace_config () =
  Config.make_workspace_config ~max_transaction_retry_time:15. ~fetch_size:500 () |> or_fail

let () =
  Common.with_session ~pool_config:(pool_config ()) ~workspace_config:(workspace_config ())
    (fun session ->
      let result = Session.run session ~query:"RETURN 1 AS n" ~parameters:[] |> or_fail in
      match Neo4jResult.values result |> or_fail with
      | [ [ Values.Int n ] ] ->
          Printf.printf
            "pool: max 50 connections, 30m lifetime, 2m acquisition\n\
             workspace: retry 15s, fetch size 500\n\
             RETURN 1 -> %Ld\n"
            n
      | _ -> failwith "expected a single integer")
