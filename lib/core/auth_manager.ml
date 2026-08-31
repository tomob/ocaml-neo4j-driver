(* Authentication tokens for the Neo4j driver.

   Modelled on the Python driver's Auth (api.py) and ExpiringAuth
   (_auth_management.py). A token carries the scheme and the optional
   principal / credentials / realm / extra parameters; absent fields are
   omitted when the token is serialised for HELLO / LOGON (a bearer token
   sends only scheme and credentials).

   Phase A8: the auth-manager machinery (static / basic / bearer managers with
   refresh on Unauthorized / TokenExpired) is built on top of these types. *)

open Neodriver_packstream

type token = {
  scheme : string;
  principal : string option;
  credentials : string option;
  realm : string option;
  parameters : (string * Packstream.value) list;
}

(* The basic authentication token: scheme [basic] with the given principal
   (default [neo4j]) and credentials (default empty), mirroring the Python
   [basic_auth]. *)
let basic_auth ?(principal = "neo4j") ?(credentials = "") ?realm () =
  {
    scheme = "basic";
    principal = Some principal;
    credentials = Some credentials;
    realm;
    parameters = [];
  }

(* A bearer (SSO) token: scheme [bearer] with only the token as credentials
   (the principal is omitted on the wire), mirroring the Python [bearer_auth]. *)
let bearer_auth credentials =
  {
    scheme = "bearer";
    principal = None;
    credentials = Some credentials;
    realm = None;
    parameters = [];
  }

(* A custom token for arbitrary authentication schemes, mirroring the Python
   [custom_auth]: optional principal / credentials / realm plus extra
   [parameters] sent as a map. *)
let custom_auth ?principal ?credentials ?realm ?(parameters = []) scheme =
  { scheme; principal; credentials; realm; parameters }

(* Whether two tokens carry the same authentication information. Parameters are
   compared order-independently (like the Python Auth.__eq__ on its fields). *)
let eq a b =
  a.scheme = b.scheme && a.principal = b.principal && a.credentials = b.credentials
  && a.realm = b.realm
  &&
  let sort = List.sort (fun (k, _) (k', _) -> String.compare k k') in
  sort a.parameters = sort b.parameters

(* Serialise a token for HELLO (Bolt <= 5.0) or LOGON (Bolt >= 5.1): absent
   fields are omitted, like the Python [to_auth_dict]. *)
let to_map token =
  let fields =
    ("scheme", Packstream.String token.scheme)
    ::
    (match token.principal with
    | Some principal -> [ ("principal", Packstream.String principal) ]
    | None -> [])
    @ (match token.credentials with
      | Some credentials -> [ ("credentials", Packstream.String credentials) ]
      | None -> [])
    @ (match token.realm with Some realm -> [ ("realm", Packstream.String realm) ] | None -> [])
    @ if token.parameters = [] then [] else [ ("parameters", Packstream.Map token.parameters) ]
  in
  Packstream.Map fields

(* Potentially expiring authentication information, mirroring the Python
   ExpiringAuth: [expires_at] is an absolute timestamp (seconds since the
   epoch); [None] means the token does not expire in time. *)
type expiring_auth = { token : token; expires_at : float option }

(* A (flat) copy of [auth] expiring [seconds] from [now]. *)
let expires_in ~now seconds auth = { auth with expires_at = Some (now +. seconds) }

(* Whether [auth] has passed its expiry time ([None] never expires). *)
let has_expired ~now auth =
  match auth.expires_at with None -> false | Some expires_at -> expires_at < now

(* --- Auth managers --- *)

let ( let* ) = Result.bind

type t = {
  get_auth : unit -> (token, Errors.t) result;
  handle_security_exception : token -> Errors.t -> (bool, Errors.t) result;
}

(* A manager that always returns the same token and never handles security
   exceptions, mirroring the Python AsyncStaticAuthManager. *)
let static auth =
  { get_auth = (fun () -> Ok auth); handle_security_exception = (fun _ _ -> Ok false) }

(* The generic rotating-token manager (the OCaml analogue of the Python
   AsyncNeo4jAuthTokenManager): caches the provider's ExpiringAuth under a
   lock, refreshes it when the cache is empty or the token has expired, and
   refreshes it again when the server rejects the exact token currently
   cached with a handled security error. A provider failure is logged and
   propagated (like the Python manager, which logs "provider failed" and
   re-raises). [now] supplies the current timestamp for expiry checks. *)
let neo4j_auth_token_manager ~now ~provider ~handled_codes =
  let lock = Mutex.create () in
  let current : expiring_auth option ref = ref None in
  let refresh () =
    match provider () with
    | Error error ->
        Log.error Log.auth (fun m ->
            m "[#0000]  _: <AUTH MANAGER> provider failed: %s" (Errors.to_string error));
        Error error
    | Ok expiring ->
        current := Some expiring;
        Ok expiring.token
  in
  let get_auth () =
    Mutex.protect lock (fun () ->
        match !current with
        | Some expiring when not (has_expired ~now:(now ()) expiring) -> Ok expiring.token
        | _ ->
            Log.debug Log.auth (fun m ->
                m "[#0000]  _: <AUTH MANAGER> refreshing (%s)"
                  (match !current with None -> "init" | Some _ -> "time out"));
            refresh ())
  in
  let handle_security_exception auth error =
    match Errors.code error with
    | Some code when List.mem code handled_codes -> (
        match
          Mutex.protect lock (fun () ->
              match !current with
              | Some expiring when eq expiring.token auth ->
                  Log.debug Log.auth (fun m ->
                      m "[#0000]  _: <AUTH MANAGER> refreshing (error %s)" code);
                  let* _ = refresh () in
                  Ok ()
              | _ -> Ok ())
        with
        | Ok () -> Ok true
        | Error _ as error -> error)
    | _ -> Ok false
  in
  { get_auth; handle_security_exception }

(* Password rotation for basic auth: refresh when the server rejects the
   current token with Unauthorized. The provider returns a plain token (never
   expiring in time), mirroring the Python AuthManagers.basic. *)
let basic ~provider =
  let provider () = Result.map (fun token -> { token; expires_at = None }) (provider ()) in
  neo4j_auth_token_manager
    ~now:(fun () -> 0.0)
    ~provider
    ~handled_codes:[ "Neo.ClientError.Security.Unauthorized" ]

(* Potentially expiring bearer tokens: refresh proactively once [expires_at]
   passes ([now] supplies the current timestamp), or when the server rejects
   the current token with TokenExpired / Unauthorized, mirroring the Python
   AuthManagers.bearer. *)
let bearer ~now ~provider =
  neo4j_auth_token_manager ~now ~provider
    ~handled_codes:
      [ "Neo.ClientError.Security.TokenExpired"; "Neo.ClientError.Security.Unauthorized" ]
