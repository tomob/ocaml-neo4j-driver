(* Backend protocol exceptions shared by the handlers and the value encoder. *)

open Neodriver

exception Backend_error of string
exception Driver_error of Errors.t
