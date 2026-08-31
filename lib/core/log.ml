(* Logging for the Neo4j driver, mirroring the Python driver's logging.

   Logs go through the standard Logs infrastructure, with one source per area
   of the Python driver's loggers ([neo4j.io], [neo4j.pool],
   [neo4j.session], [neo4j.notifications]). Logging is off by default (Logs'
   no-op reporter); it is enabled either by the [NEO4J_LOG_LEVEL] /
   [NEO4J_LOG_SCOPES] environment variables (honoured automatically at the
   first log call) or programmatically via [setup] / [disable].

   Connection events carry a "[#XXXX]" prefix rendered from a driver-assigned
   connection id (a global counter). The Python driver uses the socket's local
   port; Eio's portable API has no [getsockname], so a counter is used instead —
   this keeps logging working on systems without file descriptors (e.g.
   MirageOS). The exact id value is not part of any API contract.

   Value formatting reuses [Packstream.to_string]; the [value_masked] helper
   redacts credential-like keys so HELLO/LOGON log lines never leak secrets. *)

open Neodriver_packstream

let io = Logs.Src.create ~doc:"Neo4j Bolt connection and messages" "neodriver.io"
let pool = Logs.Src.create ~doc:"Neo4j connection pool and routing" "neodriver.pool"
let session = Logs.Src.create ~doc:"Neo4j sessions" "neodriver.session"
let notifications = Logs.Src.create ~doc:"Neo4j server notifications" "neodriver.notifications"
let auth = Logs.Src.create ~doc:"Neo4j auth management" "neodriver.auth"

(* The connection id of events that happen without a connection. *)
let no_conn = 0

(* A global connection counter, rendered hex like the Python driver's local
   port. Starts at 1 so the first connection is [#0001]. *)
let counter = Atomic.make 0
let next_id () = Atomic.fetch_and_add counter 1 + 1
let conn id = Printf.sprintf "[#%04X]" id

(* --- Env-var control --- *)

type level = Off | Error | Warn | Info | Debug
type scope = Io | Pool | Session | Notifications

let all_scopes = [ Io; Pool; Session; Notifications ]
let srcs = [ (Io, io); (Pool, pool); (Session, session); (Notifications, notifications) ]

let level_of_string = function
  | "off" -> Some Off
  | "error" -> Some Error
  | "warn" -> Some Warn
  | "info" -> Some Info
  | "debug" -> Some Debug
  | _ -> None

let scope_of_string = function
  | "io" -> Some Io
  | "pool" -> Some Pool
  | "session" -> Some Session
  | "notifications" -> Some Notifications
  | _ -> None

(* The Logs level for a non-[Off] [level] ([Off] never reaches this: it is
   handled before any level wiring). *)
let logs_level = function
  | Error -> Logs.Error
  | Warn -> Logs.Warning
  | Info -> Logs.Info
  | Debug -> Logs.Debug
  | Off -> assert false

(* [parse_env] is pure (no environment access) so it can be unit-tested. An
   absent level is [Off]; a garbage level is treated as [Off] (documented);
   absent scopes mean all; garbage scope names are ignored. *)
let parse_env ~level ~scopes =
  let level = Option.bind level level_of_string |> Option.value ~default:Off in
  let scopes =
    match scopes with
    | None -> all_scopes
    | Some value ->
        String.split_on_char ',' value |> List.map String.trim |> List.filter_map scope_of_string
  in
  (level, scopes)

(* --- Reporter and level wiring --- *)

(* Whether env control has been applied once, so the first log call honours
   [NEO4J_LOG_LEVEL] without clobbering a user-configured reporter. *)
let initialized = ref false

(* Set the global level and the per-src levels for one [setup]. A src with an
   explicit [None] level never reports (Logs does not fall back to the global
   level per message), so the [all] case sets the level globally and on every
   existing source, the [Off] case clears everything, and a scoped case turns
   everything off except the listed sources. *)
let enable_srcs level scopes =
  match level with
  | Off -> Logs.set_level ~all:true None
  | level when scopes = all_scopes -> Logs.set_level ~all:true (Some (logs_level level))
  | level ->
      Logs.set_level ~all:true None;
      List.iter
        (fun scope -> Logs.Src.set_level (List.assoc scope srcs) (Some (logs_level level)))
        scopes

(* Apply an explicit configuration: install (or remove) the reporter and set
   the per-src levels. Idempotent and re-callable (tests reconfigure freely). *)
let setup ?(level = Off) ?(scopes = all_scopes) () =
  initialized := true;
  (match level with
  | Off -> Logs.set_reporter Logs.nop_reporter
  | Error | Warn | Info | Debug -> Logs.set_reporter (Logs_fmt.reporter ()));
  enable_srcs level scopes

(* Read [NEO4J_LOG_LEVEL] / [NEO4J_LOG_SCOPES] and apply them. When the level
   variable is unset this is a no-op, so a user's own Logs configuration is
   left untouched. *)
let setup_from_env () =
  match Sys.getenv_opt "NEO4J_LOG_LEVEL" with
  | None -> initialized := true
  | Some level ->
      let level, scopes =
        parse_env ~level:(Some level) ~scopes:(Sys.getenv_opt "NEO4J_LOG_SCOPES")
      in
      setup ~level ~scopes ()

let disable () = setup ~level:Off ~scopes:all_scopes ()

(* Applied once at the first log call; a no-op afterwards. *)
let ensure () = if not !initialized then setup_from_env ()

(* --- Value formatting --- *)

(* Recursively replace the value of every map entry whose key is in [keys]. *)
let rec mask keys = function
  | Packstream.Map entries ->
      Packstream.Map
        (List.map
           (fun (k, v) ->
             if List.mem k keys then (k, Packstream.String "*******") else (k, mask keys v))
           entries)
  | Packstream.List items -> Packstream.List (List.map (mask keys) items)
  | v -> v

let value v = Packstream.to_string v
let value_masked keys v = value (mask keys v)

(* --- Level helpers --- *)

(* The helpers use Logs' msgf style: the caller passes a closure that formats
   the message with [m]. Logs invokes that closure lazily, only when the source
   reports at the given level, so an expensive rendering inside the closure
   (e.g. [Log.value] of a message map) costs nothing when logging is disabled —
   the hot-path overhead of an inactive log statement is one [ensure] level
   check and nothing else. *)
let emit src level msgf =
  ensure ();
  Logs.msg ~src level msgf

let debug src msgf = emit src Logs.Debug msgf
let info src msgf = emit src Logs.Info msgf
let warn src msgf = emit src Logs.Warning msgf
let error src msgf = emit src Logs.Error msgf
