(* The subset of OCaml types the derivers know how to encode and decode. *)

open Ppxlib

type t =
  | String
  | Bool
  | Int
  | Int64
  | Float
  | Bytes
  | Uuid
  | Date
  | Time
  | DateTime
  | Duration
  | Point
  | Vector
  | Node
  | Relationship
  | Unbound_relationship
  | Path
  | Raw
  | List of t
  | Option of t
  | Nested of string

let rec longident_name = function
  | Lident name -> name
  | Ldot (prefix, name) -> longident_name prefix ^ "." ^ name
  | Lapply _ -> "<functor>"

let ends_with suffix name = String.ends_with ~suffix name

let primitive name =
  match name with
  | "string" -> Some String
  | "bool" -> Some Bool
  | "int" -> Some Int
  | "int64" | "Int64.t" | "Stdlib.Int64.t" -> Some Int64
  | "float" -> Some Float
  | "bytes" | "Bytes.t" | "Stdlib.Bytes.t" -> Some Bytes
  | _ when ends_with "Temporal.Date.t" name || name = "Date.t" -> Some Date
  | _ when ends_with "Temporal.Time.t" name || name = "Time.t" -> Some Time
  | _ when ends_with "Temporal.DateTime.t" name || name = "DateTime.t" -> Some DateTime
  | _ when ends_with "Temporal.Duration.t" name || name = "Duration.t" -> Some Duration
  | _ when ends_with "Values.point" name -> Some Point
  | _ when ends_with "Values.vector" name -> Some Vector
  | _ when ends_with "Values.node" name -> Some Node
  | _ when ends_with "Values.relationship" name -> Some Relationship
  | _ when ends_with "Values.unbound_relationship" name -> Some Unbound_relationship
  | _ when ends_with "Values.path" name -> Some Path
  | _ when ends_with "Values.t" name -> Some Raw
  | _ -> None

let is_list name = name = "list" || name = "List.t" || name = "Stdlib.List.t"
let is_option name = name = "option" || name = "Option.t" || name = "Stdlib.Option.t"

let nested_name ~loc lid =
  match lid with
  | Lident name -> name
  | _ ->
      Location.raise_errorf ~loc "neo4j: [@neo4j.nested] requires an unqualified record type name"

let unsupported ~loc core_type =
  Location.raise_errorf ~loc
    "neo4j: unsupported type %s; use a supported value type or add [@neo4j.nested] for a record \
     type"
    (Format.asprintf "%a" Pprintast.core_type core_type)

let rec mentions_unqualified name core_type =
  match core_type.ptyp_desc with
  | Ptyp_constr (lid, arguments) ->
      (match lid.txt with Lident candidate -> candidate = name | _ -> false)
      || List.exists (mentions_unqualified name) arguments
  | Ptyp_tuple types -> List.exists (mentions_unqualified name) types
  | Ptyp_alias (type_, _) -> mentions_unqualified name type_
  | Ptyp_arrow (_, left, right) -> mentions_unqualified name left || mentions_unqualified name right
  | Ptyp_poly (_, type_) -> mentions_unqualified name type_
  | _ -> false

let rec of_core_type ~loc ~nested ~uuid core_type =
  match core_type.ptyp_desc with
  | Ptyp_constr (lid, arguments) -> (
      let name = longident_name lid.txt in
      match (arguments, uuid, nested) with
      | [ argument ], _, _ when is_list name -> List (of_core_type ~loc ~nested ~uuid argument)
      | [ argument ], _, _ when is_option name -> Option (of_core_type ~loc ~nested ~uuid argument)
      | [], true, _ ->
          if name = "string" then Uuid
          else
            Location.raise_errorf ~loc "neo4j: [@neo4j.uuid] requires a string field, not %s" name
      | [], false, true -> (
          match primitive name with
          | Some _ ->
              Location.raise_errorf ~loc
                "neo4j: [@neo4j.nested] is only for record types, but %s is a supported value type"
                name
          | None -> Nested (nested_name ~loc lid.txt))
      | [], false, false -> (
          match primitive name with Some value -> value | None -> unsupported ~loc core_type)
      | _ -> unsupported ~loc core_type)
  | _ -> unsupported ~loc core_type
