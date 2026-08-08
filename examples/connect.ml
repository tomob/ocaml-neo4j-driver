(* Connect to Neo4j and print the server information. The connection is
   lazy, so this example forces it with [Session.conn]. *)

open Neodriver

let () =
  Common.with_session (fun session ->
      match Session.conn session with
      | Ok conn ->
          Printf.printf "connected to %s (Bolt %d.%d, agent %s)\n"
            (Addressing.to_string (Conn.address conn))
            (fst (Conn.version conn))
            (snd (Conn.version conn))
            (match Conn.server_agent conn with Some agent -> agent | None -> "unknown")
      | Error error -> failwith (Errors.to_string error))
