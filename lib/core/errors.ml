(* Error taxonomy for the Neo4j driver.

   Phase A0 (see PLAN.md) will define the error hierarchy modelled on the
   Python driver's exceptions.py:
   - driver-level errors (ServiceUnavailable, SessionExpired, PoolTimeout, ...)
   - Neo4j server errors (ClientError, TransientError, DatabaseError)
   with retryable / unauthenticates-all / has-security-code classification. *)
