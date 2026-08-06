(* TestKit backend: a JSON-over-TCP server in Eio.

   The TestKit harness connects to the backend on a TCP port (default 9876) and
   exchanges requests ({"name": ..., "data": {...}}) framed by
   #request begin / #request end lines; responses are framed by
   #response begin / #response end. Modeled on the Python driver's
   testkitbackend/server.py. *)

let max_request_size = 64 * 1024 * 1024

let port =
  match Sys.getenv_opt "TESTKIT_BACKEND_PORT" with
  | Some value -> ( match int_of_string_opt value with Some n -> n | None -> 9876)
  | None -> 9876

let write_response flow (name, data) =
  let json = Yojson.Safe.to_string (`Assoc [ ("name", `String name); ("data", data) ]) in
  Eio.Flow.write flow [ Cstruct.of_string ("#response begin\n" ^ json ^ "\n#response end\n") ]

let handle_request flow json =
  let response = Commands.dispatch json in
  write_response flow response

(* Serve one connection: read requests until end-of-file. *)
let handle_connection flow =
  let reader = Eio.Buf_read.of_flow ~max_size:max_request_size flow in
  let lines = Eio.Buf_read.lines reader in
  let buffer = Buffer.create 256 in
  let rec loop seq =
    match seq () with
    | Seq.Nil -> ()
    | Seq.Cons (line, rest) ->
        if line = "#request begin" then begin
          Buffer.clear buffer;
          loop rest
        end
        else if line = "#request end" then begin
          handle_request flow (Buffer.contents buffer);
          loop rest
        end
        else begin
          Buffer.add_string buffer line;
          loop rest
        end
  in
  loop lines

let run () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      Eio.Switch.run (fun sw ->
          let listening =
            Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw net (`Tcp (Eio.Net.Ipaddr.V4.any, port))
          in
          let rec serve () =
            let flow, _ = Eio.Net.accept ~sw listening in
            Eio.Fiber.fork ~sw (fun () -> handle_connection flow);
            serve ()
          in
          serve ()))
