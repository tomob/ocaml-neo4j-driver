(* Hydration — conversion between the transport-level PackStream values and
   the rich Neo4j values. See hydration.ml for the implementation. *)

open Neodriver_packstream

type version =
  | V1
  | V2
  | V3  (** Bolt protocol version family: [V1] = Bolt 3/4, [V2] = Bolt 5, [V3] = Bolt 6. *)

type t
(** A hydration scope holding the per-query graph state; create one per result. *)

val create : version -> t
(** Create a new hydration scope for the given protocol version. *)

val version : t -> version
(** The protocol version of this scope. *)

val hydrate : t -> Packstream.value -> Values.t
(** Convert a transport-level PackStream value into a rich value. Undecodable structures become a
    [Broken] value which propagates through lists and maps. *)

val dehydrate : t -> Values.t -> Packstream.value
(** Convert a rich value back into a transport-level PackStream value. Raises [Invalid_argument] for
    [Broken] values. *)

val nodes : t -> Values.node list
(** All nodes hydrated so far in this scope, deduplicated by [element_id]. *)

val relationships : t -> Values.relationship list
(** All relationships hydrated so far in this scope. *)
