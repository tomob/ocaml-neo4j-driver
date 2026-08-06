open Neodriver

(* TestKit command handlers.

   Dispatch a request ({"name": ..., "data": {...}}) to a handler and return the
   response (name, data). B0a supports the connection-configuration commands
   only: StartTest, GetFeatures, NewDriver, DriverClose, NewSession,
   SessionClose. Drivers and sessions store their configuration without opening
   a connection.

   Modeled on the Python driver's testkitbackend/_async/requests.py. *)

exception Backend_error of string

(* --- JSON helpers --- *)

let member key fields = List.assoc_opt key fields

let string key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> s
  | _ -> raise (Backend_error ("missing string " ^ key))

let int key fields =
  match List.assoc_opt key fields with
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some n -> n
      | None -> raise (Backend_error ("bad int " ^ key)))
  | _ -> raise (Backend_error ("missing int " ^ key))

let opt_string key fields =
  match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None

(* --- Backend state --- *)

type auth = { scheme : string; principal : string; credentials : string }
type driver = { uri : Addressing.uri; auth : auth; user_agent : string }
type session = { driver_id : int; database : string option; access_mode : string option }

let drivers : (int, driver) Hashtbl.t = Hashtbl.create 16
let sessions : (int, session) Hashtbl.t = Hashtbl.create 16
let next_id = ref 0

let new_id () =
  incr next_id;
  !next_id

let auth_of fields =
  match List.assoc_opt "authorizationToken" fields with
  | Some (`Assoc token) -> (
      match List.assoc_opt "data" token with
      | Some (`Assoc data) ->
          let scheme = string "scheme" data in
          if scheme <> "basic" then
            raise (Backend_error (Printf.sprintf "unsupported auth scheme %S" scheme));
          { scheme; principal = string "principal" data; credentials = string "credentials" data }
      | _ -> raise (Backend_error "authorizationToken has no data"))
  | _ -> raise (Backend_error "authorizationToken is required")

(* --- Handlers --- *)

let start_test _fields = ("RunTest", `Assoc [])

let get_features _fields =
  ("FeatureList", `Assoc [ ("features", `List (List.map (fun f -> `String f) Features.features)) ])

let new_driver fields =
  let uri_string = string "uri" fields in
  let user_agent = Option.value ~default:"ocaml-neo4j-driver" (opt_string "userAgent" fields) in
  let auth = auth_of fields in
  match Addressing.parse_uri uri_string with
  | Error error -> raise (Backend_error (Errors.to_string error))
  | Ok uri ->
      let id = new_id () in
      Hashtbl.add drivers id { uri; auth; user_agent };
      ("Driver", `Assoc [ ("id", `Int id) ])

let driver_close fields =
  let id = int "driverId" fields in
  Hashtbl.remove drivers id;
  ("Driver", `Assoc [ ("id", `Int id) ])

let new_session fields =
  let driver_id = int "driverId" fields in
  let database = opt_string "database" fields in
  let access_mode = opt_string "accessMode" fields in
  if not (Hashtbl.mem drivers driver_id) then raise (Backend_error "unknown driver");
  let id = new_id () in
  Hashtbl.add sessions id { driver_id; database; access_mode };
  ("Session", `Assoc [ ("id", `Int id) ])

let session_close fields =
  let id = int "sessionId" fields in
  Hashtbl.remove sessions id;
  ("Session", `Assoc [ ("id", `Int id) ])

let handle name data =
  let fields =
    match data with `Assoc fields -> fields | _ -> raise (Backend_error "data is not an object")
  in
  match name with
  | "StartTest" -> start_test fields
  | "GetFeatures" -> get_features fields
  | "NewDriver" -> new_driver fields
  | "DriverClose" -> driver_close fields
  | "NewSession" -> new_session fields
  | "SessionClose" -> session_close fields
  | _ -> raise (Backend_error ("No request handler for " ^ name))

(* Parse a request JSON and dispatch it. *)
let dispatch json =
  try
    match Yojson.Safe.from_string json with
    | `Assoc fields ->
        let name = string "name" fields in
        let data = match member "data" fields with Some data -> data | None -> `Assoc [] in
        handle name data
    | _ -> raise (Backend_error "Request is not an object")
  with
  | Backend_error message -> ("BackendError", `Assoc [ ("msg", `String message) ])
  | exn -> ("BackendError", `Assoc [ ("msg", `String (Printexc.to_string exn)) ])
