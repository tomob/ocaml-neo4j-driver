(* Custom address resolver: map the driver URI's virtual host to a real server.
   For a bolt:// driver the resolver replaces the address lookup (each returned
   address is tried in turn); for neo4j:// it also supplies the routing seeds. *)

open Neodriver

let virtual_uri = "bolt://virtual.example.com:7687"

let target =
  match Addressing.parse_uri Common.uri with
  | Ok parsed -> Addressing.of_host_port parsed.host parsed.port
  | Error error -> failwith (Errors.to_string error)

let resolver address =
  Printf.printf "resolving %s -> %s\n" (Addressing.to_string address) (Addressing.to_string target);
  Ok [ target ]

let or_fail = function Ok value -> value | Error error -> failwith (Errors.to_string error)

let () =
  Common.with_session ~uri:virtual_uri ~resolver (fun session ->
      let result =
        Session.run session ~query:"CREATE (a:Resolved {at: $at})"
          ~parameters:[ ("at", Values.String (Addressing.to_string target)) ]
        |> or_fail
      in
      Neo4jResult.consume result |> or_fail |> ignore;
      Printf.printf "query ran through the resolved address %s\n" (Addressing.to_string target))
