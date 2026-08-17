(* Per-session connection with auto-commit queries, explicit and managed
   transactions. See session.mli. *)

open Neodriver_core
open Neodriver_packstream

let ( let* ) = Result.bind

type failure = Driver of Errors.t | Client

type config = {
  database : string option;
  access_mode : Config.access_mode;
  impersonated_user : string option;
  fetch_size : int option;
  bookmarks : string list;
  max_transaction_retry_time : float;
  initial_retry_delay : float;
  retry_delay_multiplier : float;
  retry_delay_jitter_factor : float;
}

let default_config =
  {
    database = None;
    access_mode = Config.default_access_mode;
    impersonated_user = None;
    fetch_size = None;
    bookmarks = [];
    max_transaction_retry_time = 30.0;
    initial_retry_delay = 1.0;
    retry_delay_multiplier = 2.0;
    retry_delay_jitter_factor = 0.2;
  }

(* A session: its lazy connection, bookmarks, current transaction and the
   pending auto-commit result stream. [connect] acquires the session's
   connection (from a pool, or by connecting directly) and reports the
   effective database actually used (the resolved home database for a
   default-database routed session); [release] returns it on [close] (back to
   the pool, or by closing it). *)
type t = {
  config : config;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  connect :
    mode:Config.access_mode ->
    database:string option ->
    bookmarks:string list ->
    (Conn.t * string option, Errors.t) result;
  release : Conn.t -> unit;
  on_rt : string option -> Packstream.value -> unit;
  database : string option ref;
  conn : (Conn.t * Config.access_mode) option ref;
  bookmarks : string list ref;
  current_tx : Tx.t option ref;
  auto_result : Conn.stream option ref;
}

let create config ~clock ~connect ?(release = Conn.close) ?(on_rt = fun _ _ -> ()) () =
  {
    config;
    clock;
    connect;
    release;
    on_rt;
    database = ref config.database;
    conn = ref None;
    bookmarks = ref config.bookmarks;
    current_tx = ref None;
    auto_result = ref None;
  }

(* The session's connection for [mode], connecting on first use. A cached
   connection acquired for a different access mode (e.g. a read managed
   transaction on a write-mode session) is returned to the pool and re-acquired
   for [mode]. *)
let rec conn_for_mode (t : t) ~mode =
  match !(t.conn) with
  | Some (conn, cached_mode) when cached_mode = mode -> Ok conn
  | Some (conn, _) ->
      (match !(t.auto_result) with Some previous -> Conn.drain_stream previous | None -> ());
      t.auto_result := None;
      t.conn := None;
      t.release conn;
      conn_for_mode t ~mode
  | None -> (
      match t.connect ~mode ~database:!(t.database) ~bookmarks:!(t.bookmarks) with
      | Error _ as error -> error
      | Ok (conn, effective) ->
          (* The connection may resolve the session's database (a routed
             default-database session learns its home database here); the
             effective database is used for RUN/BEGIN from now on. *)
          t.database := effective;
          t.conn := Some (conn, mode);
          Ok conn)

(* The session's current connection (session access mode). Returns the cached
   connection whatever mode it was acquired for: a transaction in flight owns
   it, and callers must not yank it away by asking for a different mode. *)
let conn t =
  match !(t.conn) with
  | Some (conn, _) -> Ok conn
  | None -> conn_for_mode t ~mode:t.config.access_mode

