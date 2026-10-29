(* [@@deriving neo4j_params]: <type>_params. *)

open Ppxlib

let error ~loc format = Location.raise_errorf ~loc ("neo4j: " ^^ format)

let rec value_of_type ~loc ty expression =
  match ty with
  | Ty.String -> [%expr Neodriver_core.Values.String [%e expression]]
  | Ty.Bool -> [%expr Neodriver_core.Values.Bool [%e expression]]
  | Ty.Int -> [%expr Neodriver_core.Values.Int (Stdlib.Int64.of_int [%e expression])]
  | Ty.Int64 -> [%expr Neodriver_core.Values.Int [%e expression]]
  | Ty.Float -> [%expr Neodriver_core.Values.Float [%e expression]]
  | Ty.Bytes -> [%expr Neodriver_core.Values.Bytes [%e expression]]
  | Ty.Uuid -> [%expr Neodriver_core.Values.Uuid [%e expression]]
  | Ty.Date -> [%expr Neodriver_core.Values.Date [%e expression]]
  | Ty.Time -> [%expr Neodriver_core.Values.Time [%e expression]]
  | Ty.DateTime -> [%expr Neodriver_core.Values.DateTime [%e expression]]
  | Ty.Duration -> [%expr Neodriver_core.Values.Duration [%e expression]]
  | Ty.Point -> [%expr Neodriver_core.Values.Point [%e expression]]
  | Ty.Vector -> [%expr Neodriver_core.Values.Vector [%e expression]]
  | Ty.Raw -> expression
  | Ty.Node | Ty.Relationship | Ty.Unbound_relationship | Ty.Path ->
      error ~loc
        "graph values cannot be used as query parameters; pass a nested record or Values.Map"
  | Ty.List inner ->
      let item = gen_symbol ~prefix:"item" () in
      [%expr
        Neodriver_core.Values.List
          (Stdlib.List.map
             (fun [%p Ast_builder.Default.pvar ~loc item] ->
               [%e value_of_type ~loc inner (Ast_builder.Default.evar ~loc item)])
             [%e expression])]
  | Ty.Option inner ->
      let item = gen_symbol ~prefix:"item" () in
      [%expr
        match [%e expression] with
        | None -> Neodriver_core.Values.Null
        | Some [%p Ast_builder.Default.pvar ~loc item] ->
            [%e value_of_type ~loc inner (Ast_builder.Default.evar ~loc item)]]
  | Ty.Nested name ->
      [%expr
        Neodriver_core.Values.Map
          ([%e Ast_builder.Default.evar ~loc (name ^ "_params")] [%e expression])]

type parameter = { alias : string; value : expression }

let parameter_of_label label_declaration value_name =
  let loc = label_declaration.pld_loc in
  Attrs.check_field label_declaration;
  let alias =
    Option.value ~default:label_declaration.pld_name.txt
      (Attribute.get Attrs.alias label_declaration)
  in
  let skip = Attribute.has_flag Attrs.skip label_declaration in
  let _missing_none = Attribute.has_flag Attrs.missing_none label_declaration in
  let nested = Attribute.has_flag Attrs.nested label_declaration in
  let uuid = Attribute.has_flag Attrs.uuid label_declaration in
  if skip then None
  else (
    if nested && uuid then error ~loc "[@neo4j.nested] and [@neo4j.uuid] cannot be combined";
    let ty = Ty.of_core_type ~loc ~nested ~uuid label_declaration.pld_type in
    let field =
      Ast_builder.Default.pexp_field ~loc
        (Ast_builder.Default.evar ~loc value_name)
        (Ast_builder.Default.Located.lident ~loc label_declaration.pld_name.txt)
    in
    Some { alias; value = value_of_type ~loc ty field })

let params_expression ~loc parameters =
  Ast_builder.Default.elist ~loc
    (Stdlib.List.map
       (fun parameter ->
         [%expr [%e Ast_builder.Default.estring ~loc parameter.alias], [%e parameter.value]])
       parameters)

let type_expression ~loc name = Ast_builder.Default.ptyp_constr ~loc { loc; txt = Lident name } []

let generate_type declaration fields =
  let loc = declaration.ptype_loc in
  let name = declaration.ptype_name.txt in
  let value_name = gen_symbol ~prefix:"value" () in
  let parameters = List.filter_map (fun field -> parameter_of_label field value_name) fields in
  Attrs.check_aliases ~loc (List.map (fun parameter -> parameter.alias) parameters);
  let pattern =
    if parameters = [] then Ast_builder.Default.ppat_any ~loc
    else Ast_builder.Default.pvar ~loc value_name
  in
  let expression =
    [%expr
      fun ([%p pattern] : [%t type_expression ~loc name]) -> [%e params_expression ~loc parameters]]
  in
  [
    Ast_builder.Default.pstr_value ~loc Nonrecursive
      [
        Ast_builder.Default.value_binding ~loc
          ~pat:(Ast_builder.Default.pvar ~loc (name ^ "_params"))
          ~expr:expression;
      ];
  ]

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
          generate_type declaration fields
      | _ -> error ~loc:declaration.ptype_loc "%s must be a record type" declaration.ptype_name.txt)
  | declaration :: _ ->
      error ~loc:declaration.ptype_loc
        "type groups with multiple declarations are not supported; declare each record separately"
