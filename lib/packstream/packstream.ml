(* PackStream — binary serialization for the Neo4j Bolt protocol.

   Ported from the PackStream codec of jeong-sik/ocaml-neo4j-bolt
   (https://github.com/jeong-sik/ocaml-neo4j-bolt, MIT License).

   Differences introduced in this port:
   - [unpack] returns a [(value, error) result] instead of raising [Failure]
     on malformed input.
   - A [max_depth] limit (default 256) guards against stack overflow on
     deeply nested values; exceeding it yields [Depth_limit_exceeded].
   - Lists, maps and structures are built incrementally rather than
     pre-allocated with [List.init], so a bogus container length fails with
     [Unexpected_end_of_data] instead of allocating a huge list.
   - 16-bit and 32-bit container/sequence lengths are read as unsigned,
     fixing a crash (negative length) on values >= 2^15 / 2^31.
   - A dedicated [error] type with [error_to_string] describes decode
     failures; [pack] remains total.
   - An interface file (.mli) exposes only the public API.
   - The value pretty-printer is exposed as [to_string].
*)

(* Marker bytes — see the PackStream specification. *)
let marker_tiny_string = 0x80
let marker_tiny_list = 0x90
let marker_tiny_map = 0xA0
let marker_tiny_struct = 0xB0
let marker_null = 0xC0
let marker_float_64 = 0xC1
let marker_false = 0xC2
let marker_true = 0xC3
let marker_int_8 = 0xC8
let marker_int_16 = 0xC9
let marker_int_32 = 0xCA
let marker_int_64 = 0xCB
let marker_bytes_8 = 0xCC
let marker_bytes_16 = 0xCD
let marker_bytes_32 = 0xCE
let marker_string_8 = 0xD0
let marker_string_16 = 0xD1
let marker_string_32 = 0xD2
let marker_list_8 = 0xD4
let marker_list_16 = 0xD5
let marker_list_32 = 0xD6
let marker_map_8 = 0xD8
let marker_map_16 = 0xD9
let marker_map_32 = 0xDA
let marker_struct_8 = 0xDC
let marker_struct_16 = 0xDD

type value =
  | Null
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Bytes of bytes
  | List of value list
  | Map of (string * value) list
  | Structure of int * value list

type error =
  | Unexpected_end_of_data
  | Unknown_marker of int
  | Map_key_not_string
  | Depth_limit_exceeded of int

type limits = { max_depth : int }

let default_limits = { max_depth = 256 }

exception Unpack_error of error

let error_to_string = function
  | Unexpected_end_of_data -> "Unexpected end of data"
  | Unknown_marker marker -> Printf.sprintf "Unknown PackStream marker 0x%02X" marker
  | Map_key_not_string -> "Map key must be a string"
  | Depth_limit_exceeded depth ->
      Printf.sprintf "PackStream nesting depth exceeds the limit %d" depth

(* Interpret a signed 32-bit word as an unsigned length. *)
let uint32_to_int n = Int64.to_int (Int64.logand (Int64.of_int32 n) 0xFFFFFFFFL)

(* --- Packing --- *)

type packer = { mutable data : bytes; mutable pos : int }

let create_packer ?(initial_size = 256) () = { data = Bytes.create initial_size; pos = 0 }

let ensure_capacity p n =
  let required = p.pos + n in
  if required > Bytes.length p.data then begin
    let new_size = max required (Bytes.length p.data * 2) in
    let new_data = Bytes.create new_size in
    Bytes.blit p.data 0 new_data 0 p.pos;
    p.data <- new_data
  end

let write_byte p b =
  ensure_capacity p 1;
  Bytes.set_uint8 p.data p.pos b;
  p.pos <- p.pos + 1

let write_int16_be p n =
  ensure_capacity p 2;
  Bytes.set_int16_be p.data p.pos n;
  p.pos <- p.pos + 2

let write_int32_be p n =
  ensure_capacity p 4;
  Bytes.set_int32_be p.data p.pos n;
  p.pos <- p.pos + 4

let write_int64_be p n =
  ensure_capacity p 8;
  Bytes.set_int64_be p.data p.pos n;
  p.pos <- p.pos + 8

let write_bytes p b =
  let len = Bytes.length b in
  ensure_capacity p len;
  Bytes.blit b 0 p.data p.pos len;
  p.pos <- p.pos + len

let write_string_raw p s =
  let len = String.length s in
  ensure_capacity p len;
  Bytes.blit_string s 0 p.data p.pos len;
  p.pos <- p.pos + len

let get_bytes p = Bytes.sub p.data 0 p.pos

let rec pack_value p = function
  | Null -> write_byte p marker_null
  | Bool false -> write_byte p marker_false
  | Bool true -> write_byte p marker_true
  | Int n ->
      if n >= -16L && n < 128L then write_byte p (Int64.to_int n land 0xFF)
      else if n >= -128L && n < 128L then begin
        write_byte p marker_int_8;
        write_byte p (Int64.to_int n land 0xFF)
      end
      else if n >= -32768L && n < 32768L then begin
        write_byte p marker_int_16;
        write_int16_be p (Int64.to_int n)
      end
      else if n >= -2147483648L && n < 2147483648L then begin
        write_byte p marker_int_32;
        write_int32_be p (Int64.to_int32 n)
      end
      else begin
        write_byte p marker_int_64;
        write_int64_be p n
      end
  | Float f ->
      write_byte p marker_float_64;
      write_int64_be p (Int64.bits_of_float f)
  | String s ->
      let len = String.length s in
      if len < 16 then write_byte p (marker_tiny_string lor len)
      else if len < 256 then begin
        write_byte p marker_string_8;
        write_byte p len
      end
      else if len < 65536 then begin
        write_byte p marker_string_16;
        write_int16_be p len
      end
      else begin
        write_byte p marker_string_32;
        write_int32_be p (Int32.of_int len)
      end;
      write_string_raw p s
  | Bytes b ->
      let len = Bytes.length b in
      if len < 256 then begin
        write_byte p marker_bytes_8;
        write_byte p len
      end
      else if len < 65536 then begin
        write_byte p marker_bytes_16;
        write_int16_be p len
      end
      else begin
        write_byte p marker_bytes_32;
        write_int32_be p (Int32.of_int len)
      end;
      write_bytes p b
  | List items ->
      let len = List.length items in
      if len < 16 then write_byte p (marker_tiny_list lor len)
      else if len < 256 then begin
        write_byte p marker_list_8;
        write_byte p len
      end
      else if len < 65536 then begin
        write_byte p marker_list_16;
        write_int16_be p len
      end
      else begin
        write_byte p marker_list_32;
        write_int32_be p (Int32.of_int len)
      end;
      List.iter (pack_value p) items
  | Map entries ->
      let len = List.length entries in
      if len < 16 then write_byte p (marker_tiny_map lor len)
      else if len < 256 then begin
        write_byte p marker_map_8;
        write_byte p len
      end
      else if len < 65536 then begin
        write_byte p marker_map_16;
        write_int16_be p len
      end
      else begin
        write_byte p marker_map_32;
        write_int32_be p (Int32.of_int len)
      end;
      List.iter
        (fun (key, item) ->
          pack_value p (String key);
          pack_value p item)
        entries
  | Structure (tag, fields) ->
      let len = List.length fields in
      if len < 16 then begin
        write_byte p (marker_tiny_struct lor len);
        write_byte p tag
      end
      else if len < 256 then begin
        write_byte p marker_struct_8;
        write_byte p len;
        write_byte p tag
      end
      else begin
        write_byte p marker_struct_16;
        write_int16_be p len;
        write_byte p tag
      end;
      List.iter (pack_value p) fields

let pack value =
  let p = create_packer () in
  pack_value p value;
  get_bytes p

(* --- Unpacking --- *)

type unpacker = { data : bytes; mutable rpos : int; len : int }

let create_unpacker data = { data; rpos = 0; len = Bytes.length data }
let remaining u = u.len - u.rpos

let read_byte u =
  if remaining u < 1 then raise (Unpack_error Unexpected_end_of_data);
  let b = Bytes.get_uint8 u.data u.rpos in
  u.rpos <- u.rpos + 1;
  b

let read_int16_be u =
  if remaining u < 2 then raise (Unpack_error Unexpected_end_of_data);
  let n = Bytes.get_int16_be u.data u.rpos in
  u.rpos <- u.rpos + 2;
  n

let read_int32_be u =
  if remaining u < 4 then raise (Unpack_error Unexpected_end_of_data);
  let n = Bytes.get_int32_be u.data u.rpos in
  u.rpos <- u.rpos + 4;
  n

let read_int64_be u =
  if remaining u < 8 then raise (Unpack_error Unexpected_end_of_data);
  let n = Bytes.get_int64_be u.data u.rpos in
  u.rpos <- u.rpos + 8;
  n

let read_bytes u len =
  if remaining u < len then raise (Unpack_error Unexpected_end_of_data);
  let b = Bytes.sub u.data u.rpos len in
  u.rpos <- u.rpos + len;
  b

let read_string_raw u len =
  if remaining u < len then raise (Unpack_error Unexpected_end_of_data);
  let s = Bytes.sub_string u.data u.rpos len in
  u.rpos <- u.rpos + len;
  s

let check_depth limits depth =
  if depth >= limits.max_depth then raise (Unpack_error (Depth_limit_exceeded limits.max_depth))

let rec unpack_value limits depth u =
  let marker = read_byte u in
  let high = marker land 0xF0 in
  let low = marker land 0x0F in
  match marker with
  | m when m = marker_null -> Null
  | m when m = marker_false -> Bool false
  | m when m = marker_true -> Bool true
  | m when m = marker_float_64 -> Float (Int64.float_of_bits (read_int64_be u))
  | m when m = marker_int_8 ->
      let n = read_byte u in
      Int (Int64.of_int (if n >= 128 then n - 256 else n))
  | m when m = marker_int_16 -> Int (Int64.of_int (read_int16_be u))
  | m when m = marker_int_32 -> Int (Int64.of_int32 (read_int32_be u))
  | m when m = marker_int_64 -> Int (read_int64_be u)
  | m when m = marker_bytes_8 -> Bytes (read_bytes u (read_byte u))
  | m when m = marker_bytes_16 -> Bytes (read_bytes u (read_int16_be u land 0xFFFF))
  | m when m = marker_bytes_32 -> Bytes (read_bytes u (uint32_to_int (read_int32_be u)))
  | m when m = marker_string_8 -> String (read_string_raw u (read_byte u))
  | m when m = marker_string_16 -> String (read_string_raw u (read_int16_be u land 0xFFFF))
  | m when m = marker_string_32 -> String (read_string_raw u (uint32_to_int (read_int32_be u)))
  | m when m = marker_list_8 -> List (unpack_list limits depth u (read_byte u))
  | m when m = marker_list_16 -> List (unpack_list limits depth u (read_int16_be u land 0xFFFF))
  | m when m = marker_list_32 -> List (unpack_list limits depth u (uint32_to_int (read_int32_be u)))
  | m when m = marker_map_8 -> Map (unpack_map limits depth u (read_byte u))
  | m when m = marker_map_16 -> Map (unpack_map limits depth u (read_int16_be u land 0xFFFF))
  | m when m = marker_map_32 -> Map (unpack_map limits depth u (uint32_to_int (read_int32_be u)))
  | m when m = marker_struct_8 ->
      let tag = read_byte u in
      Structure (tag, unpack_fields limits depth u (read_byte u))
  | m when m = marker_struct_16 ->
      let tag = read_byte u in
      Structure (tag, unpack_fields limits depth u (read_int16_be u land 0xFFFF))
  | _ when high = marker_tiny_string -> String (read_string_raw u low)
  | _ when high = marker_tiny_list -> List (unpack_list limits depth u low)
  | _ when high = marker_tiny_map -> Map (unpack_map limits depth u low)
  | _ when high = marker_tiny_struct ->
      let tag = read_byte u in
      Structure (tag, unpack_fields limits depth u low)
  | m when m <= 0x7F -> Int (Int64.of_int m)
  | m when m >= 0xF0 -> Int (Int64.of_int (m - 256))
  | m -> raise (Unpack_error (Unknown_marker m))

and unpack_list limits depth u len =
  check_depth limits depth;
  let rec go acc n =
    if n = 0 then List.rev acc else go (unpack_value limits (depth + 1) u :: acc) (n - 1)
  in
  go [] len

and unpack_fields limits depth u len = unpack_list limits depth u len

and unpack_map limits depth u len =
  check_depth limits depth;
  let rec go acc n =
    if n = 0 then List.rev acc
    else
      let key = unpack_value limits (depth + 1) u in
      let item = unpack_value limits (depth + 1) u in
      match key with
      | String k -> go ((k, item) :: acc) (n - 1)
      | _ -> raise (Unpack_error Map_key_not_string)
  in
  go [] len

let unpack ?(limits = default_limits) data =
  try Ok (unpack_value limits 0 (create_unpacker data)) with Unpack_error e -> Error e

(* --- Pretty printing --- *)

let rec to_string = function
  | Null -> "null"
  | Bool b -> string_of_bool b
  | Int n -> Int64.to_string n
  | Float f -> string_of_float f
  | String s -> Printf.sprintf "%S" s
  | Bytes b -> Printf.sprintf "<bytes:%d>" (Bytes.length b)
  | List items -> "[" ^ String.concat ", " (List.map to_string items) ^ "]"
  | Map entries ->
      "{"
      ^ String.concat ", "
          (List.map (fun (k, v) -> Printf.sprintf "%S: %s" k (to_string v)) entries)
      ^ "}"
  | Structure (tag, fields) ->
      Printf.sprintf "Struct(%d, [%s])" tag (String.concat ", " (List.map to_string fields))
