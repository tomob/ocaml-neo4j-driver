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

let ( let* ) o f = match o with Some v -> f v | None -> None

type version = V1 | V2 | V3

type t = {
  version : version;
  minor : int;
  mutable nodes : (string * Values.node) list;
  mutable relationships : (string * Values.relationship) list;
}

let create ?(minor = 0) version = { version; minor; nodes = []; relationships = [] }
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
let is_broken = function Values.Broken _ -> true | _ -> false

(* The identity (element_id, legacy_id) of a graph entity from its single id
   field: a String is the element_id (Bolt 5.0+), an Int is the legacy id (used
   as the element_id fallback for Bolt 3/4). *)
let identity = function
  | Packstream.String s -> Some (s, None)
  | Packstream.Int n -> Some (Int64.to_string n, Some (Int64.to_int n))
  | _ -> None

(* Identity for the Bolt 5.1+/6 formats, where the legacy id and the element_id
   are separate fields: [?element_id] is the trailing String and [id_field] the
   leading legacy id. *)
let identity_of ?element_id id_field =
  match (element_id, id_field) with
  | Some (Packstream.String eid), Packstream.Int id -> Some (eid, Some (Int64.to_int id))
  | _ -> identity id_field

(* --- scalar structure hydrators (no graph state, non-recursive) --- *)

let hydrate_point fields =
  match fields with
  | [ srid; x; y ] -> (
      match (int_ srid, float_ x, float_ y) with
      | Some srid, Some x, Some y ->
          Some (Values.Point { Values.srid; Values.x; Values.y; Values.z = None })
      | _ -> None)
  | [ srid; x; y; z ] -> (
      match (int_ srid, float_ x, float_ y, float_ z) with
      | Some srid, Some x, Some y, Some z ->
          Some (Values.Point { Values.srid; Values.x; Values.y; Values.z = Some z })
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
      | Some ns, Some tz -> Some (Values.Time (Temporal.Time.of_ticks ~tz_offset_seconds:tz ns))
      | _ -> None)
  | [ nanoseconds ] -> (
      match int64_ nanoseconds with
      | Some ns -> Some (Values.Time (Temporal.Time.of_ticks ns))
      | None -> None)
  | _ -> None

(* Wall-clock seconds (the V1 encoding of a DateTime) for a UTC [epoch] and
   an [offset] in seconds. *)
let wall_to_epoch_seconds version sec offset =
  if version = V1 then Int64.sub sec (Int64.of_int offset) else sec

let hydrate_datetime_offset t fields =
  match fields with
  | [ seconds; nanoseconds; tz ] -> (
      match (int64_ seconds, int_ nanoseconds, int_ tz) with
      | Some sec, Some ns, Some off ->
          Some
            (Values.DateTime
               (Temporal.DateTime.of_epoch_seconds ~tz:(Offset off)
                  (wall_to_epoch_seconds t.version sec off)
                  ns))
      | _ -> None)
  | _ -> None

let hydrate_datetime_zone t fields =
  match fields with
  | [ seconds; nanoseconds; name ] -> (
      match (int64_ seconds, int_ nanoseconds, str name) with
      | Some sec, Some ns, Some name ->
          (* An unknown named zone is a value the driver cannot represent: it
             must be surfaced as an error (with the zone in the message), not
             silently fallen back to a UTC/LMT guess. *)
          if Temporal.DateTime.is_known_zone name then
            let zone = Temporal.Zone_name name in
            let epoch =
              match Temporal.DateTime.offset_seconds_at_wall ~tz:zone sec with
              | Some off -> wall_to_epoch_seconds t.version sec off
              | None -> sec
            in
            Some (Values.DateTime (Temporal.DateTime.of_epoch_seconds ~tz:zone epoch ns))
          else
            (* The raw value carries the actual wire tag: [f] (0x66) on Bolt 3/4,
               [i] (0x69) on Bolt 5/6. *)
            let tag = if t.version = V1 then 0x66 else 0x69 in
            Some
              (Values.Broken
                 {
                   Values.error = Printf.sprintf "unknown timezone %S" name;
                   Values.raw = Packstream.Structure (tag, fields);
                 })
      | _ -> None)
  | _ -> None

let hydrate_local_datetime fields =
  match fields with
  | [ seconds; nanoseconds ] -> (
      match (int64_ seconds, int_ nanoseconds) with
      | Some sec, Some ns -> Some (Values.DateTime (Temporal.DateTime.of_epoch_seconds sec ns))
      | _ -> None)
  | _ -> None

