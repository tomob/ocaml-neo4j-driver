(* Routing for [neo4j://] drivers.

   A [t] holds the routing tables per database (fetched over the ROUTE message,
   refreshed on TTL expiry or a failed fetch) and a pool per cluster address.
   Addresses are chosen per role and access mode on the least-loaded server
   (fewest in-use connections). The richer routing behaviours — address
   deactivation, server-side routing, the home-db cache and the pre-4.3
   procedure fallback — are deferred to follow-ups (see PLAN.md phase A7). *)

open Neodriver_core

let ( let* ) = Result.bind

type t = {
  pool_config : Config.pool_config;
  connect : Addressing.t -> (Conn.t, Errors.t) result;
  routing_context : (string * string) list;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  mutable routers : Addressing.t list;
  tables : (string option, Routing_table.t * Mtime.t) Hashtbl.t;
  errors : (string option, Errors.t * Mtime.t) Hashtbl.t;
  in_flight : (string option, bool) Hashtbl.t;
  pools : (string, Pool.t) Hashtbl.t;
  lock : Eio.Mutex.t;
  cond : Eio.Condition.t;
}

(* How long a failed routing-table fetch is remembered, so concurrent acquires
   don't all retry immediately after a router failure. *)
let negative_ttl = 5.0

let create ~pool_config ~connect ~routing_context ~initial clock =
  {
    pool_config;
    connect;
    routing_context;
    clock;
    routers = [ initial ];
    tables = Hashtbl.create 4;
    errors = Hashtbl.create 4;
    in_flight = Hashtbl.create 4;
    pools = Hashtbl.create 4;
    lock = Eio.Mutex.create ();
    cond = Eio.Condition.create ();
  }

let now t = Eio.Time.Mono.now t.clock
let elapsed_s t since = Mtime.Span.to_float_ns (Mtime.span (now t) since) /. 1_000_000_000.

let with_lock t f =
  Eio.Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.lock) f

let pool_for cluster addr =
  let key = Addressing.to_string addr in
  match Hashtbl.find_opt cluster.pools key with
  | Some pool -> pool
  | None ->
      let pool =
        Pool.create ~pool_config:cluster.pool_config
          ~connect:(fun () -> cluster.connect addr)
          cluster.clock
      in
      Hashtbl.add cluster.pools key pool;
      pool

(* Load of an address: in-use connections of its pool, or 0 if no pool exists
   yet (pools are created lazily for the chosen address only). *)
let load_of cluster addr =
  match Hashtbl.find_opt cluster.pools (Addressing.to_string addr) with
  | Some pool -> Pool.in_use_count pool
  | None -> 0

(* Fetch a fresh routing table for [database], trying each router in turn: a
   connection is opened directly to the router for the ROUTE request and closed
   afterwards. A router that fails to connect, answers ROUTE with an error or
   returns an unparseable table is skipped in favour of the next one.
   [last_error] carries the most recent failure so the caller gets a meaningful
   error when every router fails. *)
let rec fetch_table cluster ~database last_error = function
  | [] -> (
      match last_error with
      | Some error -> Error error
      | None -> Error (Errors.Service_unavailable "no router available for routing"))
  | addr :: rest -> (
      match cluster.connect addr with
      | Error error -> fetch_table cluster ~database (Some error) rest
      | Ok conn -> (
          let result =
            match
              Conn.route ?db:database conn ~routing_context:cluster.routing_context ~bookmarks:[]
            with
            | Error error -> Error error
            | Ok rt -> (
                match Routing_table.parse rt with
                | Some table -> Ok table
                | None -> Error (Errors.Service_unavailable "unparseable routing table"))
          in
          Conn.close conn;
          match result with
          | Ok _ as ok -> ok
          | Error error -> fetch_table cluster ~database (Some error) rest))

(* The fresh cached table for [database], if any (caller holds the lock). *)
let fresh_table cluster ~database =
  match Hashtbl.find_opt cluster.tables database with
  | Some (table, fetched_at)
    when elapsed_s cluster fetched_at <= float_of_int (Routing_table.ttl_seconds table) ->
      Some table
  | _ -> None

(* A recent fetch failure for [database], if any (caller holds the lock). *)
let cached_error cluster ~database =
  match Hashtbl.find_opt cluster.errors database with
  | Some (error, failed_at) when elapsed_s cluster failed_at <= negative_ttl -> Some error
  | _ -> None

(* Resolve the routing table for [database]. The lock is held only for the fast
   cache lookup and the single-flight coordination — the actual ROUTE fetch runs
   outside it — and at most one fetch per database is in progress at a time:
   concurrent acquires wait on the condition, then re-check the caches. A recent
   failure is served from the negative cache instead of being re-fetched. *)
let rec resolve_table cluster ~database =
  let decision =
    with_lock cluster (fun () ->
        match fresh_table cluster ~database with
        | Some table -> `Ok table
        | None -> (
            match cached_error cluster ~database with
            | Some error -> `Error error
            | None ->
                if Hashtbl.mem cluster.in_flight database then begin
                  Eio.Condition.await cluster.cond cluster.lock;
                  `Wait
                end
                else begin
                  Hashtbl.add cluster.in_flight database true;
                  `Fetch
                end))
  in
  match decision with
  | `Ok table -> Ok table
  | `Error error -> Error error
  | `Wait -> resolve_table cluster ~database
  | `Fetch ->
      (* Fetch outside the lock. Cancellation (e.g. the caller's acquisition
         timeout) still clears the in-flight marker and wakes the waiters. *)
      let result =
        Fun.protect
          ~finally:(fun () ->
            with_lock cluster (fun () ->
                Hashtbl.remove cluster.in_flight database;
                Eio.Condition.broadcast cluster.cond))
          (fun () -> fetch_table cluster ~database None cluster.routers)
      in
      with_lock cluster (fun () ->
          match result with
          | Ok table ->
              Hashtbl.replace cluster.tables database (table, now cluster);
              cluster.routers <- Routing_table.routers table;
              Hashtbl.remove cluster.errors database
          | Error error -> Hashtbl.replace cluster.errors database (error, now cluster));
      result

let acquire cluster ~mode ~database =
  let pool =
    try
      Eio.Time.Timeout.run_exn
        (Eio.Time.Timeout.seconds cluster.clock cluster.pool_config.connection_acquisition_timeout)
        (fun () ->
          let* table = resolve_table cluster ~database in
          with_lock cluster (fun () ->
              let addresses =
                match mode with
                | Config.Read -> Routing_table.readers table
                | Config.Write -> Routing_table.writers table
              in
              (* The least-loaded address of the role's slice (fewest in-use
                 connections), so concurrent sessions spread across the cluster
                 instead of piling up on one server. *)
              match Routing_table.least_loaded ~load:(load_of cluster) addresses with
              | Some addr -> Ok (pool_for cluster addr)
              | None -> Error (Errors.Service_unavailable "routing table has no suitable address")))
    with Eio.Time.Timeout ->
      Error (Errors.Connection_acquisition_timeout "Timed out acquiring a connection")
  in
  match pool with Error _ as error -> error | Ok pool -> Pool.acquire pool

let release cluster conn =
  match Hashtbl.find_opt cluster.pools (Addressing.to_string (Conn.address conn)) with
  | Some pool -> Pool.release pool conn
  | None -> Conn.close conn

let close cluster =
  with_lock cluster (fun () -> Hashtbl.iter (fun _ pool -> Pool.close pool) cluster.pools)
