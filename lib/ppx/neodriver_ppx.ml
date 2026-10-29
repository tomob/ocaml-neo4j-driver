(* Deriver registration. *)

open Ppxlib

let () =
  Deriving.add "neo4j"
    ~str_type_decl:
      (Deriving.Generator.make_noarg (fun ~loc:_ ~path:_ (rec_flag, declarations) ->
           Gen_decode.generate ~rec_flag declarations))
  |> ignore

let () =
  Deriving.add "neo4j_params"
    ~str_type_decl:
      (Deriving.Generator.make_noarg (fun ~loc:_ ~path:_ (rec_flag, declarations) ->
           Gen_params.generate ~rec_flag declarations))
  |> ignore