let hydrate_duration fields =
  match fields with
  | [ months; days; seconds; nanoseconds ] -> (
      match (int_ months, int_ days, int64_ seconds, int_ nanoseconds) with
      | Some months, Some days, Some seconds, Some nanoseconds ->
          Some (Values.Duration (Temporal.Duration.of_fields ~months ~days ~seconds ~nanoseconds))
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

(* The vector dtype field is a single marker byte (BYTES on the wire, not an
   integer). *)
let vector_dtype_of_bytes = function
  | Packstream.Bytes b when Bytes.length b = 1 -> vector_dtype_of_marker (Bytes.get_uint8 b 0)
  | _ -> None

let hydrate_vector fields =
  match fields with
  | [ dtype; data ] -> (
      match (vector_dtype_of_bytes dtype, bytes_ data) with
      | Some dtype, Some data -> Some (Values.Vector { Values.dtype; Values.data })
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
               { Values.name; Values.minimum_protocol_version = (major, minor); Values.message })
      | _ -> None)
  | _ -> None

(* --- graph hydrators (mutually recursive with [hydrate]) --- *)

(* Map a list with a partial function, short-circuiting on the first [None]. *)
let list_map_some f items =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | x :: rest -> ( match f x with Some y -> go (y :: acc) rest | None -> None)
  in
  go [] items

let rec hydrate t value =
  match value with
  | Packstream.Null -> Values.Null
  | Packstream.Bool b -> Values.Bool b
  | Packstream.Int n -> Values.Int n
  | Packstream.Float f -> Values.Float f
  | Packstream.String s -> Values.String s
  | Packstream.Bytes b -> Values.Bytes b
  | Packstream.Uuid u -> (
      (* UUID (marker 0xE0) is a Bolt 6.1 type: an earlier protocol version
          rejecting it keeps the driver honest about its negotiated
          capabilities. *)
      match (t.version, t.minor) with
      | V3, minor when minor >= 1 -> Values.Uuid u
      | _ ->
          Values.Broken
            { Values.error = "UUID is not supported before Bolt 6.1"; Values.raw = value })
  | Packstream.List items ->
      let items = List.map (hydrate t) items in
      if List.exists is_broken items then
        Values.Broken { Values.error = "broken list"; Values.raw = value }
      else Values.List items
  | Packstream.Map entries ->
      let entries = List.map (fun (k, v) -> (k, hydrate t v)) entries in
      if List.exists (fun (_, v) -> is_broken v) entries then
        Values.Broken { Values.error = "broken map"; Values.raw = value }
      else Values.Map entries
  | Packstream.Structure (tag, fields) -> (
      let wrap opt =
        match opt with
        | Some v -> v
        | None ->
            Values.Broken
              {
                Values.error = Printf.sprintf "Failed to hydrate structure tag 0x%02X" tag;
                Values.raw = value;
              }
      in
      match tag with
      | 0x4E -> wrap (Option.map (fun n -> Values.Node n) (hydrate_node t fields))
      | 0x52 -> wrap (Option.map (fun r -> Values.Relationship r) (hydrate_relationship t fields))
      | 0x72 ->
          wrap
            (Option.map
               (fun r -> Values.Unbound_relationship r)
               (hydrate_unbound_relationship t fields))
      | 0x50 -> wrap (Option.map (fun p -> Values.Path p) (hydrate_path t fields))
      | 0x58 | 0x59 -> wrap (hydrate_point fields)
      | 0x44 -> wrap (hydrate_date fields)
      | 0x54 | 0x74 -> wrap (hydrate_time fields)
      | 0x46 when t.version = V1 -> wrap (hydrate_datetime_offset t fields)
      | 0x66 when t.version = V1 -> wrap (hydrate_datetime_zone t fields)
      | 0x49 when t.version <> V1 -> wrap (hydrate_datetime_offset t fields)
      | 0x69 when t.version <> V1 -> wrap (hydrate_datetime_zone t fields)
      | 0x46 | 0x66 | 0x49 | 0x69 ->
          (* F/f (v1) or I/i (v2/v3) used with the wrong protocol version. *)
          wrap None
      | 0x64 -> wrap (hydrate_local_datetime fields)
      | 0x45 -> wrap (hydrate_duration fields)
      | 0x56 when t.version = V3 -> wrap (hydrate_vector fields)
      | 0x3F when t.version = V3 -> wrap (hydrate_unsupported fields)
      | 0x56 | 0x3F -> wrap None
      | _ ->
          Values.Broken
            {
              Values.error = Printf.sprintf "Unknown PackStream structure tag 0x%02X" tag;
              Values.raw = value;
            })

