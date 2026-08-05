(* Reads the TEST_NEO4J_* environment variables that point at a live Neo4j
   instance. Integration tests are skipped when TEST_NEO4J_HOST is not set. *)

type t = { host : string; port : int; scheme : string; user : string; password : string }

let of_env () =
  match Sys.getenv_opt "TEST_NEO4J_HOST" with
  | None -> None
  | Some host ->
      let port =
        match Sys.getenv_opt "TEST_NEO4J_PORT" with
        | Some p -> ( match int_of_string_opt p with Some n -> n | None -> 7687)
        | None -> 7687
      in
      Some
        {
          host;
          port;
          scheme = Option.value ~default:"bolt" (Sys.getenv_opt "TEST_NEO4J_SCHEME");
          user = Option.value ~default:"neo4j" (Sys.getenv_opt "TEST_NEO4J_USER");
          password = Option.value ~default:"" (Sys.getenv_opt "TEST_NEO4J_PASS");
        }
