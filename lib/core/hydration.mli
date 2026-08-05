(* Hydration — conversion between the transport-level PackStream values and
   the rich Neo4j values. See hydration.ml for the implementation. *)

open Neodriver_packstream

type version = V1 | V2 | V3
type t

val create : version -> t
val version : t -> version
val hydrate : t -> Packstream.value -> Values.t
val dehydrate : t -> Values.t -> Packstream.value
val nodes : t -> Values.node list
val relationships : t -> Values.relationship list
