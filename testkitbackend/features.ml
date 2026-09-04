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
    (* Implemented API surface (B0b). *)
    "Feature:API:Driver:GetServerInfo";
    "Feature:API:Driver.VerifyConnectivity";
    "Feature:API:Result.List";
    "Feature:API:Result.Peek";
    "Feature:API:Result.Single";
    "Feature:API:Result.SingleOptional";
    "Feature:API:Summary:GqlStatusObjects";
    "Feature:API:Type.Spatial";
    "Feature:API:Type.Temporal";
    "Feature:API:Type.UnsupportedType";
    "Feature:API:Type.Vector";
    "Feature:API:Type.UUID";
    (* BEGIN is sent eagerly when the transaction starts. *)
    "Optimization:EagerTransactionBegin";
    (* A clean connection is released without a RESET (reset happens lazily on
       reuse, or to recover a FAILED connection on release). *)
    "Optimization:MinimalResets";
    (* On a Neo.ClientError.Security.AuthorizationExpired no connection is
       reused for anything but finishing a started job: the driver marks every
       connection unauthenticated and re-establishes auth on its next use. *)
    "AuthorizationExpiredTreatment";
    (* Test-support commands for the stub routing suite. *)
    "Backend:RTFetch";
    (* GetRoutingTable *)
    "Backend:RTForceUpdate";
    (* ForcedRoutingTableUpdate *)
    (* The backend can mock the system time (FakeTimeInstall / FakeTimeTick /
       FakeTimeUninstall), used to test time-dependent behaviour. *)
    "Backend:MockTime";
    (* The driver's verify_authentication API (a read connection is opened with
       the given token; authentication errors answer false, others propagate). *)
    "Feature:API:Driver.VerifyAuthentication";
    (* The server's [connection.recv_timeout_seconds] HELLO hint is honoured as
       the connection's receive timeout. *)
    "ConfHint:connection.recv_timeout_seconds";
    (* Auth token managers (phase A8): NewAuthTokenManager /
       NewBasicAuthTokenManager / NewBearerAuthTokenManager and the driver
       authTokenManagerId. *)
    "Feature:Auth:Managed";
    "Feature:Auth:Bearer";
    (* Auth token schemes carried verbatim in the HELLO/LOGON auth map:
       custom (scheme + principal + credentials + realm + parameters) and
       Kerberos (scheme + credentials). *)
    "Feature:Auth:Custom";
    "Feature:Auth:Kerberos";
    (* Session-level auth (user switching): NewSession with authorizationToken,
       CheckSessionAuthSupport. *)
    "Feature:API:Session:AuthConfig";
    "Feature:API:Driver.SupportsSessionAuth";
  ]
