(* Unit tests for the per-version Bolt capabilities. *)

open Neodriver
open Alcotest

let caps major minor = Capabilities.of_version major minor

let thresholds () =
  let v3 = caps 3 5 in
  check bool "3.5 multiple_results" false v3.supports_multiple_results;
  check bool "3.5 multiple_databases" false v3.supports_multiple_databases;
  check bool "3.5 re_auth" false v3.supports_re_auth;
  check bool "3.5 notification_filtering" false v3.supports_notification_filtering;
  check bool "3.5 ssr" false v3.supports_ssr;
  check bool "3.5 route_message" false v3.supports_route_message;
  check bool "3.5 connection_context" false v3.supports_connection_context;
  check bool "3.5 telemetry" false v3.supports_telemetry;
  let v4_0 = caps 4 0 in
  check bool "4.0 multiple_results" true v4_0.supports_multiple_results;
  check bool "4.0 multiple_databases" true v4_0.supports_multiple_databases;
  check bool "4.0 ssr" false v4_0.supports_ssr;
  check bool "4.0 route_message" false v4_0.supports_route_message;
  check bool "4.0 connection_context" false v4_0.supports_connection_context;
  let v4_1 = caps 4 1 in
  check bool "4.1 connection_context" true v4_1.supports_connection_context;
  let v4_2 = caps 4 2 in
  check bool "4.2 connection_context" true v4_2.supports_connection_context;
  let v4_3 = caps 4 3 in
  check bool "4.3 ssr" true v4_3.supports_ssr;
  check bool "4.3 route_message" true v4_3.supports_route_message;
  let v5_0 = caps 5 0 in
  check bool "5.0 re_auth" false v5_0.supports_re_auth;
  check bool "5.0 connection_context" true v5_0.supports_connection_context;
  let v5_1 = caps 5 1 in
  check bool "5.1 re_auth" true v5_1.supports_re_auth;
  check bool "5.1 notification_filtering" false v5_1.supports_notification_filtering;
  let v5_2 = caps 5 2 in
  check bool "5.2 notification_filtering" true v5_2.supports_notification_filtering;
  check bool "5.2 telemetry" false v5_2.supports_telemetry;
  let v5_3 = caps 5 3 in
  check bool "5.3 telemetry" false v5_3.supports_telemetry;
  let v5_4 = caps 5 4 in
  check bool "5.4 telemetry" true v5_4.supports_telemetry;
  let v6_0 = caps 6 0 in
  check bool "6.0 re_auth" true v6_0.supports_re_auth;
  check bool "6.0 notification_filtering" true v6_0.supports_notification_filtering;
  check bool "6.0 ssr" true v6_0.supports_ssr;
  check bool "6.0 route_message" true v6_0.supports_route_message;
  check bool "6.0 connection_context" true v6_0.supports_connection_context;
  check bool "6.0 telemetry" true v6_0.supports_telemetry

let tests = [ ("[Capabilities] thresholds", [ test_case "version thresholds" `Quick thresholds ]) ]
