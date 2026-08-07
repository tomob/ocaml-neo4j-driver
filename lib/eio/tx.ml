(* Explicit transaction on a single connection.

   See tx.mli. The transaction owns no connection of its own: it borrows the
   session's connection, so a session cannot have two open transactions. *)

open Neodriver_packstream
open Neodriver_core

let ( let* ) = Result.bind

type state = Open | Failed | Closed
type t = { conn : Conn.t; mutable state : state; bookmark : string option ref }

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
  | Ok () -> Ok { conn; state = Open; bookmark = ref None }

let run t ~hydration ~query ~parameters =
  let* () = check_open t in
  match Conn.run t.conn ~hydration ~query ~parameters with
  | Error _ as error ->
      t.state <- Failed;
      error
  | Ok run_metadata -> (
      match Conn.pull t.conn ~hydration with
      | Error _ as error ->
          t.state <- Failed;
          error
      | Ok (records, outcome) -> (
          match outcome with
          | Error _ as error ->
              t.state <- Failed;
              error
          | Ok summary -> Ok (run_metadata, records, summary)))

let commit t =
  let* () = check_open t in
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
  else
    match Conn.rollback t.conn with
    | Error _ as error -> error
    | Ok () ->
        t.state <- Closed;
        Ok ()

let close t = match t.state with Closed -> Ok () | Open | Failed -> rollback t
