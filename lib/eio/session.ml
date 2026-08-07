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

(* A lazily-streamed auto-commit query result: RUN is sent immediately, records
   are pulled in batches on demand. [records] is kept in reverse for O(1)
   prepend; the terminal state is a [summary] (normal end) or an [error]
   (a server failure, surfaced after the buffered records are consumed). *)
type stream = {
  run_metadata : Conn.run_metadata;
  conn : Conn.t;
  hydration : Hydration.t;
  session : t;
  mutable records : Values.t list list;
  mutable summary : Packstream.value option;
  mutable error : Errors.t option;
  mutable has_more : bool;
}

and t = {
  config : config;
  clock : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  connect : unit -> (Conn.t, Errors.t) result;
  conn : Conn.t option ref;
  bookmarks : string list ref;
  current_tx : Tx.t option ref;
  auto_result : stream option ref;
}

let create config ~clock ~connect =
  {
    config;
    clock;
    connect;
    conn = ref None;
    bookmarks = ref config.bookmarks;
    current_tx = ref None;
    auto_result = ref None;
  }

let conn (t : t) =
  match !(t.conn) with
  | Some conn -> Ok conn
  | None -> (
      match t.connect () with
      | Error _ as error -> error
      | Ok conn ->
          t.conn := Some conn;
          Ok conn)

let summary_string key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with Some (Packstream.String v) -> Some v | _ -> None)
  | _ -> None

let buffered result = List.rev result.records
let has_more result = result.has_more
let error result = result.error
let summary result = result.summary
let run_metadata result = result.run_metadata

let pull ?n result =
  if not result.has_more then Ok []
  else
    match Conn.pull ?n ?qid:result.run_metadata.qid result.conn ~hydration:result.hydration with
    | Error _ as error -> error
    | Ok (records, outcome) -> (
        result.records <- List.rev_append records result.records;
        match outcome with
        | Error error ->
            result.has_more <- false;
            result.error <- Some error;
            Ok records
        | Ok summary ->
            let more = Bolt.metadata_has_more summary in
            result.has_more <- more;
            if not more then begin
              result.summary <- Some summary;
              (* The bookmark of an auto-commit transaction is reported in the
                 final PULL summary. *)
              match summary_string "bookmark" summary with
              | Some b -> result.session.bookmarks := [ b ]
              | None -> ()
            end;
            Ok records)

(* Drain an auto-commit result to its end (a server failure is left on the
   result; the connection is recovered by the next request's RESET). *)
let rec drain result =
  if result.has_more then match pull result with Ok _ -> drain result | Error _ -> ()

let run ?timeout ?metadata t ~query ~parameters =
  let* conn = conn t in
  (* A new auto-commit query cannot start while the previous result is still
     streaming on the connection: drain it first (like the Python driver's
     consume of the auto result). *)
  (match !(t.auto_result) with Some previous -> drain previous | None -> ());
  let hydration = Conn.hydration conn in
  let* run_metadata =
    Conn.run conn ~hydration ~query ~parameters ~bookmarks:!(t.bookmarks) ?db:t.config.database
      ?timeout ?metadata
  in
  let stream =
    {
      run_metadata;
      conn;
      hydration;
      session = t;
      records = [];
      summary = None;
      error = None;
      has_more = true;
    }
  in
  t.auto_result := Some stream;
  Ok stream

let begin_transaction_mode ?metadata ?timeout t ~mode =
  match !(t.current_tx) with
  | Some tx when not (Tx.closed tx) ->
      Error (Errors.Transaction_error "Explicit transaction already open")
  | _ -> (
      let* conn = conn t in
      let hydration = Conn.hydration conn in
      let metadata =
        Option.map (List.map (fun (k, v) -> (k, Hydration.dehydrate hydration v))) metadata
      in
      let extra =
        Conn.build_extra ~mode ?db:t.config.database ?imp_user:t.config.impersonated_user ?timeout
          ?metadata ~bookmarks:!(t.bookmarks) ()
      in
      match Tx.begin_transaction conn ~extra with
      | Error _ as error -> error
      | Ok tx ->
          t.current_tx := Some tx;
          Ok tx)

let begin_transaction ?metadata ?timeout t =
  begin_transaction_mode ?metadata ?timeout t ~mode:t.config.access_mode

let last_bookmarks t = !(t.bookmarks)

(* The session's transaction has ended: record [bookmark] (if any) and forget
   the current transaction so a new one can begin. *)
let mark_tx_ended t ~bookmark =
  (match bookmark with Some b -> t.bookmarks := [ b ] | None -> ());
  t.current_tx := None

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
  let rec attempt () =
    let* tx = begin_tx () in
    match work tx with
    | Ok () -> (
        match Tx.commit tx with
        | Ok bookmark ->
            (match bookmark with Some b -> t.bookmarks := [ b ] | None -> ());
            t.current_tx := None;
            Ok ()
        | Error error ->
            ignore (Tx.rollback tx);
            t.current_tx := None;
            if Errors.is_retryable error && within_budget () then (
              retry ();
              attempt ())
            else Error (Driver error))
    | Error Client ->
        ignore (Tx.rollback tx);
        t.current_tx := None;
        Error Client
    | Error (Driver error) ->
        ignore (Tx.rollback tx);
        t.current_tx := None;
        if Errors.is_retryable error && within_budget () then (
          retry ();
          attempt ())
        else Error (Driver error)
  in
  attempt ()

let close (t : t) =
  (match !(t.current_tx) with Some tx -> ignore (Tx.close tx) | None -> ());
  t.current_tx := None;
  match !(t.conn) with
  | Some conn -> Conn.close conn
  | None ->
      ();
      t.conn := None
