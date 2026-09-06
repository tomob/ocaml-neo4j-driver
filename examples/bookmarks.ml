(* Bookmarks and causal consistency.

   A bookmark is an opaque token representing the state of the database after a
   transaction commits. In a Neo4j cluster writes are replicated asynchronously,
   so a transaction routed to one server may not be visible to a later
   transaction routed to another. Sending the bookmark of the earlier
   transaction with the later one asks the cluster to deliver it to a server
   that has already seen that state — causal chaining, or "read-your-writes".

   This program shows the three ways bookmarks are used with the driver:
   - automatically within one session (a write followed by a read in the same
     session is always causally chained),
   - manually across sessions (the writer's [Session.last_bookmarks] seed the
     reader session's config),
   - with a shared [Bookmark_manager] (every session sharing it is chained
     without passing bookmarks around by hand). *)

open Neodriver

let with_session driver f =
  let session = Driver.session driver in
  Fun.protect ~finally:(fun () -> Session.close session) (fun () -> f session)

let with_session_with_bookmarks driver bookmarks f =
  let session = Driver.session ~config:{ Session.default_config with bookmarks } driver in
  Fun.protect ~finally:(fun () -> Session.close session) (fun () -> f session)

(* A session sharing [manager]: its transactions are seeded with the manager's
   bookmarks and its commits update them. *)
let with_managed_session driver manager f =
  let session =
    Driver.session ~config:{ Session.default_config with bookmark_manager = Some manager } driver
  in
  Fun.protect ~finally:(fun () -> Session.close session) (fun () -> f session)

(* Run a query and consume the whole result. For auto-commit writes the
   session records the returned bookmark once the result is consumed. *)
let run session ~query ~parameters =
  match Session.run session ~query ~parameters with
  | Ok result -> (
      match Neo4jResult.consume result with
      | Ok _ -> ()
      | Error error -> failwith (Errors.to_string error))
  | Error error -> failwith (Errors.to_string error)

let create_person session name =
  run session ~query:"CREATE (p:Person {name: $name})" ~parameters:[ ("name", Values.String name) ]

let delete_person session name =
  run session ~query:"MATCH (p:Person {name: $name}) DELETE p"
    ~parameters:[ ("name", Values.String name) ]

(* The number of [Person] nodes with [name]. *)
let count_people session name =
  match
    Session.run session ~query:"MATCH (p:Person {name: $name}) RETURN count(p) AS n"
      ~parameters:[ ("name", Values.String name) ]
  with
  | Ok result -> (
      match Neo4jResult.values result with
      | Ok [ [ Values.Int n ] ] -> Int64.to_int n
      | _ -> failwith "expected a single count")
  | Error error -> failwith (Errors.to_string error)

let bookmark_string bookmarks = String.concat "," (Bookmarks.to_list bookmarks)

let () =
  Random.self_init ();
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let driver = Common.connect ~net ~clock ~sw in
          Fun.protect
            ~finally:(fun () -> Driver.close driver)
            (fun () ->
              let name = Printf.sprintf "Bookmarks demo %d" (Random.int 1_000_000) in
              Printf.printf "--- within one session (automatic) ---\n";
              with_session driver (fun session ->
                  create_person session name;
                  Printf.printf "created '%s' (session bookmark: %s)\n" name
                    (bookmark_string (Session.last_bookmarks session));
                  Printf.printf "read-your-writes in the same session: count = %d\n"
                    (count_people session name));
              Printf.printf "--- manual chaining across sessions ---\n";
              let writer_bookmarks = ref Bookmarks.empty in
              with_session driver (fun writer ->
                  create_person writer name;
                  writer_bookmarks := Session.last_bookmarks writer);
              Printf.printf "writer recorded: %s\n" (bookmark_string !writer_bookmarks);
              with_session_with_bookmarks driver !writer_bookmarks (fun reader ->
                  Printf.printf "seeded reader count: %d\n" (count_people reader name));
              Printf.printf "--- shared bookmark manager ---\n";
              let manager = Bookmark_manager.neo4j_bookmark_manager () in
              with_managed_session driver manager (fun writer ->
                  create_person writer name;
                  Printf.printf "after the commit the manager holds: %s\n"
                    (bookmark_string (manager.get_bookmarks ())));
              with_managed_session driver manager (fun reader ->
                  Printf.printf "manager-chained reader count: %d\n" (count_people reader name));
              Printf.printf "--- cleaning up the demo nodes ---\n";
              with_managed_session driver manager (fun session -> delete_person session name))))
