(* Friendly names for the whole Neo4j driver.

   Aggregates the public API of all packages under a single namespace, so
   consumers can `open Neodriver` and use Packstream, Errors, Config,
   Addressing, Deadline and Driver directly. *)

module Packstream = Neodriver_packstream.Packstream
(** PackStream binary serialization. *)

module Errors = Neodriver_core.Errors
(** Error taxonomy. *)

module Config = Neodriver_core.Config
(** Configuration records. *)

module Addressing = Neodriver_core.Addressing
(** Server addresses and URI parsing. *)

module Deadline = Neodriver_core.Deadline
(** Deadlines. *)

module Temporal = Neodriver_core.Temporal
(** Temporal value types. *)

module Values = Neodriver_core.Values
(** Rich value types. *)

module Hydration = Neodriver_core.Hydration
(** Hydration. *)

module Capabilities = Neodriver_core.Capabilities
(** Per-version Bolt protocol capabilities. *)

module Driver = Neodriver_eio.Driver
(** Eio backend entry point. *)
