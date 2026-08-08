(* Shared helpers for the example programs: environment configuration, an
   [Eio_main] wrapper that connects a session, and a minimal CSV reader. *)

open Neodriver

let env key default =
  match Sys.getenv_opt key with Some value when value <> "" -> value | _ -> default

let uri = env "NEO4J_URI" "bolt://localhost:7687"
let user = env "NEO4J_USER" "neo4j"
let password = env "NEO4J_PASSWORD" ""

let connect ~net ~clock ~sw =
  match
    Driver.connect ~uri
      ~auth:(Conn.basic_auth ~principal:user ~credentials:password ())
      net clock sw
  with
  | Ok session -> session
  | Error error -> failwith (Errors.to_string error)

(* Run [f] on a session, closing the session afterwards. *)
let with_session f =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let session = connect ~net ~clock ~sw in
          Fun.protect ~finally:(fun () -> Session.close session) (fun () -> f session)))

(* A hydration scope for the session's connection. *)
let hydration session =
  match Session.conn session with
  | Ok conn -> Conn.hydration conn
  | Error error -> failwith (Errors.to_string error)

(* A minimal CSV reader: fields separated by commas, double-quoted fields with
   [""] as an escaped quote. Returns all rows, including the header. *)
let read_csv path =
  let split_line line =
    let fields = ref [] in
    let buf = Buffer.create 16 in
    let in_quotes = ref false in
    let i = ref 0 in
    let n = String.length line in
    while !i < n do
      let c = line.[!i] in
      if !in_quotes then
        if c = '"' then
          if !i + 1 < n && line.[!i + 1] = '"' then begin
            Buffer.add_char buf '"';
            incr i
          end
          else in_quotes := false
        else Buffer.add_char buf c
      else if c = '"' then in_quotes := true
      else if c = ',' then begin
        fields := Buffer.contents buf :: !fields;
        Buffer.clear buf
      end
      else Buffer.add_char buf c;
      incr i
    done;
    fields := Buffer.contents buf :: !fields;
    List.rev !fields
  in
  let ic = open_in path in
  let lines = ref [] in
  (try
     while true do
       let line = input_line ic in
       if line <> "" then lines := split_line line :: !lines
     done
   with End_of_file -> close_in ic);
  List.rev !lines