(* Add a node to the graph, deduplicated by [element_id] (labels/properties are
   merged when the node was first seen as a relationship endpoint). *)
and upsert_node t ~element_id ~legacy_id ~labels ~properties =
  let node =
    match List.assoc_opt element_id t.nodes with
    | Some existing ->
        {
          existing with
          labels = merge_labels existing.labels labels;
          properties = merge_props existing.properties properties;
        }
    | None -> { Values.element_id; Values.legacy_id; Values.labels; Values.properties }
  in
  t.nodes <- (element_id, node) :: List.remove_assoc element_id t.nodes;
  node

and hydrate_node t fields =
  match fields with
  (* Bolt <= 5.0: [id; labels; properties] with a legacy int or an element_id string. *)
  | [ id_field; labels; props ] ->
      let* element_id, legacy_id = identity id_field in
      hydrate_node_body t ~element_id ~legacy_id ~labels ~props
  (* Bolt 5.1+/6: [id; labels; properties; element_id]. *)
  | [ id_field; labels; props; element_id ] ->
      let* element_id, legacy_id = identity_of ~element_id id_field in
      hydrate_node_body t ~element_id ~legacy_id ~labels ~props
  | _ -> None

and hydrate_node_body t ~element_id ~legacy_id ~labels ~props =
  let* labels = hydrate_labels labels in
  let* properties = hydrate_props t props in
  Some (upsert_node t ~element_id ~legacy_id ~labels ~properties)

and get_or_create_node t element_id legacy_id =
  match List.assoc_opt element_id t.nodes with
  | Some node -> node
  | None ->
      let node =
        { Values.element_id; Values.legacy_id; Values.labels = []; Values.properties = [] }
      in
      t.nodes <- (element_id, node) :: t.nodes;
      node

(* Add a relationship to the graph, deduplicated by [element_id]. *)
and upsert_relationship t (rel : Values.relationship) =
  match List.assoc_opt rel.Values.element_id t.relationships with
  | Some existing -> existing
  | None ->
      t.relationships <- (rel.Values.element_id, rel) :: t.relationships;
      rel

(* Add a relationship to the graph, deduplicated by [element_id]. The endpoint
   nodes are created first so the relationship references them. *)
and build_relationship t ~element_id ~legacy_id ~start ~end_ ~start_legacy ~end_legacy ~type_ ~props
    =
  match (str type_, hydrate_props t props) with
  | Some rel_type, Some properties ->
      ignore (get_or_create_node t start start_legacy);
      ignore (get_or_create_node t end_ end_legacy);
      let rel =
        {
          Values.element_id;
          Values.legacy_id;
          Values.rel_type;
          Values.start;
          Values.end_;
          Values.start_legacy_id = start_legacy;
          Values.end_legacy_id = end_legacy;
          Values.properties;
        }
      in
      Some (upsert_relationship t rel)
  | _ -> None

and hydrate_relationship t fields =
  match fields with
  (* Bolt <= 5.0: [id; start; end; type; properties]. *)
  | [ id_field; start_id; end_id; type_; props ] ->
      let* element_id, legacy_id = identity id_field in
      let* start_eid, start_legacy = identity start_id in
      let* end_eid, end_legacy = identity end_id in
      build_relationship t ~element_id ~legacy_id ~start:start_eid ~end_:end_eid ~start_legacy
        ~end_legacy ~type_ ~props
  (* Bolt 5.1+/6: [id; start; end; type; properties; element_id; start_element_id; end_element_id]. *)
  | [
   Packstream.Int id;
   Packstream.Int start_id;
   Packstream.Int end_id;
   type_;
   props;
   Packstream.String element_id;
   Packstream.String start_eid;
   Packstream.String end_eid;
  ] ->
      build_relationship t ~element_id
        ~legacy_id:(Some (Int64.to_int id))
        ~start:start_eid ~end_:end_eid
        ~start_legacy:(Some (Int64.to_int start_id))
        ~end_legacy:(Some (Int64.to_int end_id))
        ~type_ ~props
  | _ -> None

and hydrate_unbound_relationship t fields =
  match fields with
  (* Bolt <= 5.0: [id; type; properties]. *)
  | [ id_field; type_; props ] ->
      let* element_id, legacy_id = identity id_field in
      build_unbound t ~element_id ~legacy_id ~type_ ~props
  (* Bolt 5.1+/6: [id; type; properties; element_id]. *)
  | [ id_field; type_; props; element_id ] ->
      let* element_id, legacy_id = identity_of ~element_id id_field in
      build_unbound t ~element_id ~legacy_id ~type_ ~props
  | _ -> None

