(* Friendly names for the whole Neo4j driver.

   Aggregates the public API of all packages under a single namespace, so
   consumers can `open Neodriver` and use Packstream, Errors, Config,
   Addressing, Deadline and Driver directly. *)

module Packstream = Neodriver_packstream.Packstream
module Errors = Neodriver_core.Errors
module Config = Neodriver_core.Config
module Addressing = Neodriver_core.Addressing
module Deadline = Neodriver_core.Deadline
module Driver = Neodriver_eio.Driver
