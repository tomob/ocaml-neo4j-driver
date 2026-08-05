(* Eio-based TCP transport with Bolt message framing.

   Modeled on the Neo4j Python driver's _async/io/_bolt_socket.py. Provides
   deadline-bounded reads/writes and the Bolt chunk framing (16-bit chunk size
   prefixes, a 0x0000 terminator and NOOP skipping).

   Note: SO_KEEPALIVE is not exposed by Eio's portable Net API and is deferred
   until a platform-specific mechanism is available. *)

open Eio.Std
open Neodriver_core

let ( let* ) = Result.bind
let cancelled = function Eio.Cancel.Cancelled _ -> true | _ -> false

type tls_mode = Plain | Verify of string | Trust_all of string

type t = {
  socket : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r;
  clock : [ `Clock of float ] r;
  timeout : float option;
}

(* Bolt messages are sent in chunks of at most 64 KiB; the drivers use 16 KiB. *)
let chunk_size = 16384

let resolve_host net host port =
  match Eio.Net.getaddrinfo_stream net ~service:(string_of_int port) host with
  | sockaddr :: _ -> Some sockaddr
  | [] -> None

let sockaddr_of_address net = function
  | Addressing.IPv4 (host, port) | Addressing.IPv6 (host, port, _, _) -> resolve_host net host port

let connect net clock sw ?(timeout = infinity) ?(tls = Plain) address =
  let timeout = if timeout = infinity then None else Some timeout in
  let with_timeout f =
    match timeout with None -> f () | Some timeout -> Eio.Time.with_timeout_exn clock timeout f
  in
  match sockaddr_of_address net address with
  | None ->
      Error
        (Errors.Service_unavailable
           (Printf.sprintf "Could not resolve address %s" (Addressing.to_string address)))
  | Some sockaddr -> (
      let connect () =
        match timeout with
        | None -> Eio.Net.connect ~sw net sockaddr
        | Some timeout ->
            Eio.Time.with_timeout_exn clock timeout (fun () -> Eio.Net.connect ~sw net sockaddr)
      in
      let secure socket =
        match tls with
        | Plain -> Ok socket
        | Verify host -> Tls_client.wrap { Tls_client.mode = Verify; host } socket
        | Trust_all host -> Tls_client.wrap { Tls_client.mode = Trust_all; host } socket
      in
      let wrap socket =
        let socket = (socket :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r) in
        let* socket = with_timeout (fun () -> secure socket) in
        Ok { socket; clock; timeout }
      in
      match connect () with
      | exception Eio.Time.Timeout -> Error (Errors.Service_unavailable "Connection timed out")
      | exception exn ->
          Error
            (Errors.Service_unavailable
               (Printf.sprintf "Connection failed: %s" (Printexc.to_string exn)))
      | socket -> (
          match wrap socket with
          | exception Eio.Time.Timeout -> Error (Errors.Service_unavailable "Connection timed out")
          | exception exn ->
              if cancelled exn then raise exn
              else
                Error
                  (Errors.Service_unavailable
                     (Printf.sprintf "Connection failed: %s" (Printexc.to_string exn)))
          | Ok transport -> Ok transport
          | Error _ as error -> error))

let read_exact t buf off len =
  let buffer = Cstruct.create len in
  let rec go n_read =
    if n_read = len then ()
    else
      let chunk = Cstruct.sub buffer n_read (len - n_read) in
      let n = Eio.Flow.single_read t.socket chunk in
      if n = 0 then raise End_of_file else go (n_read + n)
  in
  try
    (match t.timeout with
    | None -> go 0
    | Some timeout -> Eio.Time.with_timeout_exn t.clock timeout (fun () -> go 0));
    Bytes.blit (Cstruct.to_bytes buffer) 0 buf off len;
    Ok ()
  with
  | Eio.Time.Timeout -> Error (Errors.Service_unavailable "Read timed out")
  | End_of_file -> Error (Errors.Service_unavailable "Connection closed")

let write t buf =
  let buffer = Cstruct.of_bytes buf in
  let write () = Eio.Flow.write t.socket [ buffer ] in
  try
    match t.timeout with
    | None -> Ok (write ())
    | Some timeout -> Ok (Eio.Time.with_timeout_exn t.clock timeout write)
  with
  | Eio.Time.Timeout -> Error (Errors.Service_unavailable "Write timed out")
  | exn ->
      Error
        (Errors.Service_unavailable (Printf.sprintf "Write failed: %s" (Printexc.to_string exn)))

let write_message t message =
  let len = Bytes.length message in
  let n_chunks = (len + chunk_size - 1) / chunk_size in
  let out = Bytes.create ((n_chunks * (2 + chunk_size)) + 2) in
  let pos = ref 0 in
  let offset = ref 0 in
  while !offset < len do
    let chunk_len = min chunk_size (len - !offset) in
    Bytes.set_uint16_be out !pos chunk_len;
    pos := !pos + 2;
    Bytes.blit message !offset out !pos chunk_len;
    pos := !pos + chunk_len;
    offset := !offset + chunk_len
  done;
  Bytes.set_uint16_be out !pos 0;
  write t (Bytes.sub out 0 (!pos + 2))

let read_message t =
  let buffer = Buffer.create 256 in
  let size_buf = Bytes.create 2 in
  let rec loop () =
    let* () = read_exact t size_buf 0 2 in
    let size = Bytes.get_uint16_be size_buf 0 in
    if size = 0 then
      (* Terminator: a message with no payload is a NOOP, skip it. *)
      if Buffer.length buffer = 0 then loop () else Ok (Buffer.to_bytes buffer)
    else begin
      let chunk = Bytes.create size in
      let* () = read_exact t chunk 0 size in
      Buffer.add_bytes buffer chunk;
      loop ()
    end
  in
  loop ()

let close t = Eio.Resource.close t.socket
