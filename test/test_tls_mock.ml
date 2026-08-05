(* Shared mock TLS server for the unit tests.

   Wraps an accepted connection in TLS (Tls_eio.server_of_flow) using the
   committed self-signed certificate (Test_fixtures), then serves the usual
   mock Bolt behavior over the encrypted channel. A failed handshake (e.g. the
   client rejecting the certificate) is swallowed on the server side, as some
   tests expect exactly that. *)

let server_config () =
  let cert =
    match X509.Certificate.decode_pem Test_fixtures.cert with
    | Ok cert -> cert
    | Error (`Msg msg) -> failwith ("bad cert fixture: " ^ msg)
  in
  let key =
    match X509.Private_key.decode_pem Test_fixtures.key with
    | Ok key -> key
    | Error (`Msg msg) -> failwith ("bad key fixture: " ^ msg)
  in
  Mirage_crypto_rng_unix.use_default ();
  match Tls.Config.server ~certificates:(`Single ([ cert ], key)) () with
  | Ok config -> config
  | Error (`Msg msg) -> failwith ("bad TLS server config: " ^ msg)

let handler behavior flow =
  try
    let tls = Tls_eio.server_of_flow (server_config ()) flow in
    Test_mock.serve_behavior behavior (tls :> Test_mock.flow)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> ()

let with_mock behavior client = Test_mock.with_server (handler behavior) client
