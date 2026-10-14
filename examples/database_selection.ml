(* Selecting a database: a session (or a one-shot execute_query) targets a named
   database through its session config. Requires a server that offers the
   "examples" database (multi-database: enterprise, or a server where it was
   created). *)

open Neodriver

let database = "examples"
let or_fail = function Ok value -> value | Error error -> failwith (Errors.to_string error)
let config access_mode = { Session.default_config with database = Some database; access_mode }

let write driver =
  Driver.execute_query driver ~config:(config Config.Write)
    ~query:"CREATE (a:Greeting {message: 'Hello, Example-Database'})" ~parameters:[]
  |> or_fail |> ignore

let read driver =
  let session = Driver.session ~config:(config Config.Read) driver in
  Fun.protect
    ~finally:(fun () -> Session.close session)
    (fun () ->
      let result =
        Session.run session ~query:"MATCH (a:Greeting) RETURN a.message AS msg" ~parameters:[]
        |> or_fail
      in
      match Neo4jResult.single result |> or_fail with
      | [ Values.String message ] -> message
      | _ -> failwith "expected a message")

let () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let driver = Common.connect net clock sw in
          write driver;
          Printf.printf "%s (from database '%s')\n" (read driver) database))
