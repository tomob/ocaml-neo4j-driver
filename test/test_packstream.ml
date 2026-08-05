open Neodriver
open Packstream
open Alcotest

let pp_value ppf v = Format.fprintf ppf "%s" (Packstream.to_string v)
let value = testable pp_value ( = )

let round_trip v =
  match Packstream.unpack (Packstream.pack v) with
  | Ok decoded -> check value "round trip" v decoded
  | Error e -> fail (Packstream.error_to_string e)

let round_trip () =
  List.iter round_trip
    [
      Null;
      Bool true;
      Bool false;
      Int (-1L);
      Int 0L;
      Int 1L;
      Int 127L;
      Int 128L;
      Int (-128L);
      Int (-129L);
      Int 32767L;
      Int 32768L;
      Int (-32768L);
      Int (-32769L);
      Int 2147483647L;
      Int 2147483648L;
      Int (-2147483648L);
      Int (-2147483649L);
      Int Int64.max_int;
      Int Int64.min_int;
      Float 0.0;
      Float (-1.5);
      Float 3.14159;
      String "";
      String "A";
      String (String.make 15 'a');
      String (String.make 16 'b');
      String (String.make 255 'c');
      String (String.make 256 'd');
      String (String.make 65535 'e');
      String (String.make 65536 'f');
      Bytes (Bytes.of_string "xy");
      Bytes (Bytes.create 0);
      List [];
      List [ Null; Int 1L; String "two" ];
      Map [];
      Map [ ("a", Int 1L); ("b", String "bee") ];
      Structure (0x4E, [ String "node"; Int 42L ]);
      Structure (0x58, [ Float 1.0; Float 2.0; Float 3.0 ]);
      List (List.init 256 (fun i -> Int (Int64.of_int i)));
      List (List.init 20 (fun i -> List [ Int (Int64.of_int i) ]));
    ]

let byte_vector () =
  check string "null" "\xc0" (Bytes.to_string (Packstream.pack Null));
  check string "int 1" "\x01" (Bytes.to_string (Packstream.pack (Int 1L)));
  check string "int -1" "\xff" (Bytes.to_string (Packstream.pack (Int (-1L))));
  check string "true" "\xc3" (Bytes.to_string (Packstream.pack (Bool true)));
  check string "false" "\xc2" (Bytes.to_string (Packstream.pack (Bool false)));
  check string "empty string" "\x80"
    (Bytes.to_string (Packstream.pack (String "")));
  check string "string A" "\x81A"
    (Bytes.to_string (Packstream.pack (String "A")));
  check string "empty list" "\x90" (Bytes.to_string (Packstream.pack (List [])));
  check string "empty map" "\xa0" (Bytes.to_string (Packstream.pack (Map [])));
  check string "struct" "\xb1N\xc0"
    (Bytes.to_string (Packstream.pack (Structure (0x4E, [ Null ]))))

let truncated () =
  (match Packstream.unpack (Bytes.of_string "\xc1") with
  | Ok _ -> fail "truncated float should fail"
  | Error e ->
      check string "truncated float" "Unexpected end of data"
        (Packstream.error_to_string e));
  match Packstream.unpack (Bytes.of_string "\x91") with
  | Ok _ -> fail "truncated list should fail"
  | Error e ->
      check string "truncated list" "Unexpected end of data"
        (Packstream.error_to_string e)

let unknown_marker () =
  match Packstream.unpack (Bytes.of_string "\xc4") with
  | Ok _ -> fail "unknown marker should fail"
  | Error e ->
      check string "unknown marker" "Unknown PackStream marker 0xC4"
        (Packstream.error_to_string e)

let map_key_not_string () =
  match Packstream.unpack (Bytes.of_string "\xa1\x01\xc0") with
  | Ok _ -> fail "non-string map key should fail"
  | Error e ->
      check string "map key" "Map key must be a string"
        (Packstream.error_to_string e)

let depth_limit () =
  let nested = List [ List [ List [ Null ] ] ] in
  (match
     Packstream.unpack ~limits:{ max_depth = 2 } (Packstream.pack nested)
   with
  | Ok _ -> fail "depth 3 with max_depth 2 should fail"
  | Error e ->
      check string "depth" "PackStream nesting depth exceeds the limit 2"
        (Packstream.error_to_string e));
  match
    Packstream.unpack ~limits:{ max_depth = 3 } (Packstream.pack nested)
  with
  | Ok _ -> ()
  | Error e -> fail (Packstream.error_to_string e)

let bogus_length () =
  (* STRING_16 header claiming 0xFFFF bytes with no data following. *)
  (match Packstream.unpack (Bytes.of_string "\xd1\xff\xff") with
  | Ok _ -> fail "oversized string should fail"
  | Error e ->
      check string "oversized string" "Unexpected end of data"
        (Packstream.error_to_string e));
  (* LIST_32 header claiming 0xFFFFFFFF elements with no data following. *)
  match Packstream.unpack (Bytes.of_string "\xd6\xff\xff\xff\xff") with
  | Ok _ -> fail "oversized list should fail"
  | Error e ->
      check string "oversized list" "Unexpected end of data"
        (Packstream.error_to_string e)

let tests =
  [
    ( "[Packstream] round_trip",
      [ test_case "all value types" `Quick round_trip ] );
    ( "[Packstream] byte_vector",
      [ test_case "known encodings" `Quick byte_vector ] );
    ("[Packstream] truncated", [ test_case "truncated data" `Quick truncated ]);
    ( "[Packstream] unknown_marker",
      [ test_case "unknown marker" `Quick unknown_marker ] );
    ( "[Packstream] map_key_not_string",
      [ test_case "map key" `Quick map_key_not_string ] );
    ("[Packstream] depth_limit", [ test_case "depth limit" `Quick depth_limit ]);
    ( "[Packstream] bogus_length",
      [ test_case "bogus lengths" `Quick bogus_length ] );
  ]
