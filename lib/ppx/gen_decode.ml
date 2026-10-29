(* [@@deriving neo4j]: <type>_decoder and <type>_aliases. *)

open Ppxlib

let error ~loc format = Location.raise_errorf ~loc ("neo4j: " ^^ format)

let rec decoder_of_type ~loc = function
  | Ty.String -> [%expr Neodriver_core.Decode.string]
  | Ty.Bool -> [%expr Neodriver_core.Decode.bool]
  | Ty.Int -> [%expr Neodriver_core.Decode.int]
  | Ty.Int64 -> [%expr Neodriver_core.Decode.int64]
  | Ty.Float -> [%expr Neodriver_core.Decode.float]
  | Ty.Bytes -> [%expr Neodriver_core.Decode.bytes]
  | Ty.Uuid -> [%expr Neodriver_core.Decode.uuid]
  | Ty.Date -> [%expr Neodriver_core.Decode.date]
  | Ty.Time -> [%expr Neodriver_core.Decode.time]
  | Ty.DateTime -> [%expr Neodriver_core.Decode.datetime]
  | Ty.Duration -> [%expr Neodriver_core.Decode.duration]
  | Ty.Point -> [%expr Neodriver_core.Decode.point]
  | Ty.Vector -> [%expr Neodriver_core.Decode.vector]
  | Ty.Node -> [%expr Neodriver_core.Decode.node]
  | Ty.Relationship -> [%expr Neodriver_core.Decode.relationship]
  | Ty.Unbound_relationship -> [%expr Neodriver_core.Decode.unbound_relationship]
  | Ty.Path -> [%expr Neodriver_core.Decode.path]
  | Ty.Raw -> [%expr Neodriver_core.Decode.raw]
  | Ty.List inner -> [%expr Neodriver_core.Decode.list [%e decoder_of_type ~loc inner]]
  | Ty.Option inner -> [%expr Neodriver_core.Decode.option [%e decoder_of_type ~loc inner]]
  | Ty.Nested name -> Ast_builder.Default.evar ~loc (name ^ "_decoder")

type field = { label : string; alias : string; decoder : expression; required : bool }

let field_of_label label_declaration =
  let loc = label_declaration.pld_loc in
  Attrs.check_field label_declaration;
  let label = label_declaration.pld_name.txt in
  let alias = Option.value ~default:label (Attribute.get Attrs.alias label_declaration) in
  (* [@neo4j.skip] only affects the parameter encoder; the field is still decoded. *)
  let _skip = Attribute.has_flag Attrs.skip label_declaration in
  let missing_none = Attribute.has_flag Attrs.missing_none label_declaration in
  let nested = Attribute.has_flag Attrs.nested label_declaration in
  let uuid = Attribute.has_flag Attrs.uuid label_declaration in
  if nested && uuid then error ~loc "[@neo4j.nested] and [@neo4j.uuid] cannot be combined";
  let ty = Ty.of_core_type ~loc ~nested ~uuid label_declaration.pld_type in
  match (missing_none, ty) with
  | true, Ty.Option inner ->
      {
        label;
        alias;
        decoder =
          [%expr
            Neodriver_core.Decode.field_opt
              [%e Ast_builder.Default.estring ~loc alias]
              [%e decoder_of_type ~loc inner]];
        required = false;
      }
  | true, _ -> error ~loc "[@neo4j.missing_none] requires an option field"
  | false, ty ->
      {
        label;
        alias;
        decoder =
          [%expr
            Neodriver_core.Decode.field
              [%e Ast_builder.Default.estring ~loc alias]
              [%e decoder_of_type ~loc ty]];
        required = true;
      }

let record_expression ~loc fields =
  Ast_builder.Default.pexp_record ~loc
    (List.map
       (fun field ->
         ( Ast_builder.Default.Located.lident ~loc field.label,
           Ast_builder.Default.evar ~loc field.label ))
       fields)
    None

let rec combine ~loc = function
  | [] -> assert false
  | [ field ] -> (Ast_builder.Default.pvar ~loc field.label, field.decoder)
  | field :: rest ->
      let pattern, expression = combine ~loc rest in
      ( Ast_builder.Default.ppat_tuple ~loc [ Ast_builder.Default.pvar ~loc field.label; pattern ],
        [%expr Neodriver_core.Decode.both [%e field.decoder] [%e expression]] )

let decoder_expression ~loc fields =
  let pattern, expression = combine ~loc fields in
  [%expr
    Neodriver_core.Decode.map
      (fun [%p pattern] -> [%e record_expression ~loc fields])
      [%e expression]]

let type_expression ~loc name = Ast_builder.Default.ptyp_constr ~loc { loc; txt = Lident name } []

let aliases_expression ~loc fields =
  Ast_builder.Default.elist ~loc
    (List.filter_map
       (fun field ->
         if field.required then Some (Ast_builder.Default.estring ~loc field.alias) else None)
       fields)

let generate_type declaration fields =
  let loc = declaration.ptype_loc in
  let name = declaration.ptype_name.txt in
  let decoder_type = [%type: [%t type_expression ~loc name] Neodriver_core.Decode.t] in
  let decoder =
    Ast_builder.Default.pstr_value ~loc Nonrecursive
      [
        Ast_builder.Default.value_binding ~loc
          ~pat:(Ast_builder.Default.pvar ~loc (name ^ "_decoder"))
          ~expr:[%expr ([%e decoder_expression ~loc fields] : [%t decoder_type])];
      ]
  in
  let aliases =
    Ast_builder.Default.pstr_value ~loc Nonrecursive
      [
        Ast_builder.Default.value_binding ~loc
          ~pat:(Ast_builder.Default.pvar ~loc (name ^ "_aliases"))
          ~expr:(aliases_expression ~loc fields);
      ]
  in
  [ decoder; aliases ]

let generate ~rec_flag:_ declarations =
  match declarations with
  | [] -> []
  | [ declaration ] -> (
      Attrs.check_type declaration;
      match declaration.ptype_kind with
      | Ptype_record fields ->
          let name = declaration.ptype_name.txt in
          if declaration.ptype_params <> [] then
            error ~loc:declaration.ptype_loc "polymorphic record types are not supported";
          if fields = [] then
            error ~loc:declaration.ptype_loc "empty record types are not supported";
          if List.exists (fun field -> Ty.mentions_unqualified name field.pld_type) fields then
            error ~loc:declaration.ptype_loc
              "recursive record types are not supported; declare each record separately";
          let fields = List.map field_of_label fields in
          Attrs.check_aliases ~loc:declaration.ptype_loc
            (List.map (fun field -> field.alias) fields);
          generate_type declaration fields
      | _ -> error ~loc:declaration.ptype_loc "%s must be a record type" declaration.ptype_name.txt)
  | declaration :: _ ->
      error ~loc:declaration.ptype_loc
        "type groups with multiple declarations are not supported; declare each record separately"
