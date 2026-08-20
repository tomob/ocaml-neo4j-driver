(** Hydration — conversion between the transport-level PackStream values and the rich Neo4j values.
    See hydration.ml for the implementation. *)

open Neodriver_packstream

type version =
  | V1
  | V2
  | V3  (** Bolt protocol version family: [V1] = Bolt 3/4, [V2] = Bolt 5, [V3] = Bolt 6. *)

type t
(** A hydration scope holding the per-query graph state; create one per result. *)

val create : ?minor:int -> version -> t
(** A fresh hydration scope. [minor] (default 0) is the negotiated protocol minor version, which
    gates Bolt 6.1-only types such as UUID. *)

val version : t -> version
(** The protocol version of this scope. *)

val hydrate : t -> Packstream.value -> Values.t
(** Convert a transport-level PackStream value into a rich value. Undecodable structures become a
    [Broken] value which propagates through lists and maps. *)

val dehydrate : t -> Values.t -> Packstream.value
(** Convert a rich value back into a transport-level PackStream value. Raises [Invalid_argument] for
    [Broken] values. *)

val dehydrate_assoc_list :
  t -> (string * Values.t) list -> ((string * Packstream.value) list, Errors.t) result
(** Dehydrate an association list of [(name, value)] pairs (query parameters or tx_metadata),
    failing with a [Configuration_error] on a value the negotiated protocol version cannot encode
    (e.g. a UUID before Bolt 6.1). *)

val nodes : t -> Values.node list
(** All nodes hydrated so far in this scope, deduplicated by [element_id]. *)

val relationships : t -> Values.relationship list
(** All relationships hydrated so far in this scope. *)
