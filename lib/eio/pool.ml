(* A bounded connection pool for a single address.

   Connections are created on demand (up to [max_connection_pool_size]),
   reused while idle (checked against the max lifetime and, when configured,
   liveness-checked with a RESET) and returned to the pool with a RESET on
   release. An [acquire] that cannot obtain a connection within the
   [connection_acquisition_timeout] fails with
   [Errors.Connection_acquisition_timeout].

   Address-level deactivation (closing the connections of a failed server) is
   deferred to routing (phase A7); at the connection level it is handled here:
   a connection that comes back in the [Failed] state, or whose RESET fails,
   is closed rather than reused. *)

open Neodriver_core

type t = {
  connect : unit -> (Conn.t, Errors.t) result;
  pool_config : Config.pool_config;
  acquisition_timeout : float;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  mutex : Eio.Mutex.t;
  idle : (Conn.t * Mtime.t) Queue.t;
  permits : Eio.Semaphore.t;
  mutable closed : bool;
}

let create ~pool_config ~connect clock =
  {
    connect;
    pool_config;
    acquisition_timeout = pool_config.connection_acquisition_timeout;
    clock;
    mutex = Eio.Mutex.create ();
    idle = Queue.create ();
    permits = Eio.Semaphore.make pool_config.max_connection_pool_size;
    closed = false;
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
        Conn.close conn;
        take_idle t)

let acquire t =
  if t.closed then Error (Errors.Connection_pool_error "Pool is closed")
  else
    let permit =
      try
        Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds t.clock t.acquisition_timeout) (fun () ->
            Eio.Semaphore.acquire t.permits;
            Ok ())
      with Eio.Time.Timeout ->
        Error (Errors.Connection_acquisition_timeout "Timed out waiting for a free connection")
    in
    match permit with
    | Error _ as error -> error
    | Ok () -> (
        match take_idle t with
        | Some conn -> Ok conn
        | None -> (
            match t.connect () with
            | Ok conn -> Ok conn
            | Error _ as error ->
                Eio.Semaphore.release t.permits;
                error))

(* Hand an already-established connection to the pool as an idle connection,
   without acquiring a permit (the connection never held one). Used to recycle
   a routing connection whose server also serves data (the routing fetch and a
   subsequent data query then share one connection, as the server expects).
   When the pool is closed the connection is dropped. *)
let put_conn t conn =
  with_lock t.mutex (fun () ->
      if t.closed then Conn.close conn else Queue.push (conn, now t) t.idle)

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
    Eio.Semaphore.release t.permits
  end
  else begin
    let reusable =
      if Conn.is_failed conn then match Conn.reset conn with Ok () -> true | Error _ -> false
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
    | `Keep -> Eio.Semaphore.release t.permits
    | `Close ->
        Conn.close conn;
        Eio.Semaphore.release t.permits
  end

let close t =
  with_lock t.mutex (fun () ->
      t.closed <- true;
      Queue.iter (fun (conn, _) -> Conn.close conn) t.idle;
      Queue.clear t.idle)
