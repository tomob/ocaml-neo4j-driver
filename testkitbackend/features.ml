(* Features reported by the TestKit backend.

   The harness skips every test that needs a feature not listed here. The list
   grows as the driver API matures: B0b reports the Bolt protocol versions the
   driver speaks and the implemented result / server-info commands. *)

let features : string list =
  [
    (* Bolt protocol versions the driver supports. *)
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
  ]
