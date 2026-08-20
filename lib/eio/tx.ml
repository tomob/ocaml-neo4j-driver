(* Explicit transaction on a single connection.

   See tx.mli. The transaction owns no connection of its own: it borrows the
   session's connection, so a session cannot have two open transactions. *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

type state = Open | Failed | Closed

type t = {
  conn : Conn.t;
  fetch_size : int option;
  mutable state : state;
  bookmark : string option ref;
  mutable streams : Conn.stream list;
}

let closed t = t.state = Closed
let failed t = t.state = Failed
let closed_error = Errors.Transaction_error "Transaction closed"
let failed_error = Errors.Transaction_error "Transaction failed"

let check_open t =
  match t.state with Open -> Ok () | Closed -> Error closed_error | Failed -> Error failed_error

let metadata_string key = function
  | Packstream.Map fields -> (
      match List.assoc_opt key fields with Some (Packstream.String v) -> Some v | _ -> None)
  | _ -> None

let begin_transaction conn ~extra ~fetch_size ~telemetry =
  match Conn.begin_ ?telemetry conn ~extra with
  | Error _ as error -> error
  | Ok () -> Ok { conn; fetch_size; state = Open; bookmark = ref None; streams = [] }

(* Drain the transaction's still-open results (like the Python driver's
   _consume_results) so COMMIT/ROLLBACK can follow, and mark them closed: a
   result whose transaction ended is out of scope, so later reads on it fail
   immediately. Best effort: a server failure is left on the stream. The
   remaining records are DISCARDed (not pulled) so an endless stream cannot
   hang the close. *)
let drain_pending t =
  List.iter (fun s -> ignore (Conn.discard_stream s)) t.streams;
  List.iter Conn.mark_stream_closed t.streams;
  t.streams <- []

let run t ~hydration ~query ~parameters =
  let* () = check_open t in
  match Conn.run t.conn ~hydration ~query ~parameters with
  | Error error ->
      t.state <- Failed;
      (* A failed RUN terminates every result of the transaction: they surface
         the same failure instead of pulling on the broken connection. *)
      List.iter (fun s -> Conn.mark_stream_error s error) t.streams;
      Error error
  | Ok run_metadata ->
      let stream =
        Conn.stream t.conn ~hydration ~run_metadata ~on_error:(fun error ->
            (* A server failure on one of the transaction's results terminates
               it: mark the transaction failed and every result failed, so
               later operations on them raise without touching the connection. *)
            t.state <- Failed;
            List.iter (fun s -> Conn.mark_stream_error s error) t.streams)
      in
      t.streams <- stream :: t.streams;
      Ok (Neo4j_result.make ?fetch_size:t.fetch_size ~query ~parameters stream)

let commit t =
  let* () = check_open t in
  if not (failed t) then drain_pending t;
  match Conn.commit t.conn with
  | Error (Errors.Neo4j _ as error) ->
      (* The server answered with a FAILURE: the transaction was not applied. *)
      t.state <- Failed;
      Error error
  | Error error ->
      (* A connection-level failure during COMMIT: the outcome is unknown (the
         commit may have been applied). Surface an IncompleteCommit. *)
      t.state <- Failed;
      Error (Errors.Incomplete_commit (Errors.to_string error))
  | Ok metadata ->
      let bookmark = metadata_string "bookmark" metadata in
      t.bookmark := bookmark;
      t.state <- Closed;
      Ok bookmark

let rollback t =
  if closed t then Error closed_error
  else begin
    if not (failed t) then drain_pending t;
    match Conn.rollback t.conn with
    | Error _ as error -> error
    | Ok () ->
        t.state <- Closed;
        Ok ()
  end

let close t = match t.state with Closed -> Ok () | Open | Failed -> rollback t
