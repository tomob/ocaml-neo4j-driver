(* Per-version Bolt protocol capabilities.

   Modeled on the Neo4j Python driver's per-protocol-version feature flags
   (_async/io/_bolt3.py ... _bolt6.py). The thresholds:

   - multiple results ([qid]) and multiple databases ([db]): Bolt 4.0
   - LOGON/LOGOFF (re-auth): Bolt 5.1
   - notification filtering: Bolt 5.2
   - the ROUTE message: Bolt 4.3
   - server-side routing (ssr.enabled hint): Bolt 4.3
   - the routing context in HELLO (server-side routing): Bolt 4.1
   - the TELEMETRY message: Bolt 5.4
   - the GOODBYE message (client-initiated close): Bolt 4.4 *)

type t = {
  supports_multiple_results : bool;
  supports_multiple_databases : bool;
  supports_re_auth : bool;
  supports_notification_filtering : bool;
  supports_route_message : bool;
  supports_ssr : bool;
  supports_connection_context : bool;
  supports_telemetry : bool;
  supports_goodbye : bool;
}

let of_version major minor =
  let at_least m n = major > m || (major = m && minor >= n) in
  {
    supports_multiple_results = major >= 4;
    supports_multiple_databases = major >= 4;
    supports_re_auth = at_least 5 1;
    supports_notification_filtering = at_least 5 2;
    supports_route_message = at_least 4 3;
    supports_ssr = at_least 4 3;
    supports_connection_context = at_least 4 1;
    supports_telemetry = at_least 5 4;
    supports_goodbye = at_least 4 4;
  }
