(** Minimal Bolt connection: TCP connect (+ optional TLS) + handshake + HELLO/auth + state machine.

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
  routing_context : (string * string) list option;
  telemetry_disabled : bool;
}
(** Target connection settings. The scheme selects TLS: [Bolt] plain, [Bolt_secure] TLS with
    certificate validation, [Bolt_self_signed] TLS without validation. [routing_context] is sent as
    the [routing] field of HELLO (server-side routing) for routed ([neo4j*]) drivers: [None] for
    direct [bolt*] drivers, [Some ctx] for routed ones (an empty list sends [routing: {}]). The
    field is only sent on Bolt >= 4.1. [telemetry_disabled] suppresses the Bolt 5.4+ TELEMETRY
    notifications. *)

type t
(** An established, authenticated Bolt connection: the transport, the negotiated protocol version
    and the tracked server state. *)

val default_user_agent : string
(** Default [user_agent] header for HELLO. *)

val basic_auth : ?principal:string -> ?credentials:string -> unit -> auth
(** The basic authentication token ([scheme = "basic"]), with the given [principal] (default
    [neo4j]) and [credentials] (default empty). *)

val connect :
  ?resolver:(Addressing.t -> (Addressing.t list, Errors.t) result) ->
  ?domain_name_resolver:(string -> (string list, Errors.t) result) ->
  [> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  Mtime.t Eio.Time.clock_ty Eio.Resource.t ->
  Eio.Switch.t ->
  config ->
  (t, Errors.t) result
(** Establish a connection (over TLS when the scheme requires it), negotiate the Bolt protocol
    version and authenticate. [resolver] replaces the address lookup: the address built from
    [config] is passed to it and each returned address is tried in turn (first success wins, errors
    are aggregated). Without [resolver], the single configured address is used.
    [domain_name_resolver] resolves any hostnames among the (resolved) addresses to literal IPs (the
    TestKit harness's custom domain-name resolution); literal IPs are used as-is. An IPv6 literal in
    [config.host] is treated as such (the address is built with brackets around the host). For Bolt
    >= 5.1 the authentication is sent via LOGON after HELLO; for older versions it is inline in
    HELLO. [clock] bounds the whole attempt and subsequent reads/writes by
    [config.connection_timeout].
    @return
      [Error _] for connection/handshake failures, for routing schemes (unsupported until routing is
      implemented), or for an authentication failure reported by the server. *)

val address : t -> Addressing.t
(** The resolved address the connection is established with. *)

val version : t -> int * int
(** The negotiated protocol version [(major, minor)]. *)

val id : t -> int
(** The connection id (a driver-assigned counter, rendered as "[#XXXX]" in log lines; see
    [Log.conn]). *)

val server_state : t -> State.t
(** The tracked server protocol state. *)

val is_failed : t -> bool
(** Whether the server answered the last request with a FAILURE: the connection is not in a clean
    state and needs a RESET before it can be reused. *)

val set_on_error : t -> (t -> Errors.t -> unit) -> unit
(** Install a callback invoked with [t] and the error whenever a request on the connection fails:
    failed auto-RESETs and failed messages in {!run} and {!route}, and server failures surfaced by
    {!pull} and {!discard}. The routing cluster installs it to deactivate the connection's address.
*)

val last_database : t -> string option
(** The [db] of the last {!run} on the connection, if any. *)

val set_last_database : t -> string option -> unit
(** Record the [db] of the next {!run}. *)

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

type run_metadata = {
  fields : string list;
  qid : int option;
  bookmark : string option;
  t_first : int option;
  rt : Packstream.value option;
}
(** Metadata of a RUN response: the result's field names, the query id (for multiple results), the
    [bookmark] reported for an auto-commit transaction (if any), the [t_first] timing (result
    available-after, milliseconds) and the [rt] routing-table value reported when server-side
    routing is enabled (if any). *)

val run :
  ?mode:Config.access_mode ->
  ?db:string ->
  ?bookmarks:string list ->
  ?timeout:float ->
  ?metadata:(string * Values.t) list ->
  ?telemetry:int ->
  t ->
  hydration:Hydration.t ->
  query:string ->
  parameters:(string * Values.t) list ->
  (run_metadata, Errors.t) result
(** Send a RUN message for [query]. [parameters] are dehydrated with [hydration]. The optional
    [mode], [db], [bookmarks], [timeout] (seconds) and [metadata] ([tx_metadata]) go into the
    request's [extra] map. [telemetry] batches a TELEMETRY notification (Bolt 5.4+) with the RUN.
    @return
      [Error _] if the server fails the request (the connection enters [Failed] and is RESET before
      the next request). *)

val begin_ : ?telemetry:int -> t -> extra:Packstream.value -> (unit, Errors.t) result
(** Send a BEGIN message (start a transaction) with the given [extra] map (see [build_extra]). A
    RESET is sent first if the server is in the [Failed] state. [telemetry] batches a TELEMETRY
    notification with the BEGIN. *)

val build_extra :
  ?mode:Config.access_mode ->
  ?db:string ->
  ?imp_user:string ->
  ?bookmarks:string list ->
  ?timeout:float ->
  ?metadata:(string * Packstream.value) list ->
  unit ->
  Packstream.value
(** The [extra] map for BEGIN (and auto-commit RUN): [mode] ([Read] -> "r"), [db], [imp_user],
    [bookmarks], [timeout] (seconds, sent as [tx_timeout] milliseconds) and [metadata]
    ([tx_metadata], already dehydrated). *)

val commit : t -> (Packstream.value, Errors.t) result
(** Send a COMMIT message (end the transaction, applying its writes). Returns the full response
    metadata (its [bookmark] entry records the commit position). *)

val rollback : t -> (unit, Errors.t) result
(** Send a ROLLBACK message (end the transaction, discarding its writes). On a [Failed] connection
    the server already discarded the transaction implicitly, so a RESET is sent instead. *)

val route :
  ?db:string ->
  ?imp_user:string ->
  t ->
  routing_context:(string * string) list ->
  bookmarks:string list ->
  (Packstream.value, Errors.t) result
(** Fetch the routing table of [db] (default database when [None]). On Bolt 4.3+ this uses the ROUTE
    message; the [routing_context] (from the URI query) and [bookmarks] are sent with the request
    and the [rt] routing-table value is returned. On older servers (Bolt 3 / 4.0–4.2) the routing
    procedure is called instead: [CALL dbms.cluster.routing.getRoutingTable($context)] (Bolt 3) or
    [CALL dbms.routing.getRoutingTable($context[, $database])] on the [system] database (Bolt
    4.0–4.2); the single returned record is zipped with its field names into the same
    [ttl]/[servers] shape as the ROUTE [rt] value.
    @return the routing-table value (for {!Neodriver_core.Routing_table.parse}).
    @return
      [Error _] for a failed fetch (a procedure that is missing on the server is a non-fatal
      discovery error, e.g. a standalone 3.5 instance), or a [Errors.Configuration_error] for
      [imp_user] on Bolt < 4.3 (procedures do not support impersonation) and for [db] on Bolt 3 (no
      multi-db). *)

val pull :
  ?n:int ->
  ?qid:int ->
  t ->
  hydration:Hydration.t ->
  (Values.t list list * (Packstream.value, Errors.t) result, Errors.t) result
(** Send a PULL message, fetching up to [n] records (all by default) of the result [qid]. Records
    are hydrated with [hydration]. Returns the records delivered and the terminal outcome: [Ok _]
    with the PULL summary metadata (its [has_more] flag, readable via [Bolt.metadata_has_more], says
    whether more records remain) on SUCCESS, or [Error _] for a server FAILURE (the records
    delivered before the failure are kept). A server failure leaves the connection in the [Failed]
    state. *)

val discard : ?n:int -> ?qid:int -> t -> ((Packstream.value, Errors.t) result, Errors.t) result
(** Send a DISCARD message, discarding up to [n] remaining records (all by default) of the result
    [qid]. Returns the response: [Ok (Ok _)] with the DISCARD summary metadata on SUCCESS, or
    [Error _] for a server failure (the connection enters the [Failed] state). *)

type stream
(** A lazily-streamed result on a connection: RUN is sent immediately, records are pulled in batches
    on demand. The terminal state is a [summary] (normal end) or an [error] (a server failure,
    surfaced after the buffered records are consumed). *)

val stream :
  ?on_complete:(Packstream.value -> unit) ->
  ?on_error:(Errors.t -> unit) ->
  t ->
  hydration:Hydration.t ->
  run_metadata:run_metadata ->
  stream
(** A fresh [stream] for the given connection, hydration scope and RUN metadata. [on_complete] fires
    with the final summary once the stream ends normally; [on_error] fires with the failure that
    terminated the stream (e.g. to mark the owning transaction as failed). *)

val connection : stream -> t
(** The connection the stream is running on. *)

val buffered : stream -> Values.t list list
(** A snapshot of the records buffered so far (still unconsumed), in order. Consuming the stream
    with [next_record] pops from the FIFO buffer. *)

val has_records : stream -> bool
(** Whether a record is buffered and available without pulling. *)

val next_record : stream -> Values.t list option
(** Pop the next buffered record, if any ([None] once the buffer is empty — the caller pulls for
    more). *)

val peek_record : stream -> Values.t list option
(** Peek at the next buffered record, if any, without consuming it. *)

val has_more : stream -> bool
(** Whether the stream still has records to pull. *)

val error : stream -> Errors.t option
(** A server failure that interrupted the stream. *)

val summary : stream -> Packstream.value option
(** The final PULL summary metadata, once the stream has ended normally. *)

val had_record : stream -> bool
(** Whether any record was pulled on this stream (used to synthesize the Bolt 4.x GQL status
    objects: a result with records is a Success, one without is No Data). *)

val run_metadata : stream -> run_metadata
(** The RUN metadata (field names, query id, timings, bookmark). *)

val pull_stream : ?n:int -> stream -> (Values.t list list, Errors.t) result
(** Pull up to [n] more records (all by default), buffering them, and return the newly fetched
    records. A server failure mid-stream is stored on the stream ([error]) and the records delivered
    before it are kept. Once the stream ends normally, its summary is stored.
    @return [Error _] for transport failures. *)

val drain_stream : stream -> unit
(** Pull a stream to its end, best effort: a transport failure stops the drain (the failure is left
    on the stream; the connection is recovered by the next request's RESET). *)

val discard_stream : stream -> (unit, Errors.t) result
(** Discard the rest of a stream without pulling its records (consume semantics): the DISCARD
    response's metadata becomes the stream's final summary. No-op once the stream is finished. *)

val stream_closed : stream -> bool
(** Whether the stream's transaction was closed (the stream is out of scope). *)

val mark_stream_closed : stream -> unit
(** Mark a stream as closed: further reads on it must fail, like the Python driver's
    ResultConsumedError. *)

val mark_stream_error : stream -> Errors.t -> unit
(** Mark a stream as failed with [error]: further reads surface the failure instead of pulling (e.g.
    when a sibling request failed and terminated the stream's transaction). *)

val server_agent : t -> string option
(** The server agent string reported in the HELLO response, if any. *)

val ssr_enabled : t -> bool
(** Whether the server advertised the [ssr.enabled] hint in its HELLO response, i.e. whether it
    sends [rt] routing tables in RUN responses (server-side routing). *)

val capabilities : t -> Capabilities.t
(** The protocol capabilities of the connection's version. *)

val current_auth : t -> auth option
(** The authentication token the connection is currently logged on with, if any. *)

val re_auth : t -> auth -> (bool, Errors.t) result
(** Re-authenticate when [auth] differs from the current token (LOGOFF then LOGON, Bolt >= 5.1).
    Returns whether the token changed ([false] when it is the same as the current one).
    @return [Error _] for older protocol versions or on server failure. *)

val mark_unauthenticated : t -> unit
(** Forget the current token (the next [re_auth] will log on again). *)
