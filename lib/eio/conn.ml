(* Minimal Bolt connection: TCP connect + handshake.

   A [t] represents an established Bolt connection (transport + agreed
   protocol version). HELLO, authentication and queries belong to later
   phases. TLS (bolt+s / bolt+ssc) is not implemented yet. *)

open Neodriver_core

let ( let* ) = Result.bind

type config = { host : string; port : int; scheme : Addressing.scheme; connection_timeout : float }
type t = { transport : Transport.t; major : int; minor : int }

let connect net clock sw config =
  match config.scheme with
  | Addressing.Bolt ->
      let* address =
        Addressing.parse ~default_host:"localhost" ~default_port:7687
          (Printf.sprintf "%s:%d" config.host config.port)
      in
      let* transport = Transport.connect net clock sw ~timeout:config.connection_timeout address in
      let* major, minor = Handshake.negotiate transport in
      Ok { transport; major; minor }
  | _ -> Error (Errors.Service_unavailable "TLS is not supported yet")

let close t = Transport.close t.transport
