(** Logging for the Neo4j driver, mirroring the Python driver's logging.

    Logs go through the standard {{:https://erratique.ch/software/logs/doc/Logs/index.html}Logs}
    infrastructure, with one source per area of the Python driver's loggers. Logging is off by
    default; enable it with the [NEO4J_LOG_LEVEL] / [NEO4J_LOG_SCOPES] environment variables
    (honoured automatically at the first log call) or programmatically with {!setup} / {!disable}.
*)
val io : Logs.src
(** Connection-level logging: transport, handshake, Bolt message exchange, connection lifecycle and
    state changes (Python's [neo4j.io]). *)

val pool : Logs.src
(** Pool and routing logging (Python's [neo4j.pool]). *)

val session : Logs.src
(** Session logging: retries, home-database resolution (Python's [neo4j.session]). *)

val notifications : Logs.src
(** Server notification logging (Python's [neo4j.notifications]). *)

val auth : Logs.src
(** Auth-manager logging: token refreshes and provider failures (Python's [neo4j.auth_management]).
*)

val no_conn : int
(** The connection id used for events that happen without a connection (rendered as [#0000]). *)

val next_id : unit -> int
(** A fresh connection id (a global process counter, hex-rendered as [#0001], [#0002], ...). It is
    not a network identifier: Eio's portable API has no [getsockname], so a driver-assigned counter
    is used instead of the Python driver's local port — this keeps logging working on systems
    without file descriptors (e.g. MirageOS). *)

val conn : int -> string
(** [conn id] is the "[#XXXX]" prefix of [id]. *)

val value : Neodriver_packstream.Packstream.value -> string
(** [value v] renders [v] with [Packstream.to_string]. *)

val value_masked : string list -> Neodriver_packstream.Packstream.value -> string
(** [value_masked keys v] is like {!value} but every map entry whose key is in [keys] (recursively)
    has its value replaced by ["*******"] — used so HELLO / LOGON log lines never leak credentials.
*)

val debug : Logs.src -> 'a Logs.log
(** Log at debug level on [src], in Logs' msgf style (lazy: the message is formatted only when [src]
    reports at this level, so an inactive log statement costs nothing). Format the message with [m];
    to render the Python-style connection prefix, embed it in the format, e.g.
    [Log.debug Log.io (fun m -> m "[#%04X]  C: RUN %s" id query)]. *)

val info : Logs.src -> 'a Logs.log
(** Log at info level on [src]. See {!debug}. *)

val warn : Logs.src -> 'a Logs.log
(** Log at warning level on [src]. See {!debug}. *)

val error : Logs.src -> 'a Logs.log
(** Log at error level on [src]. See {!debug}. *)

(** {1:env Environment control}

    - [NEO4J_LOG_LEVEL]: [off|error|warn|info|debug] (default [off]);
    - [NEO4J_LOG_SCOPES]: comma-separated [io,pool,session,notifications,auth] (default [all]).

    The environment is read once from the process-start snapshot (OCaml [Sys.getenv] semantics):
    runtime changes are picked up only through an explicit {!setup} call. When [NEO4J_LOG_LEVEL] is
    unset, the driver never touches the user's Logs configuration. *)

type level =
  | Off
  | Error
  | Warn
  | Info
  | Debug  (** The log levels understood by the environment variables and {!setup}. *)

type scope =
  | Io
  | Pool
  | Session
  | Notifications
  | Auth  (** The log areas understood by [NEO4J_LOG_SCOPES] and {!setup}. *)

val all_scopes : scope list
(** Every scope ([Io; Pool; Session; Notifications; Auth]). *)

val level_of_string : string -> level option
(** [level_of_string s] parses [off|error|warn|info|debug]. *)

val scope_of_string : string -> scope option
(** [scope_of_string s] parses [io|pool|session|notifications|auth]. *)

val parse_env : level:string option -> scopes:string option -> level * scope list
(** [parse_env ~level ~scopes] interprets the raw environment values: an absent or garbage level is
    [Off]; absent scopes mean all; garbage scope names are ignored. Pure (no environment access) so
    it can be unit-tested. *)

val setup : ?level:level -> ?scopes:scope list -> unit -> unit
(** [setup ?level ?scopes ()] installs (or removes) the reporter and sets the per-src levels.
    Idempotent and re-callable. Defaults: [level = Off], [scopes = all_scopes] (equivalent to
    {!disable}). *)

val setup_from_env : unit -> unit
(** Read [NEO4J_LOG_LEVEL] / [NEO4J_LOG_SCOPES] and apply them. When the level variable is unset
    this is a no-op. *)

val disable : unit -> unit
(** [disable ()] restores the no-op reporter and turns every source off. *)
