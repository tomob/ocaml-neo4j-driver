(* Typed decoding of query results. See decode.mli. *)

let ( let* ) = Result.bind

type env = Row of (string * Values.t) list | Value of Values.t
type 'a t = { run : env -> ('a, Errors.t) result; aliases : string list }

let decode_row decoder fields = decoder.run (Row fields)
let decode_value decoder value = decoder.run (Value value)
let aliases decoder = decoder.aliases

let row_of_values ~keys values =
  if List.length keys <> List.length values then
    Error
      (Errors.Broken_record_error
         (Printf.sprintf "record has %d value(s), result has %d field(s)" (List.length values)
            (List.length keys)))
  else Ok (List.combine keys values)

let check_keys ~keys decoder =
  let rec duplicates seen duplicated = function
    | [] -> List.rev duplicated
    | key :: rest ->
        if List.mem key seen then duplicates seen (key :: duplicated) rest
        else duplicates (key :: seen) duplicated rest
  in
  match duplicates [] [] keys with
  | _ :: _ as duplicated ->
      Error
        (Errors.Decode_error
           (Printf.sprintf "result has duplicate field name(s): %s" (String.concat ", " duplicated)))
  | [] -> (
      let missing = List.filter (fun key -> not (List.mem key keys)) (aliases decoder) in
      match missing with
      | [] -> Ok ()
      | _ ->
          Error
            (Errors.Decode_error
               (Printf.sprintf "decoder expects missing field(s): %s; result fields: %s"
                  (String.concat ", " missing)
                  (match keys with [] -> "none" | _ -> String.concat ", " keys))))

let type_name = function
  | Values.Null -> "Null"
  | Bool _ -> "Bool"
  | Int _ -> "Int"
  | Float _ -> "Float"
  | String _ -> "String"
  | Bytes _ -> "Bytes"
  | List _ -> "List"
  | Map _ -> "Map"
  | Node _ -> "Node"
  | Relationship _ -> "Relationship"
  | Unbound_relationship _ -> "UnboundRelationship"
  | Path _ -> "Path"
  | Point _ -> "Point"
  | Date _ -> "Date"
  | Time _ -> "Time"
  | DateTime _ -> "DateTime"
  | Duration _ -> "Duration"
  | Vector _ -> "Vector"
  | Uuid _ -> "Uuid"
  | Unsupported unsupported -> "Unsupported(" ^ unsupported.name ^ ")"
  | Broken _ -> "Broken"

let broken_error (broken : Values.broken) = Errors.Decode_error ("broken value: " ^ broken.error)
let succeed value = { run = (fun _ -> Ok value); aliases = [] }
let fail message = { run = (fun _ -> Error (Errors.Decode_error message)); aliases = [] }

let union left right =
  let rec add acc = function
    | [] -> List.rev acc
    | name :: rest -> if List.mem name acc then add acc rest else add (name :: acc) rest
  in
  add (List.rev left) right

let map f decoder = { run = (fun env -> Result.map f (decoder.run env)); aliases = decoder.aliases }

let both left right =
  {
    run =
      (fun env ->
        let* left_value = left.run env in
        let* right_value = right.run env in
        Ok (left_value, right_value));
    aliases = union left.aliases right.aliases;
  }

let ( let+ ) decoder f = map f decoder
let ( and+ ) = both

let raw =
  {
    run =
      (function
      | Value value -> Ok value
      | Row _ -> Error (Errors.Decode_error "expected a value, got a row"));
    aliases = [];
  }

let expect name project =
  {
    run =
      (function
      | Value (Values.Broken broken) -> Error (broken_error broken)
      | Value value -> (
          match project value with
          | Some value -> Ok value
          | None ->
              Error
                (Errors.Decode_error (Printf.sprintf "expected %s, got %s" name (type_name value))))
      | Row _ ->
          Error
            (Errors.Decode_error
               (Printf.sprintf "expected %s, got a row; use [field] to read a column" name)));
    aliases = [];
  }

let string = expect "String" (function Values.String value -> Some value | _ -> None)
let bool = expect "Bool" (function Values.Bool value -> Some value | _ -> None)
let int64 = expect "Int" (function Values.Int value -> Some value | _ -> None)
let float = expect "Float" (function Values.Float value -> Some value | _ -> None)
let bytes = expect "Bytes" (function Values.Bytes value -> Some value | _ -> None)
let uuid = expect "Uuid" (function Values.Uuid value -> Some value | _ -> None)

