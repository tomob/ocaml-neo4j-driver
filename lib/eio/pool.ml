(* A bounded connection pool for a single address.

   Connections are created on demand (up to [max_connection_pool_size]),
   reused while idle (checked against the max lifetime and, when configured,
   liveness-checked with a RESET) and returned to the pool with a RESET on
   release. An [acquire] that cannot obtain a connection within the
   [connection_acquisition_timeout] fails with
   [Errors.Connection_acquisition_timeout].

   Auth: the pool owns the driver's auth manager. New connections
   resolve their initial token from it at connect time; a reused connection is
   re-authenticated (LOGOFF + LOGON, Bolt >= 5.1) when the manager's token
   differs from the one it is logged on with — or when it was marked
   unauthenticated. On a protocol version that cannot re-authenticate the
   connection is purged and the acquire retried (the Python driver's
   "backwards compatible auth token refresh" path). A server security error on
   a pooled connection is handled here: an [AuthorizationExpired] marks every
   connection unauthenticated (they re-authenticate on their next acquire) and
   a [Neo.ClientError.Security.*] error is offered to the manager, which may
   mark it retryable.

   Address-level deactivation (closing the connections of a failed server) is
   deferred to routing (phase A7); at the connection level it is handled here:
   a connection that comes back in the [Failed] state, or whose RESET fails,
   is closed rather than reused. *)

open Neodriver_core

let ( let* ) = Result.bind

type t = {
  connect : unit -> (Conn.t, Errors.t) result;
  pool_config : Config.pool_config;
  acquisition_timeout : float;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  mutex : Eio.Mutex.t;
  idle : (Conn.t * Mtime.t) Queue.t;
  permits : Eio.Semaphore.t;
  mutable closed : bool;
  auth_manager : Auth_manager.t option;
  live : Conn.t list ref;
}

let create ~pool_config ?(auth_manager : Auth_manager.t option = None) ~connect clock =
  {
    connect;
    pool_config;
    acquisition_timeout = pool_config.connection_acquisition_timeout;
    clock;
    mutex = Eio.Mutex.create ();
    idle = Queue.create ();
    permits = Eio.Semaphore.make pool_config.max_connection_pool_size;
    closed = false;
    auth_manager;
    live = ref [];
  }

let now t = Eio.Time.Mono.now t.clock

(* The number of connections currently checked out: every checked-out connection
   holds exactly one permit, so it is the pool bound minus the available permits. *)
let in_use_count t = t.pool_config.max_connection_pool_size - Eio.Semaphore.get_value t.permits

let with_lock m f =
  Eio.Mutex.lock m;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock m) f

(* Whether a connection has been alive longer than the max lifetime. *)
let over_lifetime t created_at =
  let age = Mtime.span (now t) created_at in
  Mtime.Span.to_float_ns age >= t.pool_config.max_connection_lifetime *. 1_000_000_000.

(* Liveness-check an idle connection: send a RESET (bounded by the configured
   timeout when set), like the Python driver which resets a connection lazily
   when it is reused. On failure the connection is closed. *)
let liveness_ok t conn =
  match t.pool_config.liveness_check_timeout with
  | Some timeout -> (
      try
        Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds t.clock timeout) (fun () ->
            Conn.reset conn)
        |> Stdlib.Result.is_ok
      with _ -> false)
  | None -> Result.is_ok (Conn.reset conn)

(* Pop a reusable connection off the idle queue, closing any that are over
   their lifetime or fail the liveness check. *)
let rec take_idle t =
  let reusable =
    with_lock t.mutex (fun () ->
        let rec go () =
          if Queue.is_empty t.idle then None
          else
            let conn, created_at = Queue.pop t.idle in
            if over_lifetime t created_at then begin
              Conn.close conn;
              go ()
            end
            else Some conn
        in
        go ())
  in
  match reusable with
  | None -> None
  | Some conn ->
      if liveness_ok t conn then Some conn
      else (
        Log.debug Log.pool (fun m ->
            m "[#%04X]  _: <POOL> found unhealthy connection" (Conn.id conn));
        Conn.close conn;
        take_idle t)

(* --- Auth --- *)

(* Track a connection as part of the pool's live set (idle or checked out), so
   an AuthorizationExpired can mark every one of them unauthenticated. *)
let add_live t conn =
  with_lock t.mutex (fun () ->
      if not (List.exists (fun c -> c == conn) !(t.live)) then t.live := conn :: !(t.live))

let remove_live t conn =
  with_lock t.mutex (fun () -> t.live := List.filter (fun c -> c != conn) !(t.live))

(* Clear the current token of every connection (AuthorizationExpired): each one
   re-authenticates on its next acquire. *)
let mark_all_unauthenticated t =
  with_lock t.mutex (fun () -> List.iter Conn.mark_unauthenticated !(t.live))

