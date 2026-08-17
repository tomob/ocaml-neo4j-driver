(* Routing for [neo4j://] drivers.

   A [t] holds the routing tables per database (fetched over the ROUTE message,
   refreshed on TTL expiry or a failed fetch) and a pool per cluster address.
   Addresses are chosen per role and access mode on the least-loaded server
   (fewest in-use connections). A server that fails a request (transport error
   or DatabaseUnavailable) or a routing-table fetch is deactivated: dropped
   from every routing table and its pool closed, so subsequent acquires skip it
   until a refresh re-lists it. A NotALeader / read-only failure removes the
   address from the database's writers only. Routing tables are also refreshed
   server-side: when the server sends an [rt] routing table in a RUN response
   (server-side routing), [update_table] replaces the cached table. A session
   for the default database ([database = None]) resolves its effective database
   to the server's home database (the [db] field of the ROUTE [rt]) and caches
   it per impersonated user with [home_db_cache_ttl], so later default-database
   sessions reuse it without a ROUTE. *)

open Neodriver_core

let ( let* ) = Result.bind

type t = {
  pool_config : Config.pool_config;
  connect : Addressing.t -> (Conn.t, Errors.t) result;
  routing_context : (string * string) list;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  mutable routers : Addressing.t list;
  initial_routers : Addressing.t list;
  tables : (string option, Routing_table.t * Mtime.t) Hashtbl.t;
  errors : (string option, Errors.t * Mtime.t) Hashtbl.t;
  in_flight : (string option, bool) Hashtbl.t;
  pools : (string, Pool.t) Hashtbl.t;
  routing : (string, Conn.t) Hashtbl.t;
  home_dbs : (string option, string * Mtime.t) Hashtbl.t;
  lock : Eio.Mutex.t;
  cond : Eio.Condition.t;
  routing_lock : Eio.Mutex.t;
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
    initial_routers = [ initial ];
    tables = Hashtbl.create 4;
    errors = Hashtbl.create 4;
    in_flight = Hashtbl.create 4;
    pools = Hashtbl.create 4;
    routing = Hashtbl.create 4;
    home_dbs = Hashtbl.create 4;
    lock = Eio.Mutex.create ();
    cond = Eio.Condition.create ();
    routing_lock = Eio.Mutex.create ();
  }

let now t = Eio.Time.Mono.now t.clock
let elapsed_s t since = Mtime.Span.to_float_ns (Mtime.span (now t) since) /. 1_000_000_000.

let with_lock t f =
  Eio.Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.lock) f

(* Serializes routing-table fetches (the ROUTE requests on the shared routing
   connections must not interleave across concurrent fetches). *)
let with_routing_lock t f =
  Eio.Mutex.lock t.routing_lock;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.routing_lock) f

(* The routers to try for a routing-table fetch: the known routers (from the
   cached tables) first, then the initial seed routers as a fallback — a known
   router that went down or serves unusable tables is skipped and the address
   that seeded the driver still gets a chance (Python keeps the initial routers
   for the same reason). *)
let fetch_routers cluster =
  let known = cluster.routers in
  let known_keys = List.map Addressing.to_string known in
  known
  @ List.filter
      (fun a -> not (List.mem (Addressing.to_string a) known_keys))
      cluster.initial_routers

(* Full address deactivation (under the lock): drop [addr] from every routing
   table and close its pool, so future acquires skip it until a refresh
   re-lists it. *)
let deactivate cluster addr =
  with_lock cluster (fun () ->
      let key = Addressing.to_string addr in
      Hashtbl.iter
        (fun database (table, fetched_at) ->
          Hashtbl.replace cluster.tables database
            (Routing_table.remove_address addr table, fetched_at))
        cluster.tables;
      cluster.routers <- List.filter (fun a -> Addressing.to_string a <> key) cluster.routers;
      (match Hashtbl.find_opt cluster.pools key with
      | Some pool ->
          Hashtbl.remove cluster.pools key;
          Pool.close pool
      | None -> ());
      match Hashtbl.find_opt cluster.routing key with
      | Some conn ->
          Hashtbl.remove cluster.routing key;
          Conn.close conn
      | None -> ())

(* Drop [addr] from the [writers] of [database] (a NotALeader / read-only
   failure), leaving the pool and the other roles untouched. *)
