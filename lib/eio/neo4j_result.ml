(* A lazily-streamed query result. [next]/[peek]/[fetch] iterate the records
   (pulling from the connection on demand); [consume] drains the stream and
   returns its summary; [single]/[single_optional] enforce cardinality.

   A deferred server failure is surfaced as [Error] once the buffered records
   before it have been consumed. *)

open Neodriver_core

let ( let* ) = Result.bind

type t = {
  stream : Conn.stream;
  mutable cursor : int;
  query : string;
  parameters : (string * Values.t) list;
}

let make ?(query = "") ?(parameters = []) stream = { stream; cursor = 0; query; parameters }
let stream t = t.stream
let keys t = (Conn.run_metadata t.stream).fields

(* Pull batches until at least one record is buffered beyond the cursor, or the
   stream is exhausted (either with a summary or an error). *)
let rec ensure t =
  if t.cursor < List.length (Conn.buffered t.stream) then Ok ()
  else if Conn.has_more t.stream then
    let* _ = Conn.pull_stream t.stream ~n:1 in
    ensure t
  else Ok ()

let record_at t =
  if t.cursor < List.length (Conn.buffered t.stream) then
    Ok (Some (List.nth (Conn.buffered t.stream) t.cursor))
  else match Conn.error t.stream with Some error -> Error error | None -> Ok None

let next t =
  let* () = ensure t in
  match record_at t with
  | Ok (Some _ as record) ->
      t.cursor <- t.cursor + 1;
      Ok record
  | result -> result

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
