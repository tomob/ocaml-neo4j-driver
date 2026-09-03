(* TestKit backend: a JSON-over-TCP server in Eio.

   The TestKit harness connects to the backend on a TCP port (default 9876) and
   exchanges requests ({"name": ..., "data": {...}}) framed by
   #request begin / #request end lines; responses are framed by
   #response begin / #response end. The connection context also lets handlers
   push unsolicited messages to the harness (e.g. ResolverResolutionRequired)
   and read the follow-up request. Modeled on the Python driver's
   testkitbackend/server.py. *)

let max_request_size = 64 * 1024 * 1024

let port =
  match Sys.getenv_opt "TESTKIT_BACKEND_PORT" with
  | Some value -> ( match int_of_string_opt value with Some n -> n | None -> 9876)
  | None -> 9876

let write_response flow (name, data) =
  let json = Yojson.Safe.to_string (`Assoc [ ("name", `String name); ("data", data) ]) in
  Eio.Flow.write flow [ Cstruct.of_string ("#response begin\n" ^ json ^ "\n#response end\n") ]

(* Serve one connection: read requests until end-of-file. The context's [read]
   and [send] share the same line reader so handlers can push messages and
   consume the follow-up requests (e.g. custom resolution). *)
let handle_connection net clock sw flow =
  let mock, clock = Fake_time.create clock in
  let reader = Eio.Buf_read.of_flow ~max_size:max_request_size flow in
  let lines = Eio.Buf_read.lines reader in
  let state = ref lines in
  let buffer = Buffer.create 256 in
  let rec read_one_request () =
    match !state () with
    | Seq.Nil -> None
    | Seq.Cons (line, rest) ->
        state := rest;
        if line = "#request begin" then begin
          Buffer.clear buffer;
          read_one_request ()
        end
        else if line = "#request end" then Some (Buffer.contents buffer)
        else begin
          Buffer.add_string buffer line;
          read_one_request ()
        end
  in
  let ctx =
    Commands.
      {
        net;
        clock;
        mock;
        sw;
        send = (fun name data -> write_response flow (name, data));
        read = read_one_request;
      }
  in
  let rec loop () =
    match read_one_request () with
    | None -> ()
    | Some json ->
        (match Commands.dispatch ctx json with
        | Some response -> write_response flow response
        | None -> ());
        loop ()
  in
  loop ()

let run () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let listening =
            Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw net (`Tcp (Eio.Net.Ipaddr.V4.any, port))
          in
          let rec serve () =
            Eio.Net.accept_fork ~sw listening
              ~on_error:(fun exn ->
                prerr_endline ("testkit backend: connection error: " ^ Printexc.to_string exn))
              (fun flow _client_addr -> handle_connection net clock sw flow);
            serve ()
          in
          serve ()))
