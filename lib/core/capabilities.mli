(** Per-version Bolt protocol capabilities.

    See capabilities.ml for the implementation. *)

type t = {
  supports_multiple_results : bool;
  supports_multiple_databases : bool;
  supports_re_auth : bool;
  supports_notification_filtering : bool;
  supports_route_message : bool;
  supports_ssr : bool;
  supports_telemetry : bool;
}
(** Protocol features available for a given Bolt version. *)

val of_version : int -> int -> t
(** The capabilities of a Bolt [major].[minor] version. *)
