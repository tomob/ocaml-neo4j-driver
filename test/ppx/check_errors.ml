(* Compile-time errors emitted by the derivers. The test expands a parsed
   structure in-process, so it does not need a nested dune project. *)

open Ppxlib
open Alcotest

let expand code =
  let structure = Parse.implementation (Lexing.from_string code) in
  Driver.map_structure structure

let expect_error name code =
  match expand code with
  | _ -> fail (name ^ ": expected a ppx error")
  | exception Location.Error error ->
      check bool name true (String.length (Location.Error.message error) > 0)

let tests =
  [
    ( "[Ppx errors] unsupported",
      [
        test_case "unsupported field type" `Quick (fun () ->
            expect_error "unsupported type" "type bad = { x : Unsupported.t } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] missing_none",
      [
        test_case "missing_none on non-option" `Quick (fun () ->
            expect_error "missing_none"
              "type bad = { x : string [@neo4j.missing_none] } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] nested_uuid",
      [
        test_case "nested + uuid" `Quick (fun () ->
            expect_error "nested + uuid"
              "type bad = { x : string [@neo4j.nested] [@neo4j.uuid] } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] recursive",
      [
        test_case "recursive record" `Quick (fun () ->
            expect_error "recursive"
              "type bad = { next : bad option [@neo4j.nested] } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] group",
      [
        test_case "multiple declarations" `Quick (fun () ->
            expect_error "group" "type a = { x : string } and b = { y : string } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] not_record",
      [
        test_case "variant type" `Quick (fun () ->
            expect_error "variant" "type bad = A | B [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] unknown_attribute",
      [
        test_case "unknown neo4j attribute" `Quick (fun () ->
            expect_error "unknown attribute"
              "type bad = { x : string [@neo4j.unknown] } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] duplicate_alias",
      [
        test_case "duplicate alias" `Quick (fun () ->
            expect_error "duplicate alias"
              "type bad = { a : string [@neo4j.alias \"x\"]; b : string [@neo4j.alias \"x\"] } \
               [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] uuid",
      [
        test_case "uuid on non-string" `Quick (fun () ->
            expect_error "uuid" "type bad = { x : int [@neo4j.uuid] } [@@deriving neo4j]");
      ] );
    ( "[Ppx errors] graph_param",
      [
        test_case "graph value as a parameter" `Quick (fun () ->
            expect_error "graph param" "type bad = { x : Values.node } [@@deriving neo4j_params]");
      ] );
  ]

let () = Alcotest.run "neodriver_ppx_errors" tests
