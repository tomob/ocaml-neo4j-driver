(* Unit tests for PEM private key loading, including the legacy OpenSSL
   encrypted form (phase A10/T4). *)

open Neodriver_eio
open Alcotest

let fixture_key () =
  match X509.Private_key.decode_pem Test_fixtures.key with
  | Ok key -> key
  | Error (`Msg msg) -> fail ("bad key fixture: " ^ msg)

let same_key a b =
  String.equal
    (X509.Private_key.public a |> X509.Public_key.fingerprint)
    (X509.Private_key.public b |> X509.Public_key.fingerprint)

(* OpenSSL's EVP_BytesToKey(MD5, one iteration) as used by the legacy PEM
   encryption; replicated here so the round-trip exercises the parser, the KDF,
   AES-CBC and the PKCS#7 unpadding. *)
let evp_bytes_to_key ~password ~salt key_len =
  let rec go acc previous =
    if String.length acc >= key_len then String.sub acc 0 key_len
    else
      let digest = Digestif.MD5.(to_raw_string (digest_string (previous ^ password ^ salt))) in
      go (acc ^ digest) digest
  in
  go "" ""

let pkcs7_pad block data =
  let pad = block - (String.length data mod block) in
  data ^ String.make pad (Char.chr pad)

let hex_encode text =
  String.to_seq text
  |> Seq.map (fun c -> Printf.sprintf "%02x" (Char.code c))
  |> List.of_seq |> String.concat ""

let legacy_encrypt ~password ~label der =
  Mirage_crypto_rng_unix.use_default ();
  let iv_string = Mirage_crypto_rng.generate 16 in
  let salt = String.sub iv_string 0 8 in
  let key = Mirage_crypto.AES.CBC.of_secret (evp_bytes_to_key ~password ~salt 32) in
  let encrypted = Mirage_crypto.AES.CBC.encrypt ~key ~iv:iv_string (pkcs7_pad 16 der) in
  Printf.sprintf
    "-----BEGIN %s-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,%s\n\n%s\n-----END %s-----\n"
    label (hex_encode iv_string) (Base64.encode_string encrypted) label

let plain_key () =
  match Pem_key.decode Test_fixtures.key with
  | Ok key -> check bool "plain key decodes" true (same_key key (fixture_key ()))
  | Error message -> fail message

let round_trip () =
  let der = X509.Private_key.encode_der (fixture_key ()) in
  let pem = legacy_encrypt ~password:"secret" ~label:"PRIVATE KEY" der in
  match Pem_key.decode ~password:"secret" pem with
  | Ok key -> check bool "decrypted key matches" true (same_key key (fixture_key ()))
  | Error message -> fail message

let wrong_password () =
  let der = X509.Private_key.encode_der (fixture_key ()) in
  let pem = legacy_encrypt ~password:"secret" ~label:"PRIVATE KEY" der in
  match Pem_key.decode ~password:"nope" pem with
  | Ok _ -> fail "a wrong password should not decode the key"
  | Error _ -> ()

let missing_password () =
  let der = X509.Private_key.encode_der (fixture_key ()) in
  let pem = legacy_encrypt ~password:"secret" ~label:"PRIVATE KEY" der in
  match Pem_key.decode pem with
  | Ok _ -> fail "an encrypted key without a password should not decode"
  | Error _ -> ()

(* The committed fixtures live next to the test executable in the build tree
   (a dune dependency); also look there when the test binary is run directly
   rather than through dune, which uses the test directory as the CWD. *)
let fixture_path name =
  let candidates =
    [
      Filename.concat "fixtures" name;
      Filename.concat (Filename.dirname Sys.executable_name) (Filename.concat "fixtures" name);
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
      failwith
        (Printf.sprintf "fixture %s not found (looked in %s)" name (String.concat ", " candidates))

(* Validate against a committed OpenSSL-generated fixture: an encrypted RSA
   private key and the certificate it belongs to (the TestKit TLS client
   certificate set, kept here so the unit tests need no external checkout). *)
let openssl_fixture () =
  let read name = In_channel.with_open_bin (fixture_path name) In_channel.input_all in
  let key_pem = read "privatekey1_with_thepassword1.pem" in
  let cert_pem = read "certificate1.pem" in
  match Pem_key.decode ~password:"thepassword1" key_pem with
  | Error message -> fail message
  | Ok key -> (
      match X509.Certificate.decode_pem cert_pem with
      | Error (`Msg msg) -> fail msg
      | Ok certificate ->
          let expected = X509.Certificate.public_key certificate in
          let actual = X509.Private_key.public key in
          check bool "decrypted key matches the certificate" true
            (String.equal
               (X509.Public_key.fingerprint expected)
               (X509.Public_key.fingerprint actual)))

