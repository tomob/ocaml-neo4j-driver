(* Reads the TEST_NEO4J_* environment variables that point at a live Neo4j
   instance. Integration tests are skipped when TEST_NEO4J_HOST is not set. *)

type t = { host : string; port : int; scheme : string; user : string; password : string }

let scheme_of_string = function
  | "bolt" -> Neodriver.Addressing.Bolt
  | "bolt+s" -> Neodriver.Addressing.Bolt_secure
  | "bolt+ssc" -> Neodriver.Addressing.Bolt_self_signed
  | "neo4j" -> Neodriver.Addressing.Neo4j
  | "neo4j+s" -> Neodriver.Addressing.Neo4j_secure
  | "neo4j+ssc" -> Neodriver.Addressing.Neo4j_self_signed
  | other -> invalid_arg ("Test_env: unknown scheme " ^ other)

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

(* A Conn.config for [env], using the env scheme unless overridden. *)
let conn_config ?scheme ?password (env : t) =
  Neodriver_eio.Conn.
    {
      host = env.host;
      port = env.port;
      scheme = Option.value ~default:(scheme_of_string env.scheme) scheme;
      connection_timeout = 10.0;
      user_agent = Neodriver_eio.Conn.default_user_agent;
      auth =
        {
          scheme = "basic";
          principal = env.user;
          credentials = Option.value ~default:env.password password;
        };
      routing_context = None;
    }
