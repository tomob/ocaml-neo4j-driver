(** Loading PEM private keys, including the legacy OpenSSL-encrypted format.

    [X509.Private_key.decode_pem] only reads plain PKCS#8/PKCS#1 keys, so the legacy
    [Proc-Type: 4,ENCRYPTED] PEM (with a [DEK-Info: <cipher>,<iv>] header) used by the TestKit
    fixtures is decrypted here first. *)

val decode : ?password:string -> string -> (X509.Private_key.t, string) result
(** Decode a PEM private key. [password] decrypts a legacy OpenSSL-encrypted PEM
    (AES-128/192/256-CBC or DES-EDE3-CBC); an encrypted key without a password, a wrong password or
    an unsupported cipher is an error. A plain key ignores the password. *)
