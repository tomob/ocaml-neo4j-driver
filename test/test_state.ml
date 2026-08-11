(* Unit tests for the Bolt server-state machine (State). *)

open Neodriver_eio
open Alcotest

let show_state = function
  | State.Connected -> "Connected"
  | State.Ready -> "Ready"
  | State.Streaming -> "Streaming"
  | State.Tx_ready_or_tx_streaming -> "Tx_ready_or_tx_streaming"
  | State.Failed -> "Failed"
  | State.Authentication -> "Authentication"

let show_message = function
  | State.Hello -> "Hello"
  | State.Logon -> "Logon"
  | State.Logoff -> "Logoff"
  | State.Run -> "Run"
  | State.Pull -> "Pull"
  | State.Discard -> "Discard"
  | State.Begin -> "Begin"
  | State.Commit -> "Commit"
  | State.Rollback -> "Rollback"
  | State.Reset -> "Reset"
  | State.Route -> "Route"

let check_transition ?re_auth ?has_more from message expected =
  let actual = State.server_transition ?re_auth ?has_more from message in
  check string
    (show_state from ^ " after " ^ show_message message)
    (show_state expected) (show_state actual)

let server_re_auth () =
  (* Bolt >= 5.1. *)
  check_transition State.Connected State.Hello State.Authentication;
  check_transition State.Authentication State.Logon State.Ready;
  check_transition State.Ready State.Logoff State.Authentication;
  check_transition State.Authentication State.Logoff State.Authentication;
  check_transition State.Ready State.Run State.Streaming;
  check_transition State.Streaming State.Pull State.Ready;
  check_transition State.Streaming State.Discard State.Ready;
  check_transition State.Streaming State.Reset State.Ready;
  check_transition State.Ready State.Route State.Ready;
  check_transition State.Tx_ready_or_tx_streaming State.Commit State.Ready;
  check_transition State.Tx_ready_or_tx_streaming State.Rollback State.Ready;
  check_transition State.Tx_ready_or_tx_streaming State.Reset State.Ready;
  check_transition State.Failed State.Reset State.Ready

let server_no_re_auth () =
  (* Bolt <= 5.0: HELLO carries the credentials and enters READY. *)
  check_transition ~re_auth:false State.Connected State.Hello State.Ready;
  check_transition ~re_auth:false State.Ready State.Logoff State.Ready;
  check_transition ~re_auth:false State.Ready State.Run State.Streaming;
  check_transition ~re_auth:false State.Failed State.Reset State.Ready

let unknown_transitions () =
  (* Unspecified transitions keep the current state. *)
  check_transition State.Authentication State.Run State.Authentication;
  check_transition State.Failed State.Hello State.Failed;
  check_transition State.Connected State.Reset State.Connected

let has_more () =
  (* A Pull with has_more keeps streaming. *)
  check_transition ~has_more:true State.Streaming State.Pull State.Streaming;
  check_transition ~has_more:true State.Streaming State.Discard State.Streaming;
  check_transition State.Streaming State.Pull State.Ready

let predicates () =
  check bool "failed" true (State.failed State.Failed);
  check bool "failed false" false (State.failed State.Ready);
  check bool "ready" true (State.ready State.Ready);
  check bool "ready false" false (State.ready State.Failed)

let tests =
  [
    ("[State] re_auth", [ test_case "5.1+ transitions" `Quick server_re_auth ]);
    ("[State] no_re_auth", [ test_case "<=5.0 transitions" `Quick server_no_re_auth ]);
    ("[State] unknown", [ test_case "unknown transitions" `Quick unknown_transitions ]);
    ("[State] has_more", [ test_case "streaming with has_more" `Quick has_more ]);
    ("[State] predicates", [ test_case "failed/ready" `Quick predicates ]);
  ]
