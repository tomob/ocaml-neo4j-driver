(* Hydration — conversion between the transport-level PackStream values and
   the rich Neo4j values (see values.ml and temporal.ml).

   Modelled on the Neo4j Python driver's _codec/hydration:

   - The structure tags are interpreted per Bolt protocol version ([V1] for
     Bolt 3/4, [V2] for Bolt 5, [V3] for Bolt 6): the DateTime tags differ
     ([F]/[f] vs [I]/[i]) and [V] (Vector) / [?] (UnsupportedType) only exist
     in Bolt 6.
   - Graph entities are deduplicated by [element_id] within one hydration
     scope (per query): a node first seen as a relationship endpoint is later
     enriched with its labels and properties. For Bolt 3/4 the integer id is
     used as the [element_id] fallback.
   - Undecodable structures become a [Broken] value which propagates through
     lists and maps.

   One [t] holds the per-query graph state; create one per result. *)

open Neodriver_packstream

type version = V1 | V2 | V3

type t = {
  version : version;
  mutable nodes : (string * Values.node) list;
  mutable relationships : (string * Values.relationship) list;
}

let create version = { version; nodes = []; relationships = [] }
let version t = t.version
let nodes t = List.rev_map snd t.nodes
let relationships t = List.rev_map snd t.relationships

(* --- field accessors --- *)

let str = function Packstream.String s -> Some s | _ -> None
let int_ = function Packstream.Int n -> Some (Int64.to_int n) | _ -> None
let int64_ = function Packstream.Int n -> Some n | _ -> None

let float_ = function
  | Packstream.Float f -> Some f
  | Packstream.Int n -> Some (Int64.to_float n)
  | _ -> None

let bytes_ = function Packstream.Bytes b -> Some b | _ -> None
let list_ = function Packstream.List l -> Some l | _ -> None
let map_ = function Packstream.Map m -> Some m | _ -> None

let id_or_element_id = function
  | Packstream.String s -> Some (s, None)
  | Packstream.Int n -> Some (Int64.to_string n, Some (Int64.to_int n))
  | _ -> None

(* --- scalar structure hydrators (no graph state, non-recursive) --- *)

let hydrate_point fields =
  match fields with
  | [ srid; x; y ] -> (
      match (int_ srid, float_ x, float_ y) with
      | Some srid, Some x, Some y ->
          Some
            (Values.Point { Values.srid; Values.x; Values.y; Values.z = None })
      | _ -> None)
  | [ srid; x; y; z ] -> (
      match (int_ srid, float_ x, float_ y, float_ z) with
      | Some srid, Some x, Some y, Some z ->
          Some
            (Values.Point { Values.srid; Values.x; Values.y; Values.z = Some z })
      | _ -> None)
  | _ -> None

let hydrate_date fields =
  match fields with
  | [ days ] -> (
      match int_ days with
      | Some days -> Some (Values.Date (Temporal.Date.of_days days))
      | None -> None)
  | _ -> None

let hydrate_time fields =
  match fields with
  | [ nanoseconds; tz ] -> (
      match (int64_ nanoseconds, int_ tz) with
      | Some ns, Some tz ->
          Some (Values.Time (Temporal.Time.of_ticks ~tz_offset_seconds:tz ns))
      | _ -> None)
  | [ nanoseconds ] -> (
      match int64_ nanoseconds with
      | Some ns -> Some (Values.Time (Temporal.Time.of_ticks ns))
      | None -> None)
  | _ -> None

let hydrate_datetime_offset fields =
  match fields with
  | [ seconds; nanoseconds; tz ] -> (
      match (int64_ seconds, int_ nanoseconds, int_ tz) with
      | Some sec, Some ns, Some off ->
          Some
            (Values.DateTime
               (Temporal.DateTime.of_epoch_seconds ~tz:(Offset off) sec ns))
      | _ -> None)
  | _ -> None

let hydrate_datetime_zone fields =
  match fields with
  | [ seconds; nanoseconds; name ] -> (
      match (int64_ seconds, int_ nanoseconds, str name) with
      | Some sec, Some ns, Some name ->
          Some
            (Values.DateTime
               (Temporal.DateTime.of_epoch_seconds ~tz:(Zone_name name) sec ns))
      | _ -> None)
  | _ -> None

