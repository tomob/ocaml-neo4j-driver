(* Attribute declarations shared by the decoders and the parameter encoder. *)

open Ppxlib

let alias =
  Attribute.declare "neo4j.alias" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload (estring __))
    (fun alias -> alias)

let skip = Attribute.declare_flag "neo4j.skip" Attribute.Context.label_declaration
let missing_none = Attribute.declare_flag "neo4j.missing_none" Attribute.Context.label_declaration
let nested = Attribute.declare_flag "neo4j.nested" Attribute.Context.label_declaration
let uuid = Attribute.declare_flag "neo4j.uuid" Attribute.Context.label_declaration
let known = [ "neo4j.alias"; "neo4j.skip"; "neo4j.missing_none"; "neo4j.nested"; "neo4j.uuid" ]

let check_field field =
  List.iter
    (fun attribute ->
      let name = attribute.attr_name.txt in
      if String.starts_with ~prefix:"neo4j." name && not (List.mem name known) then
        Location.raise_errorf ~loc:attribute.attr_loc "neo4j: unknown attribute [@%s]" name)
    field.pld_attributes

let check_type declaration =
  List.iter
    (fun attribute ->
      let name = attribute.attr_name.txt in
      if String.starts_with ~prefix:"neo4j." name then
        Location.raise_errorf ~loc:attribute.attr_loc
          "neo4j: [@%s] is only allowed on record fields" name)
    declaration.ptype_attributes

let check_aliases ~loc aliases =
  let rec loop seen = function
    | [] -> ()
    | alias :: rest ->
        if List.mem alias seen then
          Location.raise_errorf ~loc "neo4j: duplicate field/parameter alias %S" alias
        else loop (alias :: seen) rest
  in
  loop [] aliases
