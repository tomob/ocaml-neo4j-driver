(* Features reported by the TestKit backend.

   The harness skips every test that needs a feature not listed here. B0a only
   implements the connection-configuration commands (no queries, transactions or
   routing yet), so the list is empty; it grows as the driver API matures. *)

let features : string list = []
