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

(* The least-loaded address of one role: the smallest [load], ties broken by
   list order (deterministic — the Python driver uses random.choice instead). *)
let least_loaded ~load addresses =
  let best =
    List.fold_left
      (fun best addr ->
        let load = load addr in
        match best with
        | None -> Some (addr, load)
        | Some (_, best_load) -> if load < best_load then Some (addr, load) else best)
      None addresses
  in
  Option.map fst best

(* Drop [addr] from a role list; addresses compare by string form to match the
   rest of the codebase (pools, routers, load). *)
let drop_address addr = List.filter (fun a -> Addressing.to_string a <> Addressing.to_string addr)

let remove_address addr t =
  {
    t with
    routers = drop_address addr t.routers;
    readers = drop_address addr t.readers;
    writers = drop_address addr t.writers;
  }

let remove_writer addr t = { t with writers = drop_address addr t.writers }
