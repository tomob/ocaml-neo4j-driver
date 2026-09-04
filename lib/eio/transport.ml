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
  id : int;
  socket : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r;
  mutable timeout : Eio.Time.Timeout.t;
}

(* Bolt messages are sent in chunks of at most 64 KiB; the drivers use 16 KiB. *)
let chunk_size = 16384
let id t = t.id

(* Replace the timeout bounding reads (and writes) on the connection: the
   server advertises a receive timeout through the [connection.recv_timeout_seconds]
   HELLO hint, overriding the driver-configured default for that connection. *)
let set_read_timeout t timeout = t.timeout <- timeout

(* A read that ran out of time means the connection is defunct (like the Python
   driver, which closes a connection whose receive timed out): close the socket
   so the pool drops it and the next operation reconnects. *)
let close_after_timeout t = try Eio.Resource.close t.socket with _ -> ()

let sockaddrs_of_address net = function
  | Addressing.IPv4 (host, port) | Addressing.IPv6 (host, port, _, _) -> (
      try Eio.Net.getaddrinfo_stream net ~service:(string_of_int port) host
      with
      (* Workaround for FreeBSD (and maybe other systems?): getaddrinfo fails to 
         resolve "localhost" when the system lacks the localhost entry in /etc/hosts. 
         Fall back to the loopback addresses directly; other systems keep using the system
          resolver. *)
      | Eio.Io (Eio.Net.E _, _) when String.equal (String.lowercase_ascii host) "localhost" ->
        [ `Tcp (Eio.Net.Ipaddr.V4.loopback, port); `Tcp (Eio.Net.Ipaddr.V6.loopback, port) ])

let connect net sw ?(timeout = Eio.Time.Timeout.none) ?(tls = Plain) address =
  (* One total deadline covering every TCP connect / TLS handshake attempt. *)
  let with_timeout f =
    try Eio.Time.Timeout.run_exn timeout f with
    | Eio.Time.Timeout ->
        Log.debug Log.io (fun m -> m "[#0000]  S: <TIMEOUT> %s" (Addressing.to_string address));
        Error (Errors.Service_unavailable "Connection timed out")
    | exn ->
        if cancelled exn then begin
          Log.debug Log.io (fun m -> m "[#0000]  S: <CANCELLED> %s" (Addressing.to_string address));
          raise exn
        end
        else
          Error
            (Errors.Service_unavailable
               (Printf.sprintf "Connection failed: %s" (Printexc.to_string exn)))
  in
  let secure id socket =
    let socket = (socket :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r) in
    match tls with
    | Plain -> Ok socket
    | Verify host ->
        Log.debug Log.io (fun m -> m "[#%04X]  C: <SECURE> %s" id host);
        Tls_client.wrap { Tls_client.mode = Verify; host } socket
        |> Result.map_error (fun error ->
            Log.debug Log.io (fun m ->
                m "[#%04X]  S: <SECURE FAILURE> %s: %s" id host (Errors.to_string error));
            error)
    | Trust_all host ->
        Log.debug Log.io (fun m -> m "[#%04X]  C: <SECURE> %s" id host);
        Tls_client.wrap { Tls_client.mode = Trust_all; host } socket
        |> Result.map_error (fun error ->
            Log.debug Log.io (fun m ->
                m "[#%04X]  S: <SECURE FAILURE> %s: %s" id host (Errors.to_string error));
            error)
  in
  let sockaddr_str sockaddr = Format.asprintf "%a" Eio.Net.Sockaddr.pp sockaddr in
  (* getaddrinfo_stream never returns an empty list; a failed lookup raises
     Eio.Io (Eio.Net.E _, _), which we report as an unresolvable address. *)
  match sockaddrs_of_address net address with
  | exception Eio.Io (Eio.Net.E _, _) ->
      Log.debug Log.io (fun m ->
          m "[#0000]  S: <ERROR> Could not resolve address %s" (Addressing.to_string address));
      Error
        (Errors.Service_unavailable
           (Printf.sprintf "Could not resolve address %s" (Addressing.to_string address)))
  | sockaddrs ->
      (* Try each resolved address in turn; a connection or TLS failure moves on
         to the next, and all failures are aggregated into the final error. *)
      with_timeout (fun () ->
          let rec go failed errors = function
            | [] ->
                let failures = { Errors.last = List.hd errors; all = List.rev errors } in
                Error
                  (Errors.Service_unavailable
                     (Addressing.connect_failure_message ~address ~resolved:failed ~failures))
            | sockaddr :: rest -> (
                Log.debug Log.io (fun m -> m "[#0000]  C: <OPEN> %s" (sockaddr_str sockaddr));
                match try Ok (Eio.Net.connect ~sw net sockaddr) with exn -> Error exn with
                | Error exn ->
                    if cancelled exn then begin
                      Log.debug Log.io (fun m ->
                          m "[#0000]  S: <CANCELLED> %s" (sockaddr_str sockaddr));
                      raise exn
                    end;
                    Log.debug Log.io (fun m ->
                        m "[#0000]  S: <CONNECTION FAILED> %s %s" (sockaddr_str sockaddr)
                          (Printexc.to_string exn));
                    go (sockaddr_str sockaddr :: failed)
                      (Errors.Service_unavailable (Printexc.to_string exn) :: errors)
                      rest
                | Ok socket -> (
                    let id = Log.next_id () in
                    match secure id socket with
                    | Ok socket -> Ok { socket; timeout; id }
                    | Error error ->
                        Log.debug Log.io (fun m ->
                            m "[#0000]  S: <CONNECTION FAILED> %s %s" (sockaddr_str sockaddr)
                              (Errors.to_string error));
                        go (sockaddr_str sockaddr :: failed) (error :: errors) rest))
          in
          go [] [] sockaddrs)

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
    Eio.Time.Timeout.run_exn t.timeout (fun () -> go 0);
    Bytes.blit (Cstruct.to_bytes buffer) 0 buf off len;
    Ok ()
  with
  | Eio.Time.Timeout ->
      close_after_timeout t;
      Error (Errors.Service_unavailable "Read timed out")
  | End_of_file -> Error (Errors.Service_unavailable "Connection closed")
  | exn ->
      (* A socket-level failure (e.g. a peer resetting the connection mid-read)
         must surface as a service-unavailable error, not leak as a raw
         exception: callers treat an [Error] as a failed connection attempt and
         fall through to the next resolved address. Cancellation is re-raised
         so the Eio cancellation context stays in control. *)
      if cancelled exn then raise exn
      else
        Error
          (Errors.Service_unavailable (Printf.sprintf "Read failed: %s" (Printexc.to_string exn)))

let write t buf =
  let buffer = Cstruct.of_bytes buf in
  let write () = Eio.Flow.write t.socket [ buffer ] in
  try Ok (Eio.Time.Timeout.run_exn t.timeout write) with
  | Eio.Time.Timeout -> Error (Errors.Service_unavailable "Write timed out")
  | exn ->
      if cancelled exn then raise exn
      else
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
      if Buffer.length buffer = 0 then begin
        Log.debug Log.io (fun m -> m "[#%04X]  S: <NOOP>" t.id);
        loop ()
      end
      else Ok (Buffer.to_bytes buffer)
    else begin
      let chunk = Bytes.create size in
      let* () = read_exact t chunk 0 size in
      Buffer.add_bytes buffer chunk;
      loop ()
    end
  in
  loop ()

let close t = Eio.Resource.close t.socket