let legacy_pem ~cipher ~iv_hex ~body =
  Printf.sprintf
    "-----BEGIN PRIVATE KEY-----\n\
     Proc-Type: 4,ENCRYPTED\n\
     DEK-Info: %s,%s\n\n\
     %s\n\
     -----END PRIVATE KEY-----\n"
    cipher iv_hex body

(* A malformed delimiter must be reported as an error, not crash with a
   negative-length String.sub. *)
let malformed_begin () =
  match Pem_key.decode ~password:"secret" "-----BEGIN \n" with
  | Ok _ -> fail "a truncated BEGIN line should not decode"
  | Error _ -> ()

let malformed_begin_short_label () =
  match Pem_key.decode ~password:"secret" "-----BEGIN X\n" with
  | Ok _ -> fail "a truncated BEGIN line should not decode"
  | Error _ -> ()

(* A malformed IV or a ciphertext that is not block-aligned must be reported as
   an error, not crash inside the CBC implementation. *)
let malformed_iv () =
  let pem =
    legacy_pem ~cipher:"AES-256-CBC" ~iv_hex:"0011"
      ~body:(Base64.encode_string (String.make 16 'x'))
  in
  match Pem_key.decode ~password:"secret" pem with
  | Ok _ -> fail "a short IV should not decode"
  | Error _ -> ()

let malformed_ciphertext () =
  let pem =
    legacy_pem ~cipher:"AES-256-CBC"
      ~iv_hex:(hex_encode (String.make 16 'x'))
      ~body:(Base64.encode_string (String.make 15 'x'))
  in
  match Pem_key.decode ~password:"secret" pem with
  | Ok _ -> fail "an unaligned ciphertext should not decode"
  | Error _ -> ()

let malformed_des_iv () =
  let pem =
    legacy_pem ~cipher:"DES-EDE3-CBC" ~iv_hex:"0011"
      ~body:(Base64.encode_string (String.make 8 'x'))
  in
  match Pem_key.decode ~password:"secret" pem with
  | Ok _ -> fail "a short DES IV should not decode"
  | Error _ -> ()

let tests =
  [
    ("[Pem_key] plain", [ test_case "plain key decodes" `Quick plain_key ]);
    ("[Pem_key] encrypted", [ test_case "encrypted key round trip" `Quick round_trip ]);
    ("[Pem_key] wrong password", [ test_case "wrong password fails" `Quick wrong_password ]);
    ("[Pem_key] missing password", [ test_case "missing password fails" `Quick missing_password ]);
    ("[Pem_key] openssl fixture", [ test_case "encrypted RSA key" `Quick openssl_fixture ]);
    ("[Pem_key] malformed begin", [ test_case "short BEGIN line" `Quick malformed_begin ]);
    ( "[Pem_key] malformed begin label",
      [ test_case "truncated label" `Quick malformed_begin_short_label ] );
    ("[Pem_key] malformed iv", [ test_case "short AES IV" `Quick malformed_iv ]);
    ( "[Pem_key] malformed ciphertext",
      [ test_case "unaligned ciphertext" `Quick malformed_ciphertext ] );
    ("[Pem_key] malformed des iv", [ test_case "short DES IV" `Quick malformed_des_iv ]);
  ]