let hydrate_local_datetime fields =
  match fields with
  | [ seconds; nanoseconds ] -> (
      match (int64_ seconds, int_ nanoseconds) with
      | Some sec, Some ns ->
          Some (Values.DateTime (Temporal.DateTime.of_epoch_seconds sec ns))
      | _ -> None)
  | _ -> None

let hydrate_duration fields =
  match fields with
  | [ months; days; seconds; nanoseconds ] -> (
      match (int_ months, int_ days, int64_ seconds, int_ nanoseconds) with
      | Some months, Some days, Some seconds, Some nanoseconds ->
          Some
            (Values.Duration
               (Temporal.Duration.of_fields ~months ~days ~seconds ~nanoseconds))
      | _ -> None)
  | _ -> None

let vector_dtype_of_marker = function
  | 0xC8 -> Some Values.I8
  | 0xC9 -> Some Values.I16
  | 0xCA -> Some Values.I32
  | 0xCB -> Some Values.I64
  | 0xC6 -> Some Values.F32
  | 0xC1 -> Some Values.F64
  | _ -> None

let vector_dtype_marker = function
  | Values.I8 -> 0xC8
  | Values.I16 -> 0xC9
  | Values.I32 -> 0xCA
  | Values.I64 -> 0xCB
  | Values.F32 -> 0xC6
  | Values.F64 -> 0xC1

let hydrate_vector fields =
  match fields with
  | [ dtype; data ] -> (
      match (int_ dtype, bytes_ data) with
      | Some dtype, Some data -> (
          match vector_dtype_of_marker dtype with
          | Some dtype -> Some (Values.Vector { Values.dtype; Values.data })
          | None -> None)
      | _ -> None)
  | _ -> None

let hydrate_unsupported fields =
  match fields with
  | [ name; min_major; min_minor; extra ] -> (
      match (str name, int_ min_major, int_ min_minor) with
      | Some name, Some major, Some minor ->
          let message =
            match extra with
            | Packstream.Map entries -> (
                match List.assoc_opt "message" entries with
                | Some (Packstream.String m) -> Some m
                | _ -> None)
            | _ -> None
          in
          Some
            (Values.Unsupported
               {
                 Values.name;
                 Values.minimum_protocol_version = (major, minor);
                 Values.message;
               })
      | _ -> None)
  | _ -> None

(* --- graph hydrators (mutually recursive with [hydrate]) --- *)

let rec hydrate t value =
  match value with
  | Packstream.Null -> Values.Null
  | Packstream.Bool b -> Values.Bool b
  | Packstream.Int n -> Values.Int n
  | Packstream.Float f -> Values.Float f
  | Packstream.String s -> Values.String s
  | Packstream.Bytes b -> Values.Bytes b
  | Packstream.List items ->
      let items = List.map (hydrate t) items in
      if List.exists (function Values.Broken _ -> true | _ -> false) items
      then Values.Broken { Values.error = "broken list"; Values.raw = value }
      else Values.List items
  | Packstream.Map entries ->
      let entries = List.map (fun (k, v) -> (k, hydrate t v)) entries in
      if
        List.exists
          (fun (_, v) -> match v with Values.Broken _ -> true | _ -> false)
          entries
      then Values.Broken { Values.error = "broken map"; Values.raw = value }
      else Values.Map entries
  | Packstream.Structure (tag, fields) -> (
      let wrap opt =
        match opt with
        | Some v -> v
        | None ->
            Values.Broken
              {
                Values.error =
                  Printf.sprintf "Failed to hydrate structure tag 0x%02X" tag;
                Values.raw = value;
              }
      in
      match tag with
      | 0x4E ->
          wrap (Option.map (fun n -> Values.Node n) (hydrate_node t fields))
      | 0x52 ->
          wrap
            (Option.map
               (fun r -> Values.Relationship r)
               (hydrate_relationship t fields))
      | 0x72 ->
          wrap
            (Option.map
               (fun r -> Values.Unbound_relationship r)
               (hydrate_unbound_relationship t fields))
      | 0x50 ->
          wrap (Option.map (fun p -> Values.Path p) (hydrate_path t fields))
      | 0x58 | 0x59 -> wrap (hydrate_point fields)
      | 0x44 -> wrap (hydrate_date fields)
      | 0x54 | 0x74 -> wrap (hydrate_time fields)
      | 0x46 when t.version = V1 -> wrap (hydrate_datetime_offset fields)
      | 0x66 when t.version = V1 -> wrap (hydrate_datetime_zone fields)
      | 0x49 when t.version <> V1 -> wrap (hydrate_datetime_offset fields)
      | 0x69 when t.version <> V1 -> wrap (hydrate_datetime_zone fields)
      | 0x46 | 0x66 | 0x49 | 0x69 ->
          (* F/f (v1) or I/i (v2/v3) used with the wrong protocol version. *)
          wrap None
      | 0x64 -> wrap (hydrate_local_datetime fields)
      | 0x45 -> wrap (hydrate_duration fields)
      | (0x56 | 0x3F) when t.version = V3 ->
          if tag = 0x56 then wrap (hydrate_vector fields)
          else wrap (hydrate_unsupported fields)
      | 0x56 | 0x3F -> wrap None
      | _ ->
          Values.Broken
            {
              Values.error =
                Printf.sprintf "Unknown PackStream structure tag 0x%02X" tag;
              Values.raw = value;
            })

