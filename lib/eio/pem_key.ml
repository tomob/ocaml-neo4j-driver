(* Loading PEM private keys, including the legacy OpenSSL-encrypted form.

   [X509.Private_key.decode_pem] only reads plain PKCS#8/PKCS#1 keys. A legacy
   [Proc-Type: 4,ENCRYPTED] PEM carries a [DEK-Info: <cipher>,<iv>] header and
   the body encrypted with an OpenSSL scheme that derives the key with
   EVP_BytesToKey(MD5), using the first eight IV bytes as salt, and decrypts
   with the IV from the header (AES/DES-CBC, PKCS#7 padding). The plaintext
   DER is then handed back to [X509.Private_key.decode_pem] under the original
   PEM label (PKCS#1 [RSA PRIVATE KEY] or PKCS#8 [PRIVATE KEY]). *)

let ( let* ) = Result.bind

let split_lines text =
  String.split_on_char '\n' text
  |> List.map (fun line ->
      let length = String.length line in
      if length > 0 && line.[length - 1] = '\r' then String.sub line 0 (length - 1) else line)

let contains ~substring text =
  let length = String.length text and sub = String.length substring in
  let rec go i = i + sub <= length && (String.sub text i sub = substring || go (i + 1)) in
  go 0

type pem = { label : string; headers : (string * string) list; body : string }

let begin_prefix = "-----BEGIN "
let label_start = String.length begin_prefix
let end_marker = "-----"

(* Parse one PEM block: the label, the [Header: value] lines before the blank
   line and the base64 body. Returns [None] when there is no PEM block. *)
let parse_pem text =
  let lines = split_lines text in
  let rec find_begin = function
    | [] -> None
    | line :: rest ->
        (* A delimiter is "-----BEGIN " + a label + "-----"; a shorter line is
           malformed and must not be sliced with a negative length. *)
        if
          String.starts_with ~prefix:begin_prefix line
          && String.length line >= label_start + String.length end_marker
        then
          let label =
            String.sub line label_start (String.length line - label_start - String.length end_marker)
          in
          Some (label, rest)
        else find_begin rest
  in
  match find_begin lines with
  | None -> None
  | Some (label, rest) ->
      let rec headers acc = function
        | [] -> (List.rev acc, [])
        | "" :: rest -> (List.rev acc, rest)
        | line :: rest -> (
            match String.index_opt line ':' with
            | Some i ->
                let key = String.sub line 0 i in
                let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
                headers ((key, value) :: acc) rest
            | None -> (List.rev acc, line :: rest))
      in
      let headers, rest = headers [] rest in
      let rec body acc = function
        | [] -> String.concat "" (List.rev acc)
        | line :: rest ->
            if String.starts_with ~prefix:"-----END " line then String.concat "" (List.rev acc)
            else body (line :: acc) rest
      in
      Some { label; headers; body = body [] rest }

(* [Cstruct.of_hex] parses hexadecimal and returns the bytes; it raises
   [Invalid_argument] on an invalid character or an odd number of digits, which
   is exposed here as a [result] like the rest of this module. *)
let hex_decode text =
  match Cstruct.of_hex text with
  | data -> Ok (Cstruct.to_string data)
  | exception Invalid_argument message -> Error message

(* OpenSSL's EVP_BytesToKey with MD5 and one iteration: D_i = MD5(D_{i-1} ||
   password || salt), concatenated until [key_len] bytes are available. *)
let evp_bytes_to_key ~password ~salt key_len =
  let rec go acc previous =
    if String.length acc >= key_len then String.sub acc 0 key_len
    else
      let digest = Digestif.MD5.(to_raw_string (digest_string (previous ^ password ^ salt))) in
      go (acc ^ digest) digest
  in
  go "" ""

(* PKCS#7 unpadding; leaves the data unchanged when the padding is invalid (the
   subsequent DER decode then reports the failure). *)
let unpad data =
  let length = String.length data in
  if length = 0 then data
  else
    let amount = Char.code data.[length - 1] in
    if amount = 0 || amount > length then data
    else
      let valid = ref true in
      for i = length - amount to length - 1 do
        if Char.code data.[i] <> amount then valid := false
      done;
      if !valid then String.sub data 0 (length - amount) else data

(* CBC raises on a wrong IV length or a ciphertext that is not block-aligned,
   so a malformed header/body must be rejected before decryption. *)
let check_block_size ~cipher ~block_size ~iv data =
  if String.length iv <> block_size then
    Error
      (Printf.sprintf "%s: the IV must be %d bytes, got %d" cipher block_size (String.length iv))
  else if String.length data mod block_size <> 0 then
    Error
      (Printf.sprintf "%s: the ciphertext length %d is not a multiple of the %d-byte block size"
         cipher (String.length data) block_size)
  else Ok ()

let strip_whitespace text =
  String.to_seq text
  |> Seq.filter (function ' ' | '\t' | '\n' | '\r' -> false | _ -> true)
  |> String.of_seq

let decrypt_body ~password ~dek_info body =
  match String.split_on_char ',' dek_info with
  | [ cipher; iv_hex ] -> (
      let* iv = hex_decode iv_hex in
      let* data =
        match Base64.decode (strip_whitespace body) with
        | Ok data -> Ok data
        | Error (`Msg msg) -> Error (Printf.sprintf "invalid base64 body: %s" msg)
      in
      let salt = if String.length iv >= 8 then String.sub iv 0 8 else iv in
      match cipher with
      | "AES-128-CBC" | "AES-192-CBC" | "AES-256-CBC" ->
          let key_len = match cipher with "AES-128-CBC" -> 16 | "AES-192-CBC" -> 24 | _ -> 32 in
          let* () = check_block_size ~cipher ~block_size:16 ~iv data in
          let key = Mirage_crypto.AES.CBC.of_secret (evp_bytes_to_key ~password ~salt key_len) in
          Ok (unpad (Mirage_crypto.AES.CBC.decrypt ~key ~iv data))
      | "DES-EDE3-CBC" ->
          let* () = check_block_size ~cipher ~block_size:8 ~iv data in
          let key = Mirage_crypto.DES.CBC.of_secret (evp_bytes_to_key ~password ~salt 24) in
          Ok (unpad (Mirage_crypto.DES.CBC.decrypt ~key ~iv data))
      | cipher -> Error (Printf.sprintf "unsupported encrypted PEM cipher %S" cipher))
  | _ -> Error "invalid DEK-Info header"

let decode_with label der =
  let pem =
    Printf.sprintf "-----BEGIN %s-----\n%s\n-----END %s-----\n" label (Base64.encode_string der)
      label
  in
  match X509.Private_key.decode_pem pem with Ok key -> Ok key | Error (`Msg msg) -> Error msg

let decode_plain text =
  match X509.Private_key.decode_pem text with Ok key -> Ok key | Error (`Msg msg) -> Error msg

let decode ?password text =
  match parse_pem text with
  | Some { label; headers; body }
    when match List.assoc_opt "Proc-Type" headers with
         | Some value -> contains ~substring:"ENCRYPTED" value
         | None -> false -> (
      match List.assoc_opt "DEK-Info" headers with
      | None -> Error "encrypted private key without a DEK-Info header"
      | Some dek_info -> (
          match password with
          | None -> Error "the private key is encrypted but no password was provided"
          | Some password ->
              let* der = decrypt_body ~password ~dek_info body in
              decode_with label der))
  | _ -> decode_plain text
