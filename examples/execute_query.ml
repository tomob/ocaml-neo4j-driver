(* The high-level API: Driver.execute_query runs a query in a managed, retried
   transaction and returns an eager result (keys / records / summary).
   Driver.verify_connectivity and Driver.supports_multi_db probe the server. *)

open Neodriver

let () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let driver = Common.connect ~net ~clock ~sw in
          Fun.protect
            ~finally:(fun () -> Driver.close driver)
            (fun () ->
              (match Driver.verify_connectivity driver with
              | Ok () -> ()
              | Error error -> failwith (Errors.to_string error));
              Printf.printf "supports multi-db: %b\n"
                (match Driver.supports_multi_db driver with
                | Ok supported -> supported
                | Error error -> failwith (Errors.to_string error));
              match
                Driver.execute_query driver
                  ~query:"CREATE (p:Person {name: $name}) RETURN p.name AS name"
                  ~parameters:[ ("name", Values.String "Eager Person") ]
              with
              | Error error -> failwith (Errors.to_string error)
              | Ok eager ->
                  Printf.printf "keys: %s\n" (String.concat ", " eager.keys);
                  List.iter
                    (function [ Values.String name ] -> Printf.printf "  %s\n" name | _ -> ())
                    eager.records)))
