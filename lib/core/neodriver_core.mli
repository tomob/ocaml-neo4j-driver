(** Public interface of the neodriver_core library.

    Curated public surface: only the modules aliased here are part of the public API. *)

module Errors = Errors
(** Error taxonomy (server and driver errors). *)

module Config = Config
(** Configuration records with validated constructors. *)

module Addressing = Addressing
(** Server addresses and URI parsing. *)

module Deadline = Deadline
(** Deadlines for unified timing. *)

module Temporal = Temporal
(** Date/Time/DateTime/Duration value types. *)

module Values = Values
(** Rich value types (graph, spatial, temporal, vector, unsupported, broken). *)

module Hydration = Hydration
(** Conversion between PackStream values and rich values. *)

module Capabilities = Capabilities
(** Per-version Bolt protocol capabilities. *)
