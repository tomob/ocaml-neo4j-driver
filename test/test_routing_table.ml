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

let rt_value ?(ttl = 300L) ?db servers =
  let fields =
    [ ("ttl", Packstream.Int ttl); ("servers", Packstream.List servers) ]
    @ match db with Some db -> [ ("db", Packstream.String db) ] | None -> []
  in
  Packstream.Map fields

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

(* Full deactivation drops the address from every role and keeps the TTL. *)
let remove_address_drops_all_roles () =
  let addr host = Addressing.of_host_port host 7687 in
  let table =
    match
      Routing_table.parse
        (rt_value ~ttl:42L
           [
             server [ "r1:7687"; "r2:7687" ] "ROUTE";
             server [ "r1:7687" ] "READ";
             server [ "r1:7687"; "r3:7687" ] "WRITE";
           ])
    with
    | Some table -> table
    | None -> fail "expected a table"
  in
  let table = Routing_table.remove_address (addr "r1") table in
  check int "ttl kept" 42 (Routing_table.ttl_seconds table);
  check int "routers" 1 (List.length (Routing_table.routers table));
  check int "readers" 0 (List.length (Routing_table.readers table));
  check int "writers" 1 (List.length (Routing_table.writers table));
  check bool "router r2 kept" true
    (List.mem "r2:7687" (List.map Addressing.to_string (Routing_table.routers table)));
  check bool "writer r3 kept" true
    (List.mem "r3:7687" (List.map Addressing.to_string (Routing_table.writers table)))

(* remove_writer drops the address from the writers only. *)
let remove_writer_drops_writers_only () =
  let addr host = Addressing.of_host_port host 7687 in
  let table =
    match
      Routing_table.parse
        (rt_value
           [
             server [ "r1:7687" ] "ROUTE"; server [ "r2:7687" ] "READ"; server [ "r1:7687" ] "WRITE";
           ])
    with
    | Some table -> table
    | None -> fail "expected a table"
  in
  let table = Routing_table.remove_writer (addr "r1") table in
  check int "routers kept" 1 (List.length (Routing_table.routers table));
  check int "readers kept" 1 (List.length (Routing_table.readers table));
  check int "writers" 0 (List.length (Routing_table.writers table))

(* Removing an address that is not in the table changes nothing. *)
let remove_address_absent_is_noop () =
  let addr host = Addressing.of_host_port host 7687 in
  let table =
    match
      Routing_table.parse
        (rt_value
           [
             server [ "r1:7687" ] "ROUTE"; server [ "r1:7687" ] "READ"; server [ "r1:7687" ] "WRITE";
           ])
    with
    | Some table -> table
    | None -> fail "expected a table"
  in
  let table = Routing_table.remove_address (addr "nope") table in
  check int "routers" 1 (List.length (Routing_table.routers table));
  check int "readers" 1 (List.length (Routing_table.readers table));
  check int "writers" 1 (List.length (Routing_table.writers table))

(* The optional [db] field of an [rt] value is captured as the table's
   database (the server's home database for a default-database fetch). *)
let parse_database_field () =
  let base = [ server [ "r1:7687" ] "ROUTE"; server [ "r1:7687" ] "READ" ] in
  (match Routing_table.parse (rt_value ~db:"homedb" base) with
  | Some table ->
      check (option string) "database from rt" (Some "homedb") (Routing_table.database table)
  | None -> fail "expected a table");
  (match Routing_table.parse (rt_value base) with
  | Some table -> check (option string) "no db field" None (Routing_table.database table)
  | None -> fail "expected a table");
  (* A non-string [db] is ignored. *)
  match Routing_table.parse (Map [ ("ttl", Int 1L); ("servers", List []); ("db", Int 3L) ]) with
  | Some table -> check (option string) "non-string db" None (Routing_table.database table)
  | None -> fail "expected a table"

(* remove_address and remove_writer keep the table's database. *)
let removals_keep_database () =
  let table =
    match
      Routing_table.parse
        (rt_value ~db:"homedb"
           [
             server [ "r1:7687" ] "ROUTE"; server [ "r2:7687" ] "READ"; server [ "r1:7687" ] "WRITE";
           ])
    with
    | Some table -> table
    | None -> fail "expected a table"
  in
  let table = Routing_table.remove_address (Addressing.of_host_port "r1" 7687) table in
  check (option string) "database after remove_address" (Some "homedb")
    (Routing_table.database table);
  let table = Routing_table.remove_writer (Addressing.of_host_port "r1" 7687) table in
  check (option string) "database after remove_writer" (Some "homedb")
    (Routing_table.database table)

let tests =
  [
    ("[RoutingTable] parse_valid", [ test_case "roles and addresses" `Quick parse_valid ]);
    ("[RoutingTable] parse_skips_bad", [ test_case "unknown roles ignored" `Quick parse_skips_bad ]);
    ("[RoutingTable] parse_malformed", [ test_case "malformed values" `Quick parse_malformed ]);
    ("[RoutingTable] parse_database_field", [ test_case "db captured" `Quick parse_database_field ]);
    ( "[RoutingTable] removals_keep_database",
      [ test_case "db preserved by removals" `Quick removals_keep_database ] );
    ( "[RoutingTable] least_loaded_picks_min",
      [ test_case "minimum load" `Quick least_loaded_picks_min ] );
    ( "[RoutingTable] least_loaded_ties_first",
      [ test_case "ties broken by order" `Quick least_loaded_ties_first ] );
    ("[RoutingTable] least_loaded_empty", [ test_case "empty role" `Quick least_loaded_empty ]);
    ( "[RoutingTable] remove_address_drops_all_roles",
      [ test_case "full deactivation" `Quick remove_address_drops_all_roles ] );
    ( "[RoutingTable] remove_writer_drops_writers_only",
      [ test_case "writer removal" `Quick remove_writer_drops_writers_only ] );
    ( "[RoutingTable] remove_address_absent_is_noop",
      [ test_case "absent address" `Quick remove_address_absent_is_noop ] );
  ]