(* Update the session's bookmarks from an auto-commit PULL summary. *)
let mark_bookmark t = function
  | Packstream.Map fields -> (
      match List.assoc_opt "bookmark" fields with
      | Some (Packstream.String b) -> t.bookmarks := [ b ]
      | _ -> ())
  | _ -> ()

let now t = Eio.Time.Mono.now t.clock
let elapsed_s t t0 = Mtime.Span.to_float_ns (Mtime.span (now t) t0) /. 1_000_000_000.

(* The jittered backoff delays of the Python driver's retry_delay_generator. *)
let retry_delay_generator config =
  let delay = ref config.initial_retry_delay in
  fun () ->
    let jitter = config.retry_delay_jitter_factor *. !delay in
    let value = !delay -. jitter +. (2. *. jitter *. Random.float 1.0) in
    delay := !delay *. config.retry_delay_multiplier;
    value

let run ?timeout ?metadata t ~query ~parameters =
  let* conn = conn t in
  (* A new auto-commit query cannot start while the previous result is still
     streaming on the connection: drain it first (like the Python driver's
     consume of the auto result). Draining fires the stream's on_complete
     hook, which records the auto-commit bookmark. *)
  (match !(t.auto_result) with Some previous -> Conn.drain_stream previous | None -> ());
  let hydration = Conn.hydration conn in
  let* run_metadata =
    Conn.run conn ~mode:t.config.access_mode ~hydration ~query ~parameters ~bookmarks:!(t.bookmarks)
      ?db:!(t.database) ?timeout ?metadata
  in
  (* Server-side routing: when the server advertised [ssr.enabled] and answered
     RUN with an [rt] routing table, hand it to the on_rt callback (the routing
     cluster of a routed driver updates its table). The callback gets the
     session's effective database, so SSR tables land under the resolved key. *)
  (if Conn.ssr_enabled conn then
     match run_metadata.rt with Some rt -> t.on_rt !(t.database) rt | None -> ());
  let stream =
    Conn.stream conn ~hydration ~run_metadata ~on_complete:(fun summary -> mark_bookmark t summary)
  in
  t.auto_result := Some stream;
  Ok (Neo4j_result.make ?fetch_size:t.config.fetch_size ~query ~parameters stream)

let begin_transaction_mode ?metadata ?timeout t ~mode =
  match !(t.current_tx) with
  | Some tx when not (Tx.closed tx) ->
      Error (Errors.Transaction_error "Explicit transaction already open")
  | _ -> (
      let* conn = conn_for_mode t ~mode in
      let hydration = Conn.hydration conn in
      let metadata =
        Option.map (List.map (fun (k, v) -> (k, Hydration.dehydrate hydration v))) metadata
      in
      let extra =
        Conn.build_extra ~mode ?db:!(t.database) ?imp_user:t.config.impersonated_user ?timeout
          ?metadata ~bookmarks:!(t.bookmarks) ()
      in
      match Tx.begin_transaction conn ~extra with
      | Ok tx ->
          t.current_tx := Some tx;
          Ok tx
      | Error _ as error ->
          (* A failed BEGIN (e.g. a connection-level error on a connection whose
             server has gone away) leaves the connection unusable: drop it so
             the next operation reconnects instead of reusing it. *)
          (match error with
          | Ok _ -> ()
          | Error (Errors.Neo4j _) -> ()
          | Error _ ->
              t.conn := None;
              t.release conn);
          error)

let begin_transaction ?metadata ?timeout t =
  begin_transaction_mode ?metadata ?timeout t ~mode:t.config.access_mode

let last_bookmarks t = !(t.bookmarks)

(* The session's transaction has ended: record [bookmark] (if any) and forget
   the current transaction so a new one can begin. *)
let mark_tx_ended t ~bookmark =
  (match bookmark with Some b -> t.bookmarks := [ b ] | None -> ());
  t.current_tx := None

let execute t ~mode ?metadata ?timeout work =
  let t0 = now t in
  let delay = retry_delay_generator t.config in
  let within_budget () = elapsed_s t t0 <= t.config.max_transaction_retry_time in
  let retry () = Eio.Time.Mono.sleep t.clock (delay ()) in
  let begin_tx () =
    match begin_transaction_mode ?metadata ?timeout t ~mode with
    | Ok tx -> Ok tx
    | Error error -> Error (Driver error)
  in
  (* Managed transactions use a connection acquired for the transaction's
     access mode and return it to the pool after every attempt: a retry
     therefore acquires a fresh connection, re-resolving the routing table (a
     failed writer/reader was deactivated, so the next ROUTE skips it). Any
     pending auto-commit stream is drained first. *)
  let reconnect () =
    (match !(t.auto_result) with Some previous -> Conn.drain_stream previous | None -> ());
    t.auto_result := None;
    match !(t.conn) with
    | None -> ()
    | Some (conn, _) ->
        t.conn := None;
        t.release conn
  in
  let rec attempt () =
    match begin_tx () with
    | Ok tx -> (
        match work tx with
        | Ok () -> (
            match Tx.commit tx with
            | Ok bookmark ->
                (match bookmark with Some b -> t.bookmarks := [ b ] | None -> ());
                t.current_tx := None;
                reconnect ();
                Ok ()
            | Error error ->
                ignore (Tx.rollback tx);
                t.current_tx := None;
                reconnect ();
                if Errors.is_retryable error && within_budget () then (
                  retry ();
                  attempt ())
                else Error (Driver error))
        | Error Client ->
            ignore (Tx.rollback tx);
            t.current_tx := None;
            reconnect ();
            Error Client
        | Error (Driver error) ->
            ignore (Tx.rollback tx);
            t.current_tx := None;
            reconnect ();
            if Errors.is_retryable error && within_budget () then (
              retry ();
              attempt ())
            else Error (Driver error))
    | Error (Driver error) when Errors.is_retryable error && within_budget () ->
        (* Acquiring the connection failed (e.g. no address available for the
           mode): retry without running the unit of work. *)
        reconnect ();
        retry ();
        attempt ()
    | Error _ as error -> error
  in
  attempt ()

let close (t : t) =
  !(t.current_tx) |> Option.iter (fun tx -> ignore (Tx.close tx));
  t.current_tx := None;
  match !(t.conn) with
  | Some (conn, _) ->
      t.conn := None;
      t.release conn
  | None -> ()
