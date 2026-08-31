(* Bolt server-state machine.

   Tracks the protocol state of the server end of a connection so the driver
   knows when it must issue a RESET (after a FAILURE) before the next request.
   Modeled on the Python driver's ServerStateManager (_async/io/_bolt3.py and
   _bolt5.py). [re_auth] selects the Bolt >= 5.1 behaviour (HELLO enters
   AUTHENTICATION; LOGON/LOGOFF move between AUTHENTICATION and READY) or the
   older behaviour where HELLO carries the credentials and enters READY. *)

type t = Connected | Ready | Streaming | Tx_ready_or_tx_streaming | Failed | Authentication

type message =
  | Hello
  | Logon
  | Logoff
  | Run
  | Pull
  | Discard
  | Begin
  | Commit
  | Rollback
  | Reset
  | Route

let failed = function Failed -> true | _ -> false
let ready = function Ready -> true | _ -> false

let to_string = function
  | Connected -> "Connected"
  | Ready -> "Ready"
  | Streaming -> "Streaming"
  | Tx_ready_or_tx_streaming -> "Tx_ready_or_tx_streaming"
  | Failed -> "Failed"
  | Authentication -> "Authentication"

let server_transition ?(re_auth = true) ?(has_more = false) state message =
  if has_more then state
  else
    match (state, message) with
    | Connected, Hello -> if re_auth then Authentication else Ready
    | Authentication, Logon -> Ready
    | Ready, Run -> Streaming
    | Ready, Begin -> Tx_ready_or_tx_streaming
    | Ready, Logoff -> if re_auth then Authentication else state
    | Ready, Route -> Ready
    | Streaming, (Pull | Discard) -> Ready
    | Streaming, Reset -> Ready
    | Tx_ready_or_tx_streaming, (Commit | Rollback) -> Ready
    | Tx_ready_or_tx_streaming, Reset -> Ready
    | Failed, Reset -> Ready
    | _ -> state
