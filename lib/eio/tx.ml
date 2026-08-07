(* Explicit transaction on a single connection.

   See tx.mli. The transaction owns no connection of its own: it borrows the
   session's connection, so a session cannot have two open transactions. *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

type state = Open | Failed | Closed

type t = {
  conn : Conn.t;
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

let begin_transaction conn ~extra =
  match Conn.begin_ conn ~extra with
  | Error _ as error -> error
  | Ok () -> Ok { conn; state = Open; bookmark = ref None; streams = [] }

(* Drain the transaction's still-open results (like the Python driver's
   _consume_results) so COMMIT/ROLLBACK can follow. Best effort: a server
   failure is left on the stream. *)
let rec drain_one s =
  if Conn.has_more s then match Conn.pull_stream s with Ok _ -> drain_one s | Error _ -> ()

let drain_pending t =
  List.iter drain_one t.streams;
  t.streams <- []

let run t ~hydration ~query ~parameters =
  let* () = check_open t in
  match Conn.run t.conn ~hydration ~query ~parameters with
  | Error _ as error ->
      t.state <- Failed;
      error
  | Ok run_metadata ->
      let stream = Conn.stream t.conn ~hydration ~run_metadata in
      t.streams <- stream :: t.streams;
      Ok (Neo4j_result.make ~query ~parameters stream)

let commit t =
  let* () = check_open t in
  if not (failed t) then drain_pending t;
  match Conn.commit t.conn with
  | Error _ as error ->
      t.state <- Failed;
      error
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
