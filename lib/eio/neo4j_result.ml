(* A lazily-streamed query result. [next]/[peek]/[fetch] iterate the records
   (pulling from the connection in batches on demand); [consume] drains the
   stream and returns its summary; [single]/[single_optional] enforce
   cardinality.

   Records live in the stream's FIFO buffer; [next] pops them one at a time
   (O(1)), pulling another batch from the connection when the buffer is empty.
   Because each stream owns its buffer, nested results stay correct: running a
   new query drains the previous stream into its own buffer, which [next] then
   returns.

   A deferred server failure is surfaced as [Error] once the buffered records
   before it have been consumed. *)

open Neodriver_core

let ( let* ) = Result.bind

(* Records are pulled in batches of this size when the session does not
   configure a fetch size (mirrors the Python driver's default of 1000). *)
let default_fetch_size = 1000

type t = {
  stream : Conn.stream;
  fetch_size : int;
  query : string;
  parameters : (string * Values.t) list;
  mutable consumed : bool;
}

let make ?(fetch_size = default_fetch_size) ?(query = "") ?(parameters = []) stream =
  { stream; fetch_size; query; parameters; consumed = false }

let stream t = t.stream
let keys t = (Conn.run_metadata t.stream).fields

(* Pull batches until a record is buffered, or the stream is exhausted (either
   with a summary or an error). *)
let rec ensure t =
  if Conn.has_records t.stream then Ok ()
  else if Conn.has_more t.stream then
    let* _ = Conn.pull_stream t.stream ~n:t.fetch_size in
    ensure t
  else Ok ()

(* The next record, or a deferred server failure once the buffer is empty. *)
let outcome pop stream =
  match pop stream with
  | Some record -> Ok (Some record)
  | None -> ( match Conn.error stream with Some error -> Error error | None -> Ok None)

(* A result is out of scope once it was consumed or its transaction closed:
   further reads must fail immediately (the Python driver's ResultConsumedError). *)
let check_open t =
  if t.consumed || Conn.stream_closed t.stream then
    Error (Errors.Result_consumed_error "result is not fully consumed")
  else Ok ()

let next t =
  let* () = check_open t in
  let* () = ensure t in
  outcome Conn.next_record t.stream

let peek t =
  let* () = check_open t in
  let* () = ensure t in
  outcome Conn.peek_record t.stream

let rec fetch_loop n acc t =
  if n = 0 then Ok (List.rev acc)
  else
    match next t with
    | Error _ as error -> error
    | Ok None -> Ok (List.rev acc)
    | Ok (Some record) -> fetch_loop (n - 1) (record :: acc) t

let fetch ?n t = match n with Some n -> fetch_loop n [] t | None -> fetch_loop max_int [] t
let values t = fetch_loop max_int [] t

let data t =
  let ks = keys t in
  let* records = values t in
  Ok (List.map (fun record -> List.combine ks record) records)

let consume t =
  (* Drain the rest of the stream with a DISCARD (like the Python driver's
     consume), not a PULL-all, and return the final summary. The result is
     marked consumed, so reading it further raises (whether the stream was
     already exhausted or still had records to discard). *)
  let stream = t.stream in
  t.consumed <- true;
  match Conn.summary stream with
  | Some _ -> Summary.of_stream stream ~query:t.query ~parameters:t.parameters
  | None -> (
      match Conn.error stream with
      | Some error -> Error error
      | None -> (
          let* () = Conn.discard_stream stream in
          match Conn.summary stream with
          | Some _ -> Summary.of_stream stream ~query:t.query ~parameters:t.parameters
          | None -> Error (Errors.Result_consumed_error "result is not fully consumed")))

let single t =
  let* () = check_open t in
  let* records = values t in
  match records with
  | [ record ] -> Ok record
  | _ -> Error (Errors.Result_not_single_error "expected exactly one record")

(* Expect at most one record: zero records is [None], one is [Some record], and
   more than one returns the first record together with a warning (like the
   Python driver), draining the rest of the stream so it cannot be used as a
   cheap [next]. *)
let single_optional t =
  let* () = check_open t in
  match next t with
  | Error _ as error -> error
  | Ok None -> Ok (None, [])
  | Ok (Some record) -> (
      match next t with
      | Error _ as error -> error
      | Ok None -> Ok (Some record, [])
      | Ok (Some _) ->
          (* More than one record: drain the rest with a DISCARD (like the
             Python driver's single(strict=False)), not a PULL-all. *)
          let* () = Conn.discard_stream t.stream in
          Ok (Some record, [ "expected at most one record but got multiple records" ]))