let on_write_failure cluster ~database addr =
  with_lock cluster (fun () ->
      match Hashtbl.find_opt cluster.tables database with
      | Some (table, fetched_at) ->
          Hashtbl.replace cluster.tables database
            (Routing_table.remove_writer addr table, fetched_at)
      | None -> ())

(* The error filter installed on the cluster's pool connections: transport
   errors and DatabaseUnavailable deactivate the address; NotALeader /
   read-only failures drop it from the writers of the database it last ran
   on. *)
let on_error cluster conn error =
  let addr = Conn.address conn in
  match Errors.specific error with
  | Errors.Not_a_leader | Errors.Forbidden_on_read_only_database ->
      on_write_failure cluster ~database:(Conn.last_database conn) addr
  | Errors.Database_unavailable -> deactivate cluster addr
  | _ -> ( match error with Errors.Service_unavailable _ -> deactivate cluster addr | _ -> ())

(* The pool for [addr], created on demand (caller holds the lock). New
   connections get the cluster's error callback, so request failures on them
   deactivate the address. *)
let pool_for cluster addr =
  let key = Addressing.to_string addr in
  match Hashtbl.find_opt cluster.pools key with
  | Some pool -> pool
  | None ->
      let pool =
        Pool.create ~pool_config:cluster.pool_config
          ~connect:(fun () ->
            let* conn = cluster.connect addr in
            Conn.set_on_error conn (fun conn error -> on_error cluster conn error);
            Ok conn)
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

