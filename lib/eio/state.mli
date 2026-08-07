(** Bolt server-state machine.

    See state.ml for the implementation. *)

type t =
  | Connected
  | Ready
  | Streaming
  | Tx_ready_or_tx_streaming
  | Failed
  | Authentication
      (** Server protocol states ([TX_READY||TX_STREAMING] is tracked as one state, like the Python
          driver). *)

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
  | Reset  (** Request messages that drive state transitions. *)

val server_transition : ?re_auth:bool -> ?has_more:bool -> t -> message -> t
(** The server state after [message] is handled. With [re_auth=true] (Bolt >= 5.1) HELLO enters
    [Authentication] and LOGON/LOGOFF move between [Authentication] and [Ready]; with
    [re_auth=false] HELLO carries the credentials and enters [Ready]. A [Pull] or [Discard] with
    [has_more=true] keeps the state at [Streaming]. *)

val failed : t -> bool
(** Whether the server is in the [Failed] state (a RESET is needed before the next request). *)

val ready : t -> bool
(** Whether the server is in the [Ready] state. *)