and hydrate_node t fields =
  match fields with
  | [ id_or_eid; labels; props ] -> (
      match
        ( id_or_element_id id_or_eid,
          hydrate_labels labels,
          hydrate_props t props )
      with
      | Some (element_id, legacy_id), Some labels, Some properties ->
          let node =
            match List.assoc_opt element_id t.nodes with
            | Some existing ->
                {
                  existing with
                  labels = merge_labels existing.labels labels;
                  properties = merge_props existing.properties properties;
                }
            | None -> { element_id; legacy_id; labels; properties }
          in
          t.nodes <- (element_id, node) :: List.remove_assoc element_id t.nodes;
          Some node
      | _ -> None)
  | _ -> None

and get_or_create_node t element_id legacy_id =
  match List.assoc_opt element_id t.nodes with
  | Some node -> node
  | None ->
      let node =
        {
          Values.element_id;
          Values.legacy_id;
          Values.labels = [];
          Values.properties = [];
        }
      in
      t.nodes <- (element_id, node) :: t.nodes;
      node

and hydrate_relationship t fields =
  match fields with
  | [ id_or_eid; start_id; end_id; type_; props ] -> (
      match
        ( id_or_element_id id_or_eid,
          id_or_element_id start_id,
          id_or_element_id end_id,
          str type_,
          hydrate_props t props )
      with
      | ( Some (element_id, legacy_id),
          Some (start_eid, start_legacy),
          Some (end_eid, end_legacy),
          Some rel_type,
          Some properties ) ->
          ignore (get_or_create_node t start_eid start_legacy);
          ignore (get_or_create_node t end_eid end_legacy);
          let rel =
            {
              Values.element_id;
              Values.legacy_id;
              Values.rel_type;
              Values.start = start_eid;
              Values.end_ = end_eid;
              Values.properties;
            }
          in
          let rel =
            match List.assoc_opt element_id t.relationships with
            | Some existing -> existing
            | None ->
                t.relationships <- (element_id, rel) :: t.relationships;
                rel
          in
          Some rel
      | _ -> None)
  | _ -> None

and hydrate_unbound_relationship t fields =
  match fields with
  | [ id_or_eid; type_; props ] -> (
      match (id_or_element_id id_or_eid, str type_, hydrate_props t props) with
      | Some (element_id, legacy_id), Some rel_type, Some properties ->
          Some
            {
              Values.element_id;
              Values.legacy_id;
              Values.rel_type;
              Values.properties;
            }
      | _ -> None)
  | _ -> None

and hydrate_node_list t nodes =
  match list_ nodes with
  | None -> None
  | Some ls ->
      let rec go acc = function
        | [] -> Some (List.rev acc)
        | Packstream.Structure (0x4E, fields) :: rest -> (
            match hydrate_node t fields with
            | Some n -> go (n :: acc) rest
            | None -> None)
        | _ -> None
      in
      go [] ls

and hydrate_unbound_list t rels =
  match list_ rels with
  | None -> None
  | Some ls ->
      let rec go acc = function
        | [] -> Some (List.rev acc)
        | Packstream.Structure (0x72, fields) :: rest -> (
            match hydrate_unbound_relationship t fields with
            | Some r -> go (r :: acc) rest
            | None -> None)
        | _ -> None
      in
      go [] ls