and build_unbound t ~element_id ~legacy_id ~type_ ~props =
  match (str type_, hydrate_props t props) with
  | Some rel_type, Some properties ->
      Some { Values.element_id; Values.legacy_id; Values.rel_type; Values.properties }
  | _ -> None

and hydrate_node_list t nodes =
  match list_ nodes with
  | None -> None
  | Some ls ->
      list_map_some
        (function Packstream.Structure (0x4E, fields) -> hydrate_node t fields | _ -> None)
        ls

and hydrate_unbound_list t rels =
  match list_ rels with
  | None -> None
  | Some ls ->
      list_map_some
        (function
          | Packstream.Structure (0x72, fields) -> hydrate_unbound_relationship t fields | _ -> None)
        ls

and int_list = function
  | Packstream.List items ->
      list_map_some (function Packstream.Int n -> Some (Int64.to_int n) | _ -> None) items
  | _ -> None

and hydrate_path t fields =
  match fields with
  | [ nodes; rels; sequence ] ->
      let* node_list = hydrate_node_list t nodes in
      let* rel_list = hydrate_unbound_list t rels in
      let* seq = int_list sequence in
      if node_list = [] || List.length seq mod 2 <> 0 then None
      else stitch_path node_list rel_list seq
  | _ -> None

(* Endpoint identities of a bound relationship, oriented by the sign of the
   path sequence entry: positive travels last -> next, negative next -> last. *)
and endpoints rel_idx (last : Values.node) (next_node : Values.node) =
  if rel_idx > 0 then
    ( last.Values.element_id,
      next_node.Values.element_id,
      last.Values.legacy_id,
      next_node.Values.legacy_id )
  else
    ( next_node.Values.element_id,
      last.Values.element_id,
      next_node.Values.legacy_id,
      last.Values.legacy_id )

