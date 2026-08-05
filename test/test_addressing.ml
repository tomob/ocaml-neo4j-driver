open Neodriver
open Alcotest

let parse_ok s expected =
  match Addressing.parse s with
  | Ok address -> check string ("parse " ^ s) expected (Addressing.to_string address)
  | Error error -> fail (Errors.to_string error)

let parse () =
  parse_ok "localhost:7687" "localhost:7687";
  parse_ok "example.com" "example.com:7687";
  parse_ok ":17601" "localhost:17601";
  parse_ok "[::1]:7687" "[::1]:7687";
  parse_ok "[::1]" "[::1]:7687";
  parse_ok "localhost:" "localhost:7687";
  parse_ok "" "localhost:7687";
  parse_ok "h:0" "h:0";
  (match Addressing.parse ~default_host:"db" ~default_port:1234 "x" with
  | Ok address -> check string "custom port default" "x:1234" (Addressing.to_string address)
  | Error error -> fail (Errors.to_string error));
  (match Addressing.parse ~default_host:"db" ~default_port:1234 "" with
  | Ok address -> check string "custom host default" "db:1234" (Addressing.to_string address)
  | Error error -> fail (Errors.to_string error));
  (match Addressing.parse "host:banana" with
  | Ok _ -> fail "non-numeric port should be rejected"
  | Error _ -> ());
  (match Addressing.parse "[::1" with
  | Ok _ -> fail "unterminated IPv6 should be rejected"
  | Error _ -> ());
  match Addressing.parse "[::1]:banana" with
  | Ok _ -> fail "non-numeric IPv6 port should be rejected"
  | Error _ -> ()

let parse_list () =
  (match Addressing.parse_list [ "localhost:7687"; "[::1]:7687" ] with
  | Ok addresses ->
      check (list string) "parse_list"
        [ "localhost:7687"; "[::1]:7687" ]
        (List.map Addressing.to_string addresses)
  | Error error -> fail (Errors.to_string error));
  match Addressing.parse_list [ "host:bad" ] with
  | Ok _ -> fail "bad port in list should be rejected"
  | Error _ -> ()

let uri_ok uri expected_scheme expected_host expected_port =
  match Addressing.parse_uri uri with
  | Ok parsed ->
      check string "scheme" expected_scheme (Addressing.scheme_to_string parsed.scheme);
      check string "host" expected_host parsed.host;
      check int "port" expected_port parsed.port
  | Error error -> fail (Errors.to_string error)

let uri () =
  uri_ok "bolt://localhost:7687" "bolt" "localhost" 7687;
  uri_ok "bolt+s://db.example.com" "bolt+s" "db.example.com" 7687;
  uri_ok "neo4j://localhost:7687?policy=eu" "neo4j" "localhost" 7687;
  uri_ok "neo4j://[::1]:7687" "neo4j" "::1" 7687;
  uri_ok "neo4j://host/path?x=1" "neo4j" "host" 7687;
  uri_ok "NEO4J+S://host" "neo4j+s" "host" 7687;
  uri_ok "bolt+ssc://host" "bolt+ssc" "host" 7687;
  uri_ok "neo4j+ssc://[::1]:7687" "neo4j+ssc" "::1" 7687;
  (match Addressing.parse_uri "http://x" with
  | Ok _ -> fail "unsupported scheme should be rejected"
  | Error _ -> ());
  (match Addressing.parse_uri "bolt://user:pass@host" with
  | Ok _ -> fail "userinfo should be rejected"
  | Error _ -> ());
  (match Addressing.parse_uri "localhost:7687" with
  | Ok _ -> fail "missing scheme should be rejected"
  | Error _ -> ());
  match Addressing.parse_uri "host" with
  | Ok _ -> fail "missing scheme should be rejected"
  | Error _ -> ()

let routing_context () =
  (match Addressing.parse_routing_context "policy=eu&region=west" with
  | Ok context ->
      check (list (pair string string)) "context" [ ("policy", "eu"); ("region", "west") ] context
  | Error error -> fail (Errors.to_string error));
  (match Addressing.parse_routing_context "a=1&a=2" with
  | Ok _ -> fail "duplicate key should be rejected"
  | Error _ -> ());
  (match Addressing.parse_routing_context "a=" with
  | Ok _ -> fail "empty value should be rejected"
  | Error _ -> ());
  (match Addressing.parse_routing_context "a" with
  | Ok _ -> fail "missing '=' should be rejected"
  | Error _ -> ());
  match Addressing.parse_routing_context "name=neo4j%20driver&k=a+b" with
  | Ok context ->
      check (list (pair string string)) "decoded" [ ("name", "neo4j driver"); ("k", "a b") ] context
  | Error error -> fail (Errors.to_string error)

let resolved () =
  let resolved = Addressing.make_resolved (Addressing.IPv4 ("10.0.0.1", 7687)) "example.com" in
  check string "resolved host name" "example.com" (Addressing.resolved_host_name resolved);
  check string "unresolved" "example.com:7687"
    (Addressing.to_string (Addressing.unresolved resolved));
  let resolved6 = Addressing.make_resolved (Addressing.IPv6 ("::1", 7687, 0, 0)) "db.example.com" in
  check string "unresolved6" "[db.example.com]:7687"
    (Addressing.to_string (Addressing.unresolved resolved6))

let tests =
  [
    ("[Adressing] parse", [ test_case "address parsing" `Quick parse ]);
    ("[Adressing] parse_list", [ test_case "list parsing" `Quick parse_list ]);
    ("[Adressing] uri", [ test_case "uri parsing" `Quick uri ]);
    ("[Adressing] routing_context", [ test_case "routing context" `Quick routing_context ]);
    ("[Adressing] resolved", [ test_case "resolved address" `Quick resolved ]);
  ]