(* The cached home database of [imp_user] (None = the driver's own user), if
   its age is within [home_db_cache_ttl] (caller holds the lock). An expired
   entry is a miss: the next default-database session resolves it again over
   ROUTE. *)
let home_db_of cluster imp_user =
  match Hashtbl.find_opt cluster.home_dbs imp_user with
  | Some (database, cached_at)
    when elapsed_s cluster cached_at <= cluster.pool_config.home_db_cache_ttl ->
      Some database
  | _ -> None

(* Cache [database] as the home database of [imp_user] (caller holds the
   lock). *)
let set_home_db cluster imp_user database =
  Hashtbl.replace cluster.home_dbs imp_user (database, now cluster)

(* The persistent routing connection for [addr]: ROUTE requests reuse it (the
   server expects several ROUTEs on one connection), created on first use and
   dropped (closed) when the address is deactivated. Guarded by [routing_lock]. *)
let routing_conn cluster addr =
  let key = Addressing.to_string addr in
  match Hashtbl.find_opt cluster.routing key with
  | Some conn -> Ok conn
  | None -> (
      match cluster.connect addr with
      | Error error -> Error error
      | Ok conn ->
          Conn.set_on_error conn (fun conn error -> on_error cluster conn error);
          Hashtbl.add cluster.routing key conn;
          Ok conn)

(* Fetch a fresh routing table for [database], trying each router in turn on a
   reused routing connection: a router that fails to connect, answers ROUTE
   with a non-fatal error or returns a table without routers or readers is
   deactivated and the next router is tried; an error that is fatal during
   discovery ([Errors.is_fatal_during_discovery], e.g. DatabaseNotFound or
   security errors) aborts the fetch immediately. [last_error] carries the most
   recent failure so the caller gets a meaningful error when every router fails.
   [bookmarks] are sent with the ROUTE request (usually the caller's own
   bookmarks, or [] for a plain resolution). ROUTEs are serialized on
   [routing_lock] so concurrent fetches never share a connection. *)
let rec fetch_table_locked cluster ~database ~imp_user ~bookmarks last_error = function
  | [] -> (
      match last_error with
      | Some error -> Error error
      | None -> Error (Errors.Service_unavailable "no router available for routing"))
  | addr :: rest -> (
      match routing_conn cluster addr with
      | Error error ->
          if Errors.is_fatal_during_discovery error then Error error
          else begin
            deactivate cluster addr;
            fetch_table_locked cluster ~database ~imp_user ~bookmarks (Some error) rest
          end
      | Ok conn -> (
          let result =
            match
              Conn.route ?db:database ?imp_user conn ~routing_context:cluster.routing_context
                ~bookmarks
            with
            | Error error -> Error error
            | Ok rt -> (
                match Routing_table.parse rt with
                | Some table -> Ok table
                | None -> Error (Errors.Service_unavailable "unparseable routing table"))
          in
          match result with
          | Ok table when Routing_table.routers table <> [] && Routing_table.readers table <> [] ->
              Ok table
          | Ok _ ->
              deactivate cluster addr;
              fetch_table_locked cluster ~database ~imp_user ~bookmarks
                (Some (Errors.Service_unavailable "invalid routing table")) rest
          | Error error ->
              if Errors.is_fatal_during_discovery error then Error error
              else begin
                deactivate cluster addr;
                fetch_table_locked cluster ~database ~imp_user ~bookmarks (Some error) rest
              end))

let fetch_table cluster ~database ~imp_user ~bookmarks last_error routers =
  with_routing_lock cluster (fun () ->
      fetch_table_locked cluster ~database ~imp_user ~bookmarks last_error routers)

(* The fresh cached table for [database], if any (caller holds the lock). A
   table is fresh only when its TTL has not elapsed AND it still lists routers
   and at least one address for the requested mode — an empty role (e.g. after
   a NotALeader writer removal) forces a refresh. *)
let fresh_table cluster ~database ~mode =
  match Hashtbl.find_opt cluster.tables database with
  | Some (table, fetched_at)
    when elapsed_s cluster fetched_at <= float_of_int (Routing_table.ttl_seconds table) ->
      let role_ok =
        match mode with
        | Config.Read -> Routing_table.readers table <> []
        | Config.Write -> Routing_table.writers table <> []
      in
      if Routing_table.routers table <> [] && role_ok then Some table else None
  | _ -> None

(* A recent fetch failure for [database], if any (caller holds the lock). *)
let cached_error cluster ~database =
  match Hashtbl.find_opt cluster.errors database with
  | Some (error, failed_at) when elapsed_s cluster failed_at <= negative_ttl -> Some error
  | _ -> None

(* Store [table] as the fresh cached routing table for [database], refreshing
   [routers] and clearing a cached fetch error (caller holds the lock). *)
let store_table cluster ~database table =
  Hashtbl.replace cluster.tables database (table, now cluster);
  cluster.routers <- Routing_table.routers table;
  Hashtbl.remove cluster.errors database

(* Apply an [rt] routing table received from the server (SSR) for [database]:
   parse it and, when valid, replace the cached table (fresh timestamp),
   refresh [routers] and clear a cached fetch error. The table's [db] field is
   the server's home database: it is cached for [imp_user] and the table is
   stored under the home database too, so default-database sessions resolve to
   it without a ROUTE. Malformed values are ignored. *)
let update_table cluster ~database ~imp_user rt =
  match Routing_table.parse rt with
  | Some table ->
      with_lock cluster (fun () ->
          (match Routing_table.database table with
          | Some home_db ->
              set_home_db cluster imp_user home_db;
              Hashtbl.replace cluster.tables (Some home_db) (table, now cluster)
          | None -> ());
          store_table cluster ~database table)
  | None -> ()

(* Resolve the routing table for [database]. The lock is held only for the fast
   cache lookup and the single-flight coordination — the actual ROUTE fetch runs
   outside it — and at most one fetch per database is in progress at a time:
   concurrent acquires wait on the condition, then re-check the caches. A recent
   failure is served from the negative cache instead of being re-fetched. *)
let rec resolve_table cluster ~database ~mode ~imp_user ~bookmarks =
  let decision =
    with_lock cluster (fun () ->
        match fresh_table cluster ~database ~mode with
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
  | `Wait -> resolve_table cluster ~database ~mode ~imp_user ~bookmarks
  | `Fetch ->
      (* Fetch outside the lock. Cancellation (e.g. the caller's acquisition
         timeout) still clears the in-flight marker and wakes the waiters. *)
      let routers = fetch_routers cluster in
      let result =
        Fun.protect
          ~finally:(fun () ->
            with_lock cluster (fun () ->
                Hashtbl.remove cluster.in_flight database;
                Eio.Condition.broadcast cluster.cond))
          (fun () -> fetch_table cluster ~database ~imp_user ~bookmarks None routers)
      in
      with_lock cluster (fun () ->
          match result with
          | Ok table -> store_table cluster ~database table
          | Error error -> Hashtbl.replace cluster.errors database (error, now cluster));
      result

(* Select the least-loaded address of the role matching [mode] from a routing
   table (already resolved) and its pool. *)
let select_from_table cluster ~mode table =
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
      | Some addr -> Ok (addr, pool_for cluster addr)
      | None -> Error (Errors.Service_unavailable "routing table has no suitable address"))

(* Resolve the effective database for [database] and the routing table to use:
   a fixed database is used as-is (the effective database equals it); the
   default database is resolved to the server's home database — from the cache
   when fresh (no ROUTE), otherwise from the ROUTE response's [db] field, which
   is then cached for [imp_user]. *)
let resolve_for cluster ~database ~mode ~imp_user ~bookmarks =
  match database with
  | Some _ ->
      let* table = resolve_table cluster ~database ~mode ~imp_user ~bookmarks in
      Ok (table, database)
  | None -> (
      match with_lock cluster (fun () -> home_db_of cluster imp_user) with
      | Some home_db ->
          let* table = resolve_table cluster ~database:(Some home_db) ~mode ~imp_user ~bookmarks in
          Ok (table, Some home_db)
      | None ->
          let* table = resolve_table cluster ~database:None ~mode ~imp_user ~bookmarks in
          (match Routing_table.database table with
          | Some home_db ->
              with_lock cluster (fun () ->
                  set_home_db cluster imp_user home_db;
                  (* The default-database fetch returned the home database's
                     table: store it under the home database too, so a later
                     default-database session (which resolves to it via the
                     cache) reuses it without a ROUTE. *)
                  Hashtbl.replace cluster.tables (Some home_db) (table, now cluster))
          | None -> ());
          Ok (table, Routing_table.database table))

let acquire cluster ~mode ~database ~imp_user ~bookmarks =
  try
    Eio.Time.Timeout.run_exn
      (Eio.Time.Timeout.seconds cluster.clock cluster.pool_config.connection_acquisition_timeout)
      (fun () ->
        let rec attempt () =
          let* table, effective = resolve_for cluster ~database ~mode ~imp_user ~bookmarks in
          let* addr, pool = select_from_table cluster ~mode table in
          match Pool.acquire pool with
          | Ok conn -> Ok (conn, effective)
          | Error (Errors.Service_unavailable _) ->
              (* The server is unreachable: deactivate the address and try
                         the next one (bounded by the acquisition timeout). *)
              deactivate cluster addr;
              attempt ()
          | Error error -> Error error
        in
        attempt ())
  with Eio.Time.Timeout ->
    Error (Errors.Connection_acquisition_timeout "Timed out acquiring a connection")

let release cluster conn =
  match Hashtbl.find_opt cluster.pools (Addressing.to_string (Conn.address conn)) with
  | Some pool -> Pool.release pool conn
  | None -> Conn.close conn

(* The cached routing table for [database], if any (no fetch; read under the
   lock). Test-support API for the TestKit backend's GetRoutingTable. *)
let routing_table_of cluster ~database =
  with_lock cluster (fun () ->
      match Hashtbl.find_opt cluster.tables database with
      | Some (table, _) -> Some table
      | None -> None)

(* Force a fresh fetch of the routing table for [database], bypassing the
   freshness and negative-cache checks, and store it (refreshing [routers] and
   clearing a cached fetch error). Bounded by the acquisition timeout. A failed
   fetch leaves the cluster unchanged apart from a deactivated router.
   Test-support API for the TestKit backend's ForcedRoutingTableUpdate. *)
let force_routing_table_update cluster ~database ~bookmarks =
  try
    Eio.Time.Timeout.run_exn
      (Eio.Time.Timeout.seconds cluster.clock cluster.pool_config.connection_acquisition_timeout)
      (fun () ->
        match
          fetch_table cluster ~database ~imp_user:None ~bookmarks None (fetch_routers cluster)
        with
        | Ok table ->
            with_lock cluster (fun () -> store_table cluster ~database table);
            Ok ()
        | Error _ as error -> error)
  with Eio.Time.Timeout ->
    Error (Errors.Connection_acquisition_timeout "Timed out updating the routing table")

let close cluster =
  with_lock cluster (fun () ->
      Hashtbl.iter (fun _ pool -> Pool.close pool) cluster.pools;
      Hashtbl.iter (fun _ conn -> Conn.close conn) cluster.routing)
