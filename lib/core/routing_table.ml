(* Routing tables for [neo4j://] (routed) drivers.

   A routing table is fetched from the server (the ROUTE Bolt message or, on
   old protocol versions, the dbms.routing.getRoutingTable procedure) and maps
   the cluster addresses for one database to their roles. See routing_table.mli. *)

open Neodriver_packstream

type t = {
  ttl_seconds : int;
  routers : Addressing.t list;
  readers : Addressing.t list;
  writers : Addressing.t list;
}

let ttl_seconds t = t.ttl_seconds
let routers t = t.routers
let readers t = t.readers
let writers t = t.writers

(* Routing table addresses are "host:port" strings. *)
let parse_address s = match Addressing.parse s with Ok address -> Some address | Error _ -> None

(* One server entry: { addresses: [String]; role: String }. *)
let parse_server = function
  | Packstream.Map fields -> (
      match (List.assoc_opt "addresses" fields, List.assoc_opt "role" fields) with
      | Some (Packstream.List addresses), Some (Packstream.String role) ->
          let addresses =
            List.filter_map
              (function Packstream.String address -> parse_address address | _ -> None)
              addresses
          in
          Some (role, addresses)
      | _ -> None)
  | _ -> None

(* Parse an [rt] value: { ttl: Int; servers: [{ addresses: [String]; role: String }] }. *)
let parse value =
  match value with
  | Packstream.Map fields -> (
      match (List.assoc_opt "ttl" fields, List.assoc_opt "servers" fields) with
      | Some (Packstream.Int ttl), Some (Packstream.List servers) ->
          let rec go routers readers writers = function
            | [] -> Some { ttl_seconds = Int64.to_int ttl; routers; readers; writers }
            | server :: rest -> (
                match parse_server server with
                | Some ("ROUTE", addresses) -> go (routers @ addresses) readers writers rest
                | Some ("READ", addresses) -> go routers (readers @ addresses) writers rest
                | Some ("WRITE", addresses) -> go routers readers (writers @ addresses) rest
                | _ -> go routers readers writers rest)
          in
          go [] [] [] servers
      | _ -> None)
  | _ -> None

(* Round-robin over the addresses of one role. *)
let pick counter addresses =
  match addresses with
  | [] -> None
  | _ ->
      let i = !counter mod List.length addresses in
      incr counter;
      Some (List.nth addresses i)
