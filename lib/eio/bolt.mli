open Neodriver_packstream
(* Bolt protocol messages: PackStream structures tagged by message type.

   See bolt.ml for the implementation. *)

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
(** Message tag of ROLLBACK (0x13). *)

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

val pull :
  Transport.t ->
  extra:Packstream.value ->
  (Packstream.value list list * Packstream.value, Errors.t) result
(** Send a PULL message with the [extra] map (e.g. [n], [qid]) and read the result: all RECORD
    messages up to the summary. Returns [(records, summary_metadata)]. *)

val discard :
  Transport.t ->
  extra:Packstream.value ->
  (Packstream.value list list * Packstream.value, Errors.t) result
(** Send a DISCARD message with the [extra] map and read the result (same shape as [pull], though
    records are normally empty). *)

val metadata_has_more : Packstream.value -> bool
(** Whether a summary metadata map carries [has_more] = true. *)
