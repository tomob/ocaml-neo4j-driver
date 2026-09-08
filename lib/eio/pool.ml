(* A bounded connection pool for a single address.

   Connections are created on demand (up to [max_connection_pool_size]),
   reused while idle (checked against the max lifetime and, when configured,
   liveness-checked with a RESET once they have been idle for at least the
   liveness timeout) and returned to the pool on release. An [acquire] that
   cannot obtain a connection within the
   [connection_acquisition_timeout] fails with
   [Errors.Connection_acquisition_timeout] — the timeout is a single deadline
   for the whole acquisition, covering not only waiting for a free connection
   but also establishing a new one (TCP connect + Bolt handshake + HELLO/auth)
   when none is idle: the pool's connect runs inside the deadline, so a slow
   server counts against the acquisition budget (and the socket connection
   timeout never short-circuits a handshake that fits in it).

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
  connect : Auth_manager.token option -> (Conn.t, Errors.t) result;
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

(* The number of idle connections waiting to be reused. Test-support accessor
   (the backend's GetConnectionPoolMetrics). *)
let idle_count t = with_lock t.mutex (fun () -> Queue.length t.idle)

(* Whether a connection has been idle longer than the max lifetime (the idle
   queue stamps when the connection was released). *)
let over_lifetime t idle_since =
  let age = Mtime.span (now t) idle_since in
  Mtime.Span.to_float_ns age >= t.pool_config.max_connection_lifetime *. 1_000_000_000.

(* How long the connection has been idle, in seconds. *)
let idle_seconds t idle_since =
  Mtime.Span.to_float_ns (Mtime.span (now t) idle_since) /. 1_000_000_000.

(* Liveness-check an idle connection on reuse. With [force] (a one-shot
   driver-level acquire such as GetServerInfo, which must see a clean
   connection — the Python driver passes [liveness_check_timeout = 0] there) or
   when the connection has been idle for at least the configured
   [liveness_check_timeout], probe it with a RESET bounded by that timeout;
   a connection idle for less is reused as-is (MinimalResets). On failure the
   connection is closed. *)
let liveness_ok t ~force ~idle_since conn =
  match (force, t.pool_config.liveness_check_timeout) with
  | true, _ -> Stdlib.Result.is_ok (Conn.reset conn)
  | false, Some timeout -> (
      if idle_seconds t idle_since < timeout then true
      else
        try
          Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds t.clock timeout) (fun () ->
              Conn.reset conn)
          |> Stdlib.Result.is_ok
        with _ -> false)
  | false, None -> true

(* Pop a reusable connection off the idle queue, closing any that are over
   their lifetime or fail the liveness check. *)
let rec take_idle t ~force_liveness =
  let reusable =
    with_lock t.mutex (fun () ->
        let rec go () =
          if Queue.is_empty t.idle then None
          else
            let conn, idle_since = Queue.pop t.idle in
            if over_lifetime t idle_since then begin
              Conn.close conn;
              go ()
            end
            else Some (conn, idle_since)
        in
        go ())
  in
  match reusable with
  | None -> None
  | Some (conn, idle_since) ->
      if liveness_ok t ~force:force_liveness ~idle_since conn then Some conn
      else (
        Log.debug Log.pool (fun m ->
            m "[#%04X]  _: <POOL> found unhealthy connection" (Conn.id conn));
        Conn.close conn;
        take_idle t ~force_liveness)

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
   and a [Neo.ClientError.Security.*] error is offered to the connection's own
   auth manager — the pool's for driver auth, a static manager over the session
   token for a session-auth connection (which never handles, like the Python
   driver). A handled error is marked retryable, a provider failure replaces
   it. Without an auth manager the error passes through unchanged. The token
   used when the server rejected the request is captured before the
   AuthorizationExpired mark clears the connections' current tokens. *)
let on_neo4j_error t conn error =
  let failed_auth = Conn.current_auth conn in
  if Errors.unauthenticates_all_connections error then begin
    Log.debug Log.pool (fun m ->
        m "[#%04X]  _: <POOL> mark all connections as unauthenticated" (Conn.id conn));
    mark_all_unauthenticated t
  end;
  if Errors.has_security_code error then
    match Conn.auth_manager conn with
    | None -> error
    | Some manager -> (
        match failed_auth with
        | None -> error
        | Some auth -> (
            match manager.handle_security_exception auth error with
            | Ok true -> Errors.make_retryable error
            | Ok false -> error
            | Error provider_error -> provider_error))
  else error

(* Re-authenticate [conn] to [token] when it differs from the one it is logged
   on with (or when it was marked unauthenticated). With [force] it re-authenticates
   even when the token is unchanged (the Python driver's verify_authentication
   forces a LOGOFF/LOGON so the server re-checks the credentials). A
   [Configuration_error] means the protocol version cannot re-authenticate an
   existing connection (Bolt < 5.1). *)
let re_auth_to ?(force = false) token conn =
  if (not force) && Conn.same_auth conn token then Ok ()
  else if not (Conn.capabilities conn).supports_re_auth then
    Error (Errors.Configuration_error "Re-authentication is not supported by this protocol version")
  else Conn.re_auth ~force conn token |> Result.map (fun _ -> ())

(* Re-authenticate [conn] on acquire: with a session token [session_auth] it is
   re-authenticated to it; without one the pool's auth manager's current token
   is used. Without an auth manager and without a session token nothing is
   done. [force] re-authenticates a reused connection even with an unchanged
   token (see [re_auth_to]). *)
let re_auth t conn session_auth ~force =
  match session_auth with
  | Some token -> re_auth_to ~force token conn
  | None -> (
      match t.auth_manager with
      | None -> Ok ()
      | Some manager ->
          let* token = manager.get_auth () in
          re_auth_to token conn)

(* Install the connection's auth manager: the pool's for driver auth; a static
   manager over the session token for a session-auth connection, so security
   errors are not offered to the driver's manager (like the Python driver,
   which sets the connection's auth_manager to the session's static manager via
   [re_auth]). *)
let set_conn_auth_manager t session_auth conn =
  match session_auth with
  | Some token -> Conn.set_auth_manager conn (Auth_manager.static token)
  | None -> Option.iter (fun manager -> Conn.set_auth_manager conn manager) t.auth_manager

(* Acquire the pool's permit and hand out a connection (see [acquire]). The
   permit stays held on success (it belongs to the checked-out connection) and
   is released by the caller when [acquire_loop] reports a failure or the
   acquire is aborted. A reused connection that cannot re-authenticate because
   the protocol lacks re-authentication (Bolt < 5.1) is purged and the acquire
   retried — the latter only for the driver's own auth: a session-level auth
   unsupported by the protocol is surfaced instead. *)
let rec acquire_loop t session_auth ~force_liveness ~force_auth =
  match take_idle t ~force_liveness with
  | Some conn -> (
      add_live t conn;
      match re_auth t conn session_auth ~force:force_auth with
      | Ok () ->
          set_conn_auth_manager t session_auth conn;
          Ok conn
      | Error (Errors.Configuration_error _) when session_auth = None ->
          Log.debug Log.pool (fun m ->
              m "[#%04X]  _: <POOL> backwards compatible auth token refresh: purge connection"
                (Conn.id conn));
          remove_live t conn;
          Conn.close conn;
          acquire_loop t session_auth ~force_liveness ~force_auth
      | Error error ->
          remove_live t conn;
          Conn.close conn;
          Error error)
  | None -> (
      Log.debug Log.pool (fun m -> m "[#0000]  _: <POOL> trying to hand out new connection");
      match t.connect session_auth with
      | Ok conn -> (
          (* New connections are opened with the session token when provided,
             otherwise with the manager's current token; the auth-manager and
             security-error hooks are installed before the connection is handed
             out, chained after any hook the cluster already installed (address
             deactivation). *)
          set_conn_auth_manager t session_auth conn;
          let previous = Conn.on_error conn in
          Conn.set_on_error conn (fun conn error -> on_neo4j_error t conn (previous conn error));
          add_live t conn;
          match session_auth with
          | Some _ when not (Conn.capabilities conn).supports_re_auth ->
              (* Session-level auth requires re-authentication support (Bolt >=
                 5.1): the connection was opened with the session token but
                 future switches are impossible. *)
              remove_live t conn;
              Conn.close conn;
              Error
                (Errors.Configuration_error
                   "Re-authentication is not supported by this protocol version")
          | _ -> Ok conn)
      | Error _ as error -> error)

let acquire ?(force_auth = false) ~session_auth ~force_liveness t =
  if t.closed then Error (Errors.Connection_pool_error "Pool is closed")
  else
    (* One acquisition-timeout deadline bounds the whole acquire: waiting for a
       permit AND, when none is idle, establishing a new connection (TCP +
       handshake + auth — [connect] runs in this deadline). The permit is
       released whenever the acquire does not hand out a connection: on a
       connect failure, on the deadline firing mid-connect, or when an
       enclosing deadline (a routed driver's cluster acquire) cancels this one.
       The deadline is [Eio.Time.Timeout.run_exn]: its own expiry surfaces as
       [Eio.Time.Timeout], while an enclosing region's cancellation propagates
       as a [Eio.Cancel.Cancelled] — either way the held permit is returned. *)
    let held = ref false in
    let release_permit () =
      if !held then begin
        held := false;
        Eio.Semaphore.release t.permits
      end
    in
    let outcome =
      try
        Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds t.clock t.acquisition_timeout) (fun () ->
            Eio.Semaphore.acquire t.permits;
            held := true;
            acquire_loop t session_auth ~force_liveness ~force_auth)
      with
      | Eio.Time.Timeout ->
          release_permit ();
          Log.debug Log.pool (fun m -> m "[#0000]  _: <POOL> acquisition timed out");
          Error (Errors.Connection_acquisition_timeout "Timed out waiting for a free connection")
      | exn ->
          release_permit ();
          raise exn
    in
    match outcome with
    | Ok conn -> Ok conn
    | Error error ->
        release_permit ();
        Error error

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