and int_list = function
  | Packstream.List items ->
      let rec go acc = function
        | [] -> Some (List.rev acc)
        | Packstream.Int n :: rest -> go (Int64.to_int n :: acc) rest
        | _ -> None
      in
      go [] items
  | _ -> None

and hydrate_path t fields =
  match fields with
  | [ nodes; rels; sequence ] -> (
      match
        ( hydrate_node_list t nodes,
          hydrate_unbound_list t rels,
          int_list sequence )
      with
      | Some node_list, Some rel_list, Some seq ->
          if List.length node_list < 1 || List.length seq mod 2 <> 0 then None
          else
            let rec go (last : Values.node) (ordered_nodes : Values.node list)
                (bound_rels : Values.relationship list) = function
              | [] ->
                  Some
                    {
                      Values.nodes = List.rev ordered_nodes;
                      relationships = List.rev bound_rels;
                    }
              | rel_idx :: node_idx :: rest -> (
                  match
                    ( List.nth_opt node_list node_idx,
                      List.nth_opt rel_list (abs rel_idx - 1) )
                  with
                  | Some next_node, Some unbound when rel_idx <> 0 ->
                      let start_eid, end_eid =
                        if rel_idx > 0 then
                          (last.element_id, next_node.element_id)
                        else (next_node.element_id, last.element_id)
                      in
                      let bound =
                        {
                          Values.element_id = unbound.element_id;
                          Values.legacy_id = unbound.legacy_id;
                          Values.rel_type = unbound.rel_type;
                          Values.start = start_eid;
                          Values.end_ = end_eid;
                          Values.properties = unbound.properties;
                        }
                      in
                      go next_node
                        (next_node :: ordered_nodes)
                        (bound :: bound_rels) rest
                  | _ -> None)
              | _ -> None
            in
            let first = List.hd node_list in
            go first [ first ] [] seq
      | _ -> None)
  | _ -> None

and hydrate_labels labels =
  match list_ labels with
  | None -> None
  | Some ls ->
      let rec go acc = function
        | [] -> Some (List.rev acc)
        | Packstream.String l :: rest -> go (l :: acc) rest
        | _ -> None
      in
      go [] ls

and hydrate_props t props =
  match map_ props with
  | None -> None
  | Some entries ->
      let rec go acc = function
        | [] -> Some (List.rev acc)
        | (k, v) :: rest -> (
            match hydrate t v with
            | Values.Broken _ -> None
            | hv -> go ((k, hv) :: acc) rest)
      in
      go [] entries

and merge_labels a b =
  List.fold_left (fun acc l -> if List.mem l acc then acc else l :: acc) a b
  |> List.rev

and merge_props a b =
  List.fold_left (fun acc (k, v) -> (k, v) :: List.remove_assoc k acc) a b

(* --- dehydration --- *)