(* Bind an unbound relationship (from a path's relationship list) to its
   endpoint nodes, whose identities come from the path sequence. *)
and bound unbound ~start ~end_ ~start_legacy ~end_legacy =
  {
    Values.element_id = unbound.Values.element_id;
    Values.legacy_id = unbound.Values.legacy_id;
    Values.rel_type = unbound.Values.rel_type;
    Values.start;
    Values.end_;
    Values.start_legacy_id = start_legacy;
    Values.end_legacy_id = end_legacy;
    Values.properties = unbound.Values.properties;
  }

and stitch_path node_list rel_list seq =
  let rec go (last : Values.node) (ordered_nodes : Values.node list)
      (bound_rels : Values.relationship list) = function
    | [] -> Some { Values.nodes = List.rev ordered_nodes; relationships = List.rev bound_rels }
    | rel_idx :: node_idx :: rest -> (
        match (List.nth_opt node_list node_idx, List.nth_opt rel_list (abs rel_idx - 1)) with
        | Some next_node, Some unbound when rel_idx <> 0 ->
            let start_eid, end_eid, start_legacy, end_legacy = endpoints rel_idx last next_node in
            let b = bound unbound ~start:start_eid ~end_:end_eid ~start_legacy ~end_legacy in
            go next_node (next_node :: ordered_nodes) (b :: bound_rels) rest
        | _ -> None)
    | _ -> None
  in
  let first = List.hd node_list in
  go first [ first ] [] seq

and hydrate_labels labels =
  match list_ labels with
  | None -> None
  | Some ls -> list_map_some (function Packstream.String l -> Some l | _ -> None) ls

and hydrate_props t props =
  match map_ props with
  | None -> None
  | Some entries ->
      list_map_some
        (fun (k, v) -> match hydrate t v with Values.Broken _ -> None | hv -> Some (k, hv))
        entries

and merge_labels a b =
  List.fold_left (fun acc l -> if List.mem l acc then acc else l :: acc) a b |> List.rev

and merge_props a b = List.fold_left (fun acc (k, v) -> (k, v) :: List.remove_assoc k acc) a b

(* --- dehydration --- *)

let rec dehydrate t value =
  match value with
  | Values.Null -> Packstream.Null
  | Values.Bool b -> Packstream.Bool b
  | Values.Int n -> Packstream.Int n
  | Values.Float f -> Packstream.Float f
  | Values.String s -> Packstream.String s
  | Values.Bytes b -> Packstream.Bytes b
  | Values.Uuid u -> (
      match (t.version, t.minor) with
      | V3, minor when minor >= 1 -> Packstream.Uuid u
      | _ -> invalid_arg "UUID is not supported before Bolt 6.1")
  | Values.List items -> Packstream.List (List.map (dehydrate t) items)
  | Values.Map entries -> Packstream.Map (List.map (fun (k, v) -> (k, dehydrate t v)) entries)
  | Values.Node n ->
      Packstream.Structure
        ( 0x4E,
          [
            id_field t.version n.legacy_id n.element_id;
            Packstream.List (List.map (fun l -> Packstream.String l) n.labels);
            dehydrate_props t n.properties;
          ] )
  | Values.Relationship r ->
      Packstream.Structure
        ( 0x52,
          [
            id_field t.version r.legacy_id r.element_id;
            Packstream.String r.start;
            Packstream.String r.end_;
            Packstream.String r.rel_type;
            dehydrate_props t r.properties;
          ] )
  | Values.Unbound_relationship r ->
      Packstream.Structure
        ( 0x72,
          [
            id_field t.version r.legacy_id r.element_id;
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
               [ Packstream.Int (Int64.of_int (i + 1)); Packstream.Int (Int64.of_int (i + 1)) ])
             p.relationships)
      in
      Packstream.Structure
        (0x50, [ Packstream.List nodes; Packstream.List rels; Packstream.List sequence ])
  | Values.Point pt -> (
      match pt.z with
      | None ->
          Packstream.Structure
            ( 0x58,
              [
                Packstream.Int (Int64.of_int pt.srid); Packstream.Float pt.x; Packstream.Float pt.y;
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
      Packstream.Structure (0x44, [ Packstream.Int (Int64.of_int (Temporal.Date.to_days d)) ])
  | Values.Time tm -> (
      let ns = Temporal.Time.to_ticks tm in
      match Temporal.Time.tz_offset_seconds tm with
      | None -> Packstream.Structure (0x74, [ Packstream.Int ns ])
      | Some off ->
          Packstream.Structure (0x54, [ Packstream.Int ns; Packstream.Int (Int64.of_int off) ]))
  | Values.DateTime dt -> (
      let seconds, nanoseconds = Temporal.DateTime.to_epoch_seconds dt in
      (* Bolt 3/4 encodes the WALL-clock seconds (the local unix epoch), Bolt
         5+ the UTC epoch; the offset/zone is carried separately in both. *)
      let wire_seconds offset =
        if t.version = V1 then Int64.add seconds (Int64.of_int offset) else seconds
      in
      match Temporal.DateTime.tz dt with
      | None ->
          Packstream.Structure
            (0x64, [ Packstream.Int seconds; Packstream.Int (Int64.of_int nanoseconds) ])
      | Some (Offset offset) ->
          let tag = if t.version = V1 then 0x46 else 0x49 in
          Packstream.Structure
            ( tag,
              [
                Packstream.Int (wire_seconds offset);
                Packstream.Int (Int64.of_int nanoseconds);
                Packstream.Int (Int64.of_int offset);
              ] )
      | Some (Zone_name name) ->
          let tag = if t.version = V1 then 0x66 else 0x69 in
          let offset =
            match Temporal.DateTime.offset_seconds dt with Some off -> off | None -> 0
          in
          Packstream.Structure
            ( tag,
              [
                Packstream.Int (wire_seconds offset);
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
      let marker = Bytes.make 1 '\000' in
      Bytes.set_uint8 marker 0 (vector_dtype_marker v.dtype);
      Packstream.Structure (0x56, [ Packstream.Bytes marker; Packstream.Bytes v.data ])
  | Values.Unsupported u ->
      let major, minor = u.minimum_protocol_version in
      let extra =
        match u.message with Some m -> [ ("message", Packstream.String m) ] | None -> []
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

(* The leading id field of a graph entity on the wire: the legacy integer id
   for Bolt 3/4, the element_id string otherwise. *)
and id_field version legacy_id element_id =
  match (legacy_id, version) with
  | Some id, V1 -> Packstream.Int (Int64.of_int id)
  | _ -> Packstream.String element_id

(* Dehydrate an association list of [(name, value)] pairs (query parameters or
   tx_metadata), failing with a Configuration_error on a value the negotiated
   protocol version cannot encode (e.g. a UUID before Bolt 6.1). *)
let dehydrate_assoc_list t entries =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (name, value) :: rest -> (
        match dehydrate t value with
        | v -> go ((name, v) :: acc) rest
        | exception Invalid_argument msg -> Error (Errors.Configuration_error msg))
  in
  go [] entries