(* Handle a server security error reported by one of the pool's connections
   (installed as the connection's on-error hook): an AuthorizationExpired
   invalidates every connection (they re-authenticate on their next acquire),
   and a [Neo.ClientError.Security.*] error is offered to the pool's auth
   manager — a handled error is marked retryable, a provider failure replaces
   it. Without an auth manager the error passes through unchanged. *)
let on_neo4j_error t conn error =
  if Errors.unauthenticates_all_connections error then begin
    Log.debug Log.pool (fun m ->
        m "[#%04X]  _: <POOL> mark all connections as unauthenticated" (Conn.id conn));
    mark_all_unauthenticated t
  end;
  if Errors.has_security_code error then
    match t.auth_manager with
    | None -> error
    | Some manager -> (
        match Conn.current_auth conn with
        | None -> error
        | Some auth -> (
            match manager.handle_security_exception auth error with
            | Ok true -> Errors.make_retryable error
            | Ok false -> error
            | Error provider_error -> provider_error))
  else error

(* Re-authenticate [conn] when the manager's token differs from the one it is
   logged on with (or when it was marked unauthenticated). Without an auth
   manager nothing is done. A [Configuration_error] means the protocol version
   cannot re-authenticate an existing connection (Bolt < 5.1): the caller
   purges it (see [acquire]). *)
let re_auth_connection t conn =
  match t.auth_manager with
  | None -> Ok ()
  | Some manager ->
      let* token = manager.get_auth () in
      let same =
        match Conn.current_auth conn with
        | Some current -> Auth_manager.eq current token
        | None -> false
      in
      if same then Ok ()
      else if not (Conn.capabilities conn).supports_re_auth then
        Error
          (Errors.Configuration_error "Re-authentication is not supported by this protocol version")
      else Conn.re_auth conn token |> Result.map (fun _ -> ())

let rec acquire t =
  if t.closed then Error (Errors.Connection_pool_error "Pool is closed")
  else
    let permit =
      try
        Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds t.clock t.acquisition_timeout) (fun () ->
            Eio.Semaphore.acquire t.permits;
            Ok ())
      with Eio.Time.Timeout ->
        Log.debug Log.pool (fun m -> m "[#0000]  _: <POOL> acquisition timed out");
        Error (Errors.Connection_acquisition_timeout "Timed out waiting for a free connection")
    in
    match permit with Error _ as error -> error | Ok () -> acquire_loop t

(* A permit is held: hand out a connection, re-authenticating a reused one and
   purging (and retrying) connections whose protocol cannot re-authenticate. *)
and acquire_loop t =
  match take_idle t with
  | Some conn -> (
      add_live t conn;
      match re_auth_connection t conn with
      | Ok () -> Ok conn
      | Error (Errors.Configuration_error _) ->
          Log.debug Log.pool (fun m ->
              m "[#%04X]  _: <POOL> backwards compatible auth token refresh: purge connection"
                (Conn.id conn));
          remove_live t conn;
          Conn.close conn;
          acquire_loop t
      | Error error ->
          remove_live t conn;
          Conn.close conn;
          Eio.Semaphore.release t.permits;
          Error error)
  | None -> (
      Log.debug Log.pool (fun m -> m "[#0000]  _: <POOL> trying to hand out new connection");
      match t.connect () with
      | Ok conn ->
          (* New connections resolve their initial token from the manager at
             connect time; the auth-manager and security-error hooks are
             installed before the connection is handed out, chained after any
             hook the cluster already installed (address deactivation). *)
          Option.iter (fun manager -> Conn.set_auth_manager conn manager) t.auth_manager;
          let previous = Conn.on_error conn in
          Conn.set_on_error conn (fun conn error -> on_neo4j_error t conn (previous conn error));
          add_live t conn;
          Ok conn
      | Error _ as error ->
          Eio.Semaphore.release t.permits;
          error)

(* Hand an already-established connection to the pool as an idle connection,
   without acquiring a permit (the connection never held one). Used to recycle
   a routing connection whose server also serves data (the routing fetch and a
   subsequent data query then share one connection, as the server expects).
   When the pool is closed the connection is dropped. *)
let put_conn t conn =
  with_lock t.mutex (fun () ->
      if t.closed then Conn.close conn
      else begin
        if not (List.exists (fun c -> c == conn) !(t.live)) then t.live := conn :: !(t.live);
        Queue.push (conn, now t) t.idle
      end)

(* Return [conn] to the pool. A second release of the same connection (already
   idle) is a no-op: it is not queued again and no permit is released, so the
   permit count cannot exceed [max_connection_pool_size]. A connection left in
   the FAILED state (a request answered with a FAILURE) is recovered with a
   RESET here, like the Python driver's release (which resets anything not
   already clean); a connection whose RESET fails (unreachable server) is
   closed. Clean connections are released without a RESET — the reset is sent
   lazily when the next acquire reuses one. *)
let release t conn =
  if t.closed then begin
    Conn.close conn;
    remove_live t conn;
    Eio.Semaphore.release t.permits
  end
  else begin
    let reusable =
      if Conn.is_failed conn then (
        match Conn.reset conn with
        | Ok () -> true
        | Error _ ->
            Log.debug Log.pool (fun m ->
                m "[#%04X]  _: <POOL> failed to reset connection on release" (Conn.id conn));
            false)
      else true
    in
    let outcome =
      with_lock t.mutex (fun () ->
          if t.closed then `Close
          else if Queue.fold (fun found (c, _) -> found || c == conn) false t.idle then `Skip
          else if reusable then begin
            Queue.push (conn, now t) t.idle;
            `Keep
          end
          else `Close)
    in
    match outcome with
    | `Skip -> ()
    | `Keep ->
        Log.debug Log.pool (fun m -> m "[#%04X]  _: <POOL> released" (Conn.id conn));
        Eio.Semaphore.release t.permits
    | `Close ->
        Log.debug Log.pool (fun m ->
            m "[#%04X]  _: <POOL> remove connection from pool" (Conn.id conn));
        remove_live t conn;
        Conn.close conn;
        Eio.Semaphore.release t.permits
  end

let close t =
  Log.debug Log.pool (fun m -> m "[#0000]  _: <POOL> close");
  with_lock t.mutex (fun () ->
      t.closed <- true;
      Queue.iter (fun (conn, _) -> Conn.close conn) t.idle;
      Queue.clear t.idle;
      t.live := [])