let rec dehydrate t value =
  match value with
  | Values.Null -> Packstream.Null
  | Values.Bool b -> Packstream.Bool b
  | Values.Int n -> Packstream.Int n
  | Values.Float f -> Packstream.Float f
  | Values.String s -> Packstream.String s
  | Values.Bytes b -> Packstream.Bytes b
  | Values.List items -> Packstream.List (List.map (dehydrate t) items)
  | Values.Map entries ->
      Packstream.Map (List.map (fun (k, v) -> (k, dehydrate t v)) entries)
  | Values.Node n ->
      let id_field =
        match (n.legacy_id, t.version) with
        | Some id, V1 -> Packstream.Int (Int64.of_int id)
        | _ -> Packstream.String n.element_id
      in
      Packstream.Structure
        ( 0x4E,
          [
            id_field;
            Packstream.List (List.map (fun l -> Packstream.String l) n.labels);
            dehydrate_props t n.properties;
          ] )
  | Values.Relationship r ->
      let id_field =
        match (r.legacy_id, t.version) with
        | Some id, V1 -> Packstream.Int (Int64.of_int id)
        | _ -> Packstream.String r.element_id
      in
      Packstream.Structure
        ( 0x52,
          [
            id_field;
            Packstream.String r.start;
            Packstream.String r.end_;
            Packstream.String r.rel_type;
            dehydrate_props t r.properties;
          ] )
  | Values.Unbound_relationship r ->
      let id_field =
        match (r.legacy_id, t.version) with
        | Some id, V1 -> Packstream.Int (Int64.of_int id)
        | _ -> Packstream.String r.element_id
      in
      Packstream.Structure
        ( 0x72,
          [
            id_field;
            Packstream.String r.rel_type;
            dehydrate_props t r.properties;
          ] )
  | Values.Path p ->
      let nodes = List.map (fun n -> dehydrate t (Values.Node n)) p.nodes in
      let rels =
        List.map
          (fun (r : Values.relationship) ->
            dehydrate t
              (Values.Unbound_relationship
                 {
                   Values.element_id = r.element_id;
                   Values.legacy_id = r.legacy_id;
                   Values.rel_type = r.rel_type;
                   Values.properties = r.properties;
                 }))
          p.relationships
      in
      let sequence =
        List.concat
          (List.mapi
             (fun i _ ->
               [
                 Packstream.Int (Int64.of_int (i + 1));
                 Packstream.Int (Int64.of_int (i + 1));
               ])
             p.relationships)
      in
      Packstream.Structure
        ( 0x50,
          [
            Packstream.List nodes;
            Packstream.List rels;
            Packstream.List sequence;
          ] )
  | Values.Point pt -> (
      match pt.z with
      | None ->
          Packstream.Structure
            ( 0x58,
              [
                Packstream.Int (Int64.of_int pt.srid);
                Packstream.Float pt.x;
                Packstream.Float pt.y;
              ] )
      | Some z ->
          Packstream.Structure
            ( 0x59,
              [
                Packstream.Int (Int64.of_int pt.srid);
                Packstream.Float pt.x;
                Packstream.Float pt.y;
                Packstream.Float z;
              ] ))
  | Values.Date d ->
      Packstream.Structure
        (0x44, [ Packstream.Int (Int64.of_int (Temporal.Date.to_days d)) ])
  | Values.Time tm -> (
      let ns = Temporal.Time.to_ticks tm in
      match Temporal.Time.tz_offset_seconds tm with
      | None -> Packstream.Structure (0x74, [ Packstream.Int ns ])
      | Some off ->
          Packstream.Structure
            (0x54, [ Packstream.Int ns; Packstream.Int (Int64.of_int off) ]))
  | Values.DateTime dt -> (
      let seconds, nanoseconds = Temporal.DateTime.to_epoch_seconds dt in
      match Temporal.DateTime.tz dt with
      | None ->
          Packstream.Structure
            ( 0x64,
              [
                Packstream.Int seconds;
                Packstream.Int (Int64.of_int nanoseconds);
              ] )
      | Some (Offset offset) ->
          let tag = if t.version = V1 then 0x46 else 0x49 in
          Packstream.Structure
            ( tag,
              [
                Packstream.Int seconds;
                Packstream.Int (Int64.of_int nanoseconds);
                Packstream.Int (Int64.of_int offset);
              ] )
      | Some (Zone_name name) ->
          let tag = if t.version = V1 then 0x66 else 0x69 in
          Packstream.Structure
            ( tag,
              [
                Packstream.Int seconds;
                Packstream.Int (Int64.of_int nanoseconds);
                Packstream.String name;
              ] ))
  | Values.Duration d ->
      let months, days, seconds, nanoseconds = Temporal.Duration.to_fields d in
      Packstream.Structure
        ( 0x45,
          [
            Packstream.Int (Int64.of_int months);
            Packstream.Int (Int64.of_int days);
            Packstream.Int seconds;
            Packstream.Int (Int64.of_int nanoseconds);
          ] )
  | Values.Vector v ->
      Packstream.Structure
        ( 0x56,
          [
            Packstream.Int (Int64.of_int (vector_dtype_marker v.dtype));
            Packstream.Bytes v.data;
          ] )
  | Values.Unsupported u ->
      let major, minor = u.minimum_protocol_version in
      let extra =
        match u.message with
        | Some m -> [ ("message", Packstream.String m) ]
        | None -> []
      in
      Packstream.Structure
        ( 0x3F,
          [
            Packstream.String u.name;
            Packstream.Int (Int64.of_int major);
            Packstream.Int (Int64.of_int minor);
            Packstream.Map extra;
          ] )
  | Values.Broken _ -> invalid_arg "Cannot dehydrate a Broken value"

and dehydrate_props t properties =
  Packstream.Map (List.map (fun (k, v) -> (k, dehydrate t v)) properties)
