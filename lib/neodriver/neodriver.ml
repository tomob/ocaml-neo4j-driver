(* Friendly names for the whole Neo4j driver.

   Aggregates the public API of all packages under a single namespace, so
   consumers can `open Neodriver` and use Packstream, Errors, Config,
   Addressing, Deadline, Conn, Session, Tx, Transport, Bolt, State, Values,
   Temporal, Hydration, Capabilities, Neo4jResult, Summary and Driver
   directly. *)
module Packstream = Neodriver_packstream.Packstream
module Errors = Neodriver_core.Errors
module Config = Neodriver_core.Config
module Addressing = Neodriver_core.Addressing
module Deadline = Neodriver_core.Deadline
module Temporal = Neodriver_core.Temporal
module Values = Neodriver_core.Values
module Hydration = Neodriver_core.Hydration
module Capabilities = Neodriver_core.Capabilities
module Routing_table = Neodriver_core.Routing_table
module Auth_manager = Neodriver_core.Auth_manager
module Conn = Neodriver_eio.Conn
module Session = Neodriver_eio.Session
module Tx = Neodriver_eio.Tx
module Transport = Neodriver_eio.Transport
module Bolt = Neodriver_eio.Bolt
module State = Neodriver_eio.State
module Cluster = Neodriver_eio.Cluster
module Neo4jResult = Neodriver_eio.Neo4jResult
module Summary = Neodriver_eio.Summary
module Driver = Neodriver_eio.Driver
module Log = Neodriver_eio.Log
