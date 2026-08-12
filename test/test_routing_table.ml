(* Unit tests for Routing_table: parsing an [rt] value and least-loaded address
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

(* Least-loaded selection picks the address with the smallest load. *)
let least_loaded_picks_min () =
  let addresses =
    [
      Addressing.of_host_port "r1" 7687;
      Addressing.of_host_port "r2" 7687;
      Addressing.of_host_port "r3" 7687;
    ]
  in
  let host addr = Addressing.host (Option.get addr) in
  let pick loads =
    let load addr = List.assoc (Addressing.host addr) loads in
    host (Routing_table.least_loaded ~load addresses)
  in
  check string "single min" "r2" (pick [ ("r1", 2); ("r2", 0); ("r3", 1) ]);
  check string "re-chooses the new min" "r2" (pick [ ("r1", 3); ("r2", 1); ("r3", 2) ])

(* Ties are broken by list order (deterministic). *)
let least_loaded_ties_first () =
  let addresses =
    [
      Addressing.of_host_port "r1" 7687;
      Addressing.of_host_port "r2" 7687;
      Addressing.of_host_port "r3" 7687;
    ]
  in
  let load addr = if Addressing.host addr = "r3" then 2 else 1 in
  match Routing_table.least_loaded ~load addresses with
  | Some addr -> check string "first tied address" "r1" (Addressing.host addr)
  | None -> fail "expected an address"

(* An empty role yields no address. *)
let least_loaded_empty () =
  check bool "no addresses" true
    (Option.is_none
       (Routing_table.least_loaded
          ~load:(fun _ -> 0)
          (Routing_table.readers
             (match Routing_table.parse (rt_value [ server [ "r1:7687" ] "ROUTE" ]) with
             | Some table -> table
             | None -> fail "expected a table"))))

let tests =
  [
    ("[RoutingTable] parse_valid", [ test_case "roles and addresses" `Quick parse_valid ]);
    ("[RoutingTable] parse_skips_bad", [ test_case "unknown roles ignored" `Quick parse_skips_bad ]);
    ("[RoutingTable] parse_malformed", [ test_case "malformed values" `Quick parse_malformed ]);
    ( "[RoutingTable] least_loaded_picks_min",
      [ test_case "minimum load" `Quick least_loaded_picks_min ] );
    ( "[RoutingTable] least_loaded_ties_first",
      [ test_case "ties broken by order" `Quick least_loaded_ties_first ] );
    ("[RoutingTable] least_loaded_empty", [ test_case "empty role" `Quick least_loaded_empty ]);
  ]
