(** Bolt protocol messages: PackStream structures tagged by message type.

    See bolt.ml for the implementation. *)

open Neodriver_packstream
open Neodriver_core

val hello_tag : int
(** Message tag of HELLO (0x01). *)

val logon_tag : int
(** Message tag of LOGON (0x6A). *)

val logoff_tag : int
(** Message tag of LOGOFF (0x6B). *)

val reset_tag : int
(** Message tag of RESET (0x0F). *)

val run_tag : int
(** Message tag of RUN (0x10). *)

val begin_tag : int
(** Message tag of BEGIN (0x11). *)

val commit_tag : int
(** Message tag of COMMIT (0x12). *)

val rollback_tag : int

val goodbye_tag : int
(** Message tag of GOODBYE (0x02). *)

val telemetry_tag : int
(** The TELEMETRY message tag (Bolt 5.4+). *)

val discard_tag : int
(** Message tag of DISCARD (0x2F). *)

val pull_tag : int
(** Message tag of PULL (0x3F). *)

val record_tag : int
(** Message tag of RECORD (0x71). *)

val success_tag : int
(** Message tag of SUCCESS (0x70). *)

val failure_tag : int
(** Message tag of FAILURE (0x7F). *)

val ignored_tag : int
(** Message tag of IGNORED (0x7E). *)

val send : Transport.t -> tag:int -> Packstream.value list -> (unit, Errors.t) result
(** Pack a message with the given [tag] and [fields] and send it.
    @return [Error _] if the message cannot be written. *)

val recv : Transport.t -> (int * Packstream.value option, Errors.t) result
(** Read one message and return its [(tag, payload)], where [payload] is the message's single field
    (none if the message carries no fields).
    @return [Error _] on timeout, end-of-file, or a malformed message. *)

val recv_fields : Transport.t -> (int * Packstream.value list, Errors.t) result
(** Read one message and return its [(tag, fields)]. For a RECORD the fields are the record's
    values.
    @return [Error _] on timeout, end-of-file, or a malformed message. *)

val respond : Transport.t -> (Packstream.value, Errors.t) result
(** Read a response message and interpret it: [SUCCESS] metadata is returned as [Ok _]; a [FAILURE]
    is mapped to [Error (Neo4j _)] via its [code] and [message]; an [IGNORED] (or any other tag) is
    an error. *)

val hello : Transport.t -> headers:Packstream.value -> (Packstream.value, Errors.t) result
(** Send a HELLO message with [headers] and read the response. *)

val logon : Transport.t -> auth:Packstream.value -> (Packstream.value, Errors.t) result
(** Send a LOGON message with the authentication map [auth] and read the response. *)

val logoff : Transport.t -> (Packstream.value, Errors.t) result
(** Send a LOGOFF message and read the response. *)

val run :
  Transport.t ->
  query:string ->
  parameters:Packstream.value ->
  extra:Packstream.value ->
  (Packstream.value, Errors.t) result
(** Send a RUN message for [query] with the given [parameters] and [extra] map, and read the
    response. *)

val begin_ : Transport.t -> extra:Packstream.value -> (Packstream.value, Errors.t) result
(** Send a BEGIN message with the [extra] map (mode, db, bookmarks, tx_metadata, tx_timeout) and
    read the response. *)

val commit : Transport.t -> (Packstream.value, Errors.t) result
(** Send a COMMIT message and read the response (its metadata carries the [bookmark]). *)

val rollback : Transport.t -> (Packstream.value, Errors.t) result
(** Send a ROLLBACK message and read the response. *)

val goodbye : Transport.t -> (unit, Errors.t) result
(** Send a GOODBYE message (the client is closing the connection); no response is read. *)

val route :
  Transport.t ->
  routing_context:Packstream.value ->
  bookmarks:Packstream.value ->
  extra:Packstream.value ->
  (Packstream.value, Errors.t) result
(** Send a ROUTE message (Bolt 4.3+): the routing table request for a database. [routing_context] is
    the URI routing context map, [bookmarks] the bookmark list and [extra] the database name (Bolt
    4.3) or a [db]/[imp_user] map (Bolt 4.4+). The response metadata carries the [rt] routing table.
*)

val pull :
  ?extra:Packstream.value ->
  Transport.t ->
  (Packstream.value list list * (Packstream.value, Errors.t) result, Errors.t) result
(** Send a PULL message and read the result: all RECORD messages up to the terminal message. [extra]
    carries the [n]/[qid] map on Bolt 4+; on Bolt 3 the PULL_ALL message takes no fields, so [extra]
    is omitted. Returns the records delivered so far and the terminal outcome — [Ok summary] on
    SUCCESS, [Error _] on a server FAILURE/IGNORED (the records delivered before the failure are
    kept, so a mid-stream error can be surfaced after buffering). *)

val discard :
  ?extra:Packstream.value ->
  Transport.t ->
  (Packstream.value list list * (Packstream.value, Errors.t) result, Errors.t) result
(** Send a DISCARD message and read the result (same shape as [pull], though records are normally
    empty). On Bolt 3 the DISCARD_ALL message takes no fields, so [extra] is omitted. *)

val metadata_has_more : Packstream.value -> bool
(** Whether a summary metadata map carries [has_more] = true. *)

val collect_records :
  Packstream.value list list ->
  Transport.t ->
  (Packstream.value list list * (Packstream.value, Errors.t) result, Errors.t) result
(** Read the RECORD messages of an already-sent PULL/DISCARD up to its summary: the records
    accumulated in [acc] (each record is its list of field values, in reverse order) plus the
    terminal outcome. Used when the request was sent without waiting for its response (e.g. a
    pipelined routing-procedure fetch). *)
