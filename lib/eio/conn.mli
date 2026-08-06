(* Minimal Bolt connection: TCP connect (+ optional TLS) + handshake + HELLO/auth + state machine.

   See conn.ml for the implementation. *)

open Neodriver_packstream
open Neodriver_core

type auth = { scheme : string; principal : string; credentials : string }
(** Authentication token sent in HELLO (Bolt <= 5.0) or LOGON (Bolt >= 5.1). Only the [basic] scheme
    is supported so far. *)

type config = {
  host : string;
  port : int;
  scheme : Addressing.scheme;
  connection_timeout : float;
  user_agent : string;
  auth : auth;
}
(** Target connection settings. The scheme selects TLS: [Bolt] plain, [Bolt_secure] TLS with
    certificate validation, [Bolt_self_signed] TLS without validation. Routing schemes ([Neo4j*])
    are rejected until routing is implemented. *)

type t
(** An established, authenticated Bolt connection: the transport, the negotiated protocol version
    and the tracked server state. *)

val default_user_agent : string
(** Default [user_agent] header for HELLO. *)

val connect :
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  config ->
  (t, Errors.t) result
(** Establish a connection (over TLS when the scheme requires it), negotiate the Bolt protocol
    version and authenticate. For Bolt >= 5.1 the authentication is sent via LOGON after HELLO; for
    older versions it is inline in HELLO. [clock] bounds the whole attempt and subsequent
    reads/writes by [config.connection_timeout].
    @return
      [Error _] for connection/handshake failures, for routing schemes (unsupported until routing is
      implemented), or for an authentication failure reported by the server. *)

val version : t -> int * int
(** The negotiated protocol version [(major, minor)]. *)

val server_state : t -> State.t
(** The tracked server protocol state. *)

val reset : t -> (unit, Errors.t) result
(** Send a RESET and wait for the response; the server returns to [Ready]. *)

val logon : t -> auth -> (unit, Errors.t) result
(** Re-authenticate with [auth] via LOGON (Bolt >= 5.1 only). A RESET is sent first if the server is
    in the [Failed] state.
    @return [Error _] for older protocol versions or on server failure. *)

val logoff : t -> (unit, Errors.t) result
(** De-authenticate via LOGOFF (Bolt >= 5.1 only). A RESET is sent first if the server is in the
    [Failed] state.
    @return [Error _] for older protocol versions or on server failure. *)

val close : t -> unit
(** Close the connection. *)

val hydration : t -> Hydration.t
(** A fresh hydration scope for the connection's protocol version. *)

type run_metadata = { fields : string list; qid : int option }
(** Metadata of a RUN response: the result's field names and, for multiple results, the query id. *)

val run :
  t ->
  hydration:Hydration.t ->
  query:string ->
  parameters:(string * Values.t) list ->
  ?mode:Config.access_mode ->
  ?db:string ->
  ?metadata:(string * Values.t) list ->
  unit ->
  (run_metadata, Errors.t) result
(** Send a RUN message for [query]. [parameters] are dehydrated with [hydration]. The optional
    [mode], [db] and [metadata] ([tx_metadata]) go into the request's [extra] map.
    @return
      [Error _] if the server fails the request (the connection enters [Failed] and is RESET before
      the next request). *)

val pull :
  t ->
  hydration:Hydration.t ->
  ?n:int ->
  ?qid:int ->
  unit ->
  (Values.t list list * Packstream.value, Errors.t) result
(** Send a PULL message, fetching up to [n] records (all by default) of the result [qid]. Records
    are hydrated with [hydration]. Returns the records and the full PULL summary metadata (its
    [has_more] flag, readable via [Bolt.metadata_has_more], says whether more records remain). *)

val discard : t -> ?n:int -> ?qid:int -> unit -> (unit, Errors.t) result
(** Send a DISCARD message, discarding up to [n] remaining records (all by default) of the result
    [qid]. *)

val server_agent : t -> string option
(** The server agent string reported in the HELLO response, if any. *)
