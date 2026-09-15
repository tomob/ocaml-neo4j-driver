(* Features reported by the TestKit backend.

   The harness skips every test that needs a feature not listed here. The list
   grows as the driver API matures: B0b reports the Bolt protocol versions the
   driver speaks and the implemented result / server-info commands. *)

let features : string list =
  [
    (* Bolt protocol versions the driver supports. *)
    "Feature:Bolt:3.0";
    "Feature:Bolt:4.2";
    "Feature:Bolt:4.3";
    "Feature:Bolt:4.4";
    "Feature:Bolt:5.0";
    "Feature:Bolt:5.1";
    "Feature:Bolt:5.2";
    "Feature:Bolt:5.3";
    "Feature:Bolt:5.4";
    "Feature:Bolt:5.5";
    "Feature:Bolt:5.6";
    "Feature:Bolt:5.7";
    "Feature:Bolt:5.8";
    "Feature:Bolt:6.0";
    "Feature:Bolt:6.1";
    "Feature:Bolt:HandshakeManifestV1";
    "Feature:API:Driver.ExecuteQuery";
    "Feature:API:Driver:GetServerInfo";
    "Feature:API:Driver:MaxConnectionLifetime";
    "Feature:API:Driver:NotificationsConfig";
    "Feature:API:Driver.VerifyConnectivity";
    "Feature:API:ConnectionAcquisitionTimeout";
    "Feature:API:Liveness.Check";
    "Feature:API:Result.List";
    "Feature:API:Result.Peek";
    "Feature:API:Result.Single";
    "Feature:API:Result.SingleOptional";
    "Feature:API:RetryableExceptions";
    "Feature:API:Session:NotificationsConfig";
    "Feature:API:Summary:GqlStatusObjects";
    "Feature:API:Type.Spatial";
    "Feature:API:Type.Temporal";
    "Feature:API:Type.UnsupportedType";
    "Feature:API:Type.Vector";
    "Feature:API:Type.UUID";
    "Optimization:ConnectionReuse";
    "Optimization:EagerTransactionBegin";
    "Optimization:ExecuteQueryPipelining";
    "Optimization:ImplicitDefaultArguments";
    "Optimization:MinimalResets";
    "Optimization:HomeDatabaseCache";
    "Optimization:HomeDbCacheBasicPrincipalIsImpersonatedUser";
    "Optimization:PullPipelining";
    "Optimization:ResultListFetchAll";
    "AuthorizationExpiredTreatment";
    "Backend:RTFetch";
    "Backend:RTForceUpdate";
    "Backend:MockTime";
    "Feature:API:Driver.VerifyAuthentication";
    "ConfHint:connection.recv_timeout_seconds";
    "Feature:Bolt:Patch:UTC";
    "Feature:API:BookmarkManager";
    "Feature:API:Driver.ExecuteQuery";
    "Feature:API:Driver.ExecuteQuery:WithAuth";
    "Feature:Auth:Managed";
    "Feature:Auth:Bearer";
    "Feature:Auth:Custom";
    "Feature:Auth:Kerberos";
    "Feature:API:Session:AuthConfig";
    "Feature:API:Driver.SupportsSessionAuth";
    "Feature:Impersonation";
    "Feature:IdempotentRetries";
  ]