let int =
  {
    run =
      (function
      | Value (Values.Broken broken) -> Error (broken_error broken)
      | Value (Values.Int value) ->
          let minimum = Int64.of_int min_int and maximum = Int64.of_int max_int in
          if Int64.compare value minimum >= 0 && Int64.compare value maximum <= 0 then
            Ok (Int64.to_int value)
          else
            Error
              (Errors.Decode_error
                 (Printf.sprintf "expected int, got Int %Ld outside the OCaml int range" value))
      | Value value ->
          Error (Errors.Decode_error (Printf.sprintf "expected Int, got %s" (type_name value)))
      | Row _ -> Error (Errors.Decode_error "expected Int, got a row"));
    aliases = [];
  }

let date = expect "Date" (function Values.Date value -> Some value | _ -> None)
let time = expect "Time" (function Values.Time value -> Some value | _ -> None)
let datetime = expect "DateTime" (function Values.DateTime value -> Some value | _ -> None)
let duration = expect "Duration" (function Values.Duration value -> Some value | _ -> None)
let point = expect "Point" (function Values.Point value -> Some value | _ -> None)
let vector = expect "Vector" (function Values.Vector value -> Some value | _ -> None)
let node = expect "Node" (function Values.Node value -> Some value | _ -> None)

let relationship =
  expect "Relationship" (function Values.Relationship value -> Some value | _ -> None)

let unbound_relationship =
  expect "UnboundRelationship" (function
    | Values.Unbound_relationship value -> Some value
    | _ -> None)

let path = expect "Path" (function Values.Path value -> Some value | _ -> None)

let option decoder =
  {
    run =
      (function
      | Value Values.Null -> Ok None
      | Value (Values.Broken broken) -> Error (broken_error broken)
      | env -> Result.map (fun value -> Some value) (decoder.run env));
    aliases = [];
  }

let list decoder =
  {
    run =
      (function
      | Value (Values.List values) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | value :: rest ->
                let* decoded = decoder.run (Value value) in
                collect (decoded :: acc) rest
          in
          collect [] values
      | Value (Values.Broken broken) -> Error (broken_error broken)
      | Value value ->
          Error (Errors.Decode_error (Printf.sprintf "expected List, got %s" (type_name value)))
      | Row _ -> Error (Errors.Decode_error "expected List, got a row"));
    aliases = [];
  }

let array decoder = map Array.of_list (list decoder)

let lookup key env =
  match env with
  | Row fields -> Ok fields
  | Value (Values.Broken broken) -> Error (broken_error broken)
  | Value value -> (
      match value with
      | Values.Map entries -> Ok entries
      | Values.Node node -> Ok node.properties
      | Values.Relationship relationship -> Ok relationship.properties
      | Values.Unbound_relationship relationship -> Ok relationship.properties
      | _ ->
          Error
            (Errors.Decode_error
               (Printf.sprintf
                  "cannot read field %S from %s; expected a row, Map, Node or Relationship" key
                  (type_name value))))

let available fields =
  match List.map fst fields with [] -> "none" | names -> String.concat ", " names

let missing_field key fields =
  Errors.Decode_error
    (Printf.sprintf "missing field %S; available fields: %s" key (available fields))

let prefix_field key = function
  | Ok value -> Ok value
  | Error (Errors.Decode_error message) ->
      Error (Errors.Decode_error (Printf.sprintf "field %S: %s" key message))
  | Error error -> Error error

let field key decoder =
  {
    run =
      (fun env ->
        let* fields = lookup key env in
        match List.assoc_opt key fields with
        | None -> Error (missing_field key fields)
        | Some value -> prefix_field key (decoder.run (Value value)));
    aliases = [ key ];
  }

let field_opt key decoder =
  {
    run =
      (fun env ->
        let* fields = lookup key env in
        match List.assoc_opt key fields with
        | None | Some Values.Null -> Ok None
        | Some value ->
            prefix_field key (Result.map (fun value -> Some value) (decoder.run (Value value))));
    aliases = [];
  }

let field_or key ~default decoder =
  {
    run =
      (fun env ->
        let* fields = lookup key env in
        match List.assoc_opt key fields with
        | None | Some Values.Null -> Ok default
        | Some value -> prefix_field key (decoder.run (Value value)));
    aliases = [];
  }
