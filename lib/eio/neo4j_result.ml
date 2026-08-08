(* A lazily-streamed query result. [next]/[peek]/[fetch] iterate the records
   (pulling from the connection in batches on demand); [consume] drains the
   stream and returns its summary; [single]/[single_optional] enforce
   cardinality.

   A deferred server failure is surfaced as [Error] once the buffered records
   before it have been consumed. *)

open Neodriver_core

let ( let* ) = Result.bind

(* Records are pulled in batches of this size when the session does not
   configure a fetch size (mirrors the Python driver's default of 1000). *)
let default_fetch_size = 1000

type t = {
  stream : Conn.stream;
  mutable pending : Values.t list list;
  fetch_size : int;
  query : string;
  parameters : (string * Values.t) list;
}

let make ?(fetch_size = default_fetch_size) ?(query = "") ?(parameters = []) stream =
  { stream; pending = []; fetch_size; query; parameters }

let stream t = t.stream
let keys t = (Conn.run_metadata t.stream).fields

(* Pull batches until at least one record is pending, or the stream is
   exhausted (either with a summary or an error). [pending] holds exactly the
   records not yet delivered to the caller, so [next]/[peek] stay O(1) per
   record regardless of how many records have been fetched so far. *)
let rec ensure t =
  match t.pending with
  | _ :: _ -> Ok ()
  | [] ->
      if Conn.has_more t.stream then (
        let* records = Conn.pull_stream t.stream ~n:t.fetch_size in
        t.pending <- records;
        ensure t)
      else Ok ()

let record_at t =
  match t.pending with
  | record :: _ -> Ok (Some record)
  | [] -> ( match Conn.error t.stream with Some error -> Error error | None -> Ok None)

let next t =
  let* () = ensure t in
  match t.pending with
  | record :: rest ->
      t.pending <- rest;
      Ok (Some record)
  | [] -> ( match Conn.error t.stream with Some error -> Error error | None -> Ok None)

let peek t =
  let* () = ensure t in
  record_at t

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
  Ok (List.map (fun record -> List.map2 (fun k v -> (k, v)) ks record) records)

let consume t =
  let* _ = values t in
  match Conn.summary t.stream with
  | Some _ -> Ok (Summary.of_stream t.stream ~query:t.query ~parameters:t.parameters)
  | None -> Error (Errors.Result_consumed_error "result is not fully consumed")

let single t =
  let* records = values t in
  match records with
  | [ record ] -> Ok record
  | _ -> Error (Errors.Result_not_single_error "expected exactly one record")

let single_optional t =
  let* records = values t in
  match records with
  | [] -> Ok None
  | [ record ] -> Ok (Some record)
  | _ -> Error (Errors.Result_not_single_error "expected at most one record")
