(* A minimal mock Bolt server for unit-testing the transport and handshake
   without a live Neo4j instance. *)

open Eio.Std

type behavior =
  | V1 of int * int
  | Reject
  | Http
  | Manifest_unknown
  | Manifest of (int * int * int) list

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r

let magic = Bytes.of_string "\x60\x60\xb0\x17"
let proposal = Bytes.of_string "\x00\x00\x01\xff\x00\x08\x08\x05\x00\x02\x04\x04\x00\x00\x00\x03"

let read_exact flow n =
  let buf = Cstruct.create n in
  let rec go off =
    if off = n then Cstruct.to_string buf
    else
      let m = Eio.Flow.single_read flow (Cstruct.sub buf off (n - off)) in
      if m = 0 then failwith "mock: unexpected EOF" else go (off + m)
  in
  go 0

let write flow s = Eio.Flow.write flow [ Cstruct.of_string s ]
let varint n = String.make 1 (Char.chr n)

let serve_behavior behavior flow =
  match behavior with
  | V1 (major, minor) ->
      write flow ("\x00\x00" ^ String.make 1 (Char.chr minor) ^ String.make 1 (Char.chr major))
  | Reject -> write flow "\x00\x00\x00\x00"
  | Http -> write flow "HTTP"
  | Manifest_unknown -> write flow "\x00\x00\x02\xff"
  | Manifest offerings ->
      write flow "\x00\x00\x01\xff";
      write flow (varint (List.length offerings));
      List.iter
        (fun (major, minor, range) ->
          write flow
            ("\x00"
            ^ String.make 1 (Char.chr range)
            ^ String.make 1 (Char.chr minor)
            ^ String.make 1 (Char.chr major)))
        offerings;
      write flow "\x00";
      (* The client replies with its chosen version and capabilities. *)
      ignore (read_exact flow 5)

let with_server handler client =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
          let listening =
            Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr listening with `Tcp (_, port) -> port | _ -> assert false
          in
          let server =
            Eio.Fiber.fork_promise ~sw (fun () ->
                let flow, _ = Eio.Net.accept ~sw listening in
                let flow = (flow :> flow) in
                handler flow)
          in
          let result = client net clock sw port in
          ignore (Eio.Promise.await_exn server);
          result))

let with_mock behavior client = with_server (serve_behavior behavior) client
