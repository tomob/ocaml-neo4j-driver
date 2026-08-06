(* Per-version Bolt protocol capabilities.

   Modeled on the Neo4j Python driver's per-protocol-version feature flags
   (_async/io/_bolt3.py ... _bolt6.py). The thresholds:

   - multiple results ([qid]) and multiple databases ([db]): Bolt 4.0
   - LOGON/LOGOFF (re-auth): Bolt 5.1
   - notification filtering: Bolt 5.2
   - the ROUTE message (server-side routing): Bolt 4.3
   - the TELEMETRY message: Bolt 5.4 *)

type t = {
  supports_multiple_results : bool;
  supports_multiple_databases : bool;
  supports_re_auth : bool;
  supports_notification_filtering : bool;
  supports_ssr : bool;
  supports_telemetry : bool;
}

let of_version major minor =
  let at_least m n = major > m || (major = m && minor >= n) in
  {
    supports_multiple_results = major >= 4;
    supports_multiple_databases = major >= 4;
    supports_re_auth = at_least 5 1;
    supports_notification_filtering = at_least 5 2;
    supports_ssr = at_least 4 3;
    supports_telemetry = at_least 5 4;
  }
