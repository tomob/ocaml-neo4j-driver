(* A minimal mock Bolt server for unit-testing the transport and handshake
   without a live Neo4j instance. *)

open Eio.Std

type response =
  | Success
  | Success_meta of (string * Neodriver.Packstream.value) list
  | Failure of string * string
  | Failure_gql of string * string
  | Ignored
  | Records of Neodriver.Packstream.value list list * bool

type behavior =
  | V1 of int * int
  | Reject
  | Http
  | Manifest_unknown
  | Manifest of (int * int * int) list
  | Session of (int * int) * Bytes.t list ref * response list
(* handshake at the given version, then read one Bolt message per
         [response], recording each in [received] and replying accordingly *)

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

(* Read one Bolt message (chunk framing) from the flow. *)
let read_message flow =
  let buffer = Buffer.create 256 in
  let rec loop () =
    let size_bytes = read_exact flow 2 in
    let size = (Char.code size_bytes.[0] * 256) + Char.code size_bytes.[1] in
    if size = 0 then if Buffer.length buffer = 0 then loop () else Buffer.contents buffer
    else begin
      Buffer.add_string buffer (read_exact flow size);
      loop ()
    end
  in
  loop ()

(* Write one Bolt message (single chunk + terminator). *)
let write_message flow s =
  write flow
    (String.make 1 (Char.chr (String.length s lsr 8))
    ^ String.make 1 (Char.chr (String.length s land 0xff))
    ^ s ^ "\x00\x00")

let reply_message flow = function
  | Success ->
      write_message flow
        (Bytes.to_string
           (Neodriver.Packstream.pack
              (Neodriver.Packstream.Structure (0x70, [ Neodriver.Packstream.Map [] ]))))
  | Success_meta metadata ->
      write_message flow
        (Bytes.to_string
           (Neodriver.Packstream.pack
              (Neodriver.Packstream.Structure (0x70, [ Neodriver.Packstream.Map metadata ]))))
  | Failure (code, message) ->
      write_message flow
        (Bytes.to_string
           (Neodriver.Packstream.pack
              (Neodriver.Packstream.Structure
                 ( 0x7F,
                   [
                     Neodriver.Packstream.Map
                       [
                         ("code", Neodriver.Packstream.String code);
                         ("message", Neodriver.Packstream.String message);
                       ];
                   ] ))))
  | Failure_gql (code, message) ->
      (* Bolt 6 FAILURE carries the code under [neo4j_code]. *)
      write_message flow
        (Bytes.to_string
           (Neodriver.Packstream.pack
              (Neodriver.Packstream.Structure
                 ( 0x7F,
                   [
                     Neodriver.Packstream.Map
                       [
                         ("neo4j_code", Neodriver.Packstream.String code);
                         ("message", Neodriver.Packstream.String message);
                       ];
                   ] ))))
  | Ignored ->
      write_message flow
        (Bytes.to_string
           (Neodriver.Packstream.pack
              (Neodriver.Packstream.Structure (0x7E, [ Neodriver.Packstream.Map [] ]))))
  | Records (records, has_more) ->
      List.iter
        (fun values ->
          write_message flow
            (Bytes.to_string
               (Neodriver.Packstream.pack
                  (Neodriver.Packstream.Structure (0x71, [ Neodriver.Packstream.List values ])))))
        records;
      write_message flow
        (Bytes.to_string
           (Neodriver.Packstream.pack
              (Neodriver.Packstream.Structure
                 ( 0x70,
                   [ Neodriver.Packstream.Map [ ("has_more", Neodriver.Packstream.Bool has_more) ] ]
                 ))))

let rec serve_behavior behavior flow =
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
  | Session (version, received, responses) ->
      (* Consume the client's handshake (magic + 16-byte proposal); the V1
         response below does not itself read it. *)
      ignore (read_exact flow 20);
      serve_behavior (V1 (fst version, snd version)) flow;
      List.iter
        (fun response ->
          let message = read_message flow in
          received := Bytes.of_string message :: !received;
          reply_message flow response)
        responses

(* Whether binding a loopback TCP socket is allowed. Some sandboxed
   environments (e.g. the opam build on macOS arm64) forbid it with an EPERM
   on [bind]; the mock-server tests are then skipped rather than failed. *)
let can_bind =
  lazy
    (Eio_main.run (fun env ->
         Eio.Switch.run (fun sw ->
             try
               ignore
                 (Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw (Eio.Stdenv.net env)
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)));
               true
             with _ -> false)))

let with_server handler client =
  if not (Lazy.force can_bind) then Alcotest.skip ();
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
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

(* Serve several sequential connections, each with its own [Session]-style
   behavior, sharing the [received] log. The client connects once per session
   (e.g. a pool that opens a fresh connection after discarding an old one). *)
let with_mock_multi sessions client =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
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
                List.iter
                  (fun (version, received, responses) ->
                    let flow, _ = Eio.Net.accept ~sw listening in
                    let flow = (flow :> flow) in
                    serve_behavior (Session (version, received, responses)) flow;
                    (* Close the flow so a client that sends more (e.g. the pool's
                       RESET on release of a connection we have nothing left for)
                       fails fast instead of waiting for a response. *)
                    Eio.Flow.close flow)
                  sessions)
          in
          let result = client net clock sw port in
          ignore (Eio.Promise.await_exn server);
          result))

(* Serve [n] concurrent mock servers on separate ports, each serving its own
   sequence of [Session]-style connections. [make_connections] receives the
   servers' ports (needed to build routing tables that address the mocks) and
   returns the per-server connection lists; [client] receives the ports. *)
let with_servers n make_connections client =
  if not (Lazy.force can_bind) then Alcotest.skip ();
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let listeners =
            List.init n (fun _ ->
                let listening =
                  Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
                in
                let port =
                  match Eio.Net.listening_addr listening with
                  | `Tcp (_, port) -> port
                  | _ -> assert false
                in
                (listening, port))
          in
          let ports = List.map snd listeners in
          let connections = make_connections ports in
          let servers =
            List.map2
              (fun (listening, _) connection_list ->
                Eio.Fiber.fork_promise ~sw (fun () ->
                    List.iter
                      (fun (version, received, responses) ->
                        let flow, _ = Eio.Net.accept ~sw listening in
                        let flow = (flow :> flow) in
                        serve_behavior (Session (version, received, responses)) flow;
                        Eio.Flow.close flow)
                      connection_list))
              listeners connections
          in
          let result = client net clock sw ports in
          List.iter (fun server -> ignore (Eio.Promise.await_exn server)) servers;
          result))
