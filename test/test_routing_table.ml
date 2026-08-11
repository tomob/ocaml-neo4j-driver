(* Unit tests for Routing_table: parsing an [rt] value and round-robin address
   selection. *)

open Neodriver
open Alcotest

let server addresses role =
  Packstream.Map
    [
      ("addresses", Packstream.List (List.map (fun a -> Packstream.String a) addresses));
      ("role", Packstream.String role);
    ]

let rt_value ?(ttl = 300L) servers =
  Packstream.Map [ ("ttl", Packstream.Int ttl); ("servers", Packstream.List servers) ]

let parse_valid () =
  let value =
    rt_value
      [
        server [ "router1:7687"; "router2:7687" ] "ROUTE";
        server [ "reader1:7687" ] "READ";
        server [ "writer1:7687"; "writer2:7687" ] "WRITE";
      ]
  in
  match Routing_table.parse value with
  | None -> fail "expected a table"
  | Some table ->
      check int "ttl" 300 (Routing_table.ttl_seconds table);
      check int "routers" 2 (List.length (Routing_table.routers table));
      check int "readers" 1 (List.length (Routing_table.readers table));
      check int "writers" 2 (List.length (Routing_table.writers table));
      check string "reader host" "reader1" (Addressing.host (List.hd (Routing_table.readers table)));
      check int "reader port" 7687 (Addressing.port (List.hd (Routing_table.readers table)))

(* Unknown roles and bad addresses are ignored. *)
let parse_skips_bad () =
  let value =
    rt_value
      [
        server [ "router:badport" ] "ROUTE";
        server [ "reader1:7687" ] "LEADER";
        server [ "writer1:7687" ] "WRITE";
      ]
  in
  match Routing_table.parse value with
  | None -> fail "expected a table"
  | Some table ->
      check int "no routers" 0 (List.length (Routing_table.routers table));
      check int "no readers" 0 (List.length (Routing_table.readers table));
      check int "one writer" 1 (List.length (Routing_table.writers table))

(* Malformed values are not parseable. *)
let parse_malformed () =
  check bool "missing servers" false
    (Option.is_some (Routing_table.parse (Map [ ("ttl", Int 1L) ])));
  check bool "ttl not int" false
    (Option.is_some (Routing_table.parse (Map [ ("ttl", String "x") ])));
  check bool "not a map" false (Option.is_some (Routing_table.parse (String "nope")));
  check bool "empty" false (Option.is_some (Routing_table.parse (Map [])))

(* Round-robin alternates over the addresses of a role. *)
let pick_round_robin () =
  let table =
    match Routing_table.parse (rt_value [ server [ "r1:7687"; "r2:7687"; "r3:7687" ] "READ" ]) with
    | Some table -> table
    | None -> fail "expected a table"
  in
  let counter = ref 0 in
  let host () =
    Addressing.host (Option.get (Routing_table.pick counter (Routing_table.readers table)))
  in
  check string "first" "r1" (host ());
  check string "second" "r2" (host ());
  check string "third" "r3" (host ());
  check string "wraps" "r1" (host ())

(* An empty role yields no address. *)
let pick_empty () =
  let table =
    match Routing_table.parse (rt_value [ server [ "r1:7687" ] "ROUTE" ]) with
    | Some table -> table
    | None -> fail "expected a table"
  in
  check bool "no readers" true
    (Option.is_none (Routing_table.pick (ref 0) (Routing_table.readers table)))

let tests =
  [
    ("[RoutingTable] parse_valid", [ test_case "roles and addresses" `Quick parse_valid ]);
    ("[RoutingTable] parse_skips_bad", [ test_case "unknown roles ignored" `Quick parse_skips_bad ]);
    ("[RoutingTable] parse_malformed", [ test_case "malformed values" `Quick parse_malformed ]);
    ("[RoutingTable] pick_round_robin", [ test_case "round robin" `Quick pick_round_robin ]);
    ("[RoutingTable] pick_empty", [ test_case "empty role" `Quick pick_empty ]);
  ]
