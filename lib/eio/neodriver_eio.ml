(* Public interface of the neodriver_eio library.

   This root module curates which modules of the library are exposed to
   consumers. Only modules aliased here are part of the public API. *)
module Driver = Driver
module Transport = Transport
module Handshake = Handshake
module Conn = Conn
module Bolt = Bolt
module State = State
module Tx = Tx
module Session = Session
module Pool = Pool
module Cluster = Cluster
module Neo4jResult = Neo4j_result
module Summary = Summary
