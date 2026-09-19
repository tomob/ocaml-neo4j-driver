(* Shared mock TLS server for the unit tests.

   Wraps an accepted connection in TLS (Tls_eio.server_of_flow) using the
   committed self-signed certificate (Test_fixtures), then serves the usual
   mock Bolt behavior over the encrypted channel. A failed handshake (e.g. the
   client rejecting the certificate) is swallowed on the server side, as some
   tests expect exactly that. With [require_client_cert] the server asks for a
   client certificate and only accepts the committed one (mTLS). *)

let certificate () =
  match X509.Certificate.decode_pem Test_fixtures.cert with
  | Ok cert -> cert
  | Error (`Msg msg) -> failwith ("bad cert fixture: " ^ msg)

let private_key () =
  match X509.Private_key.decode_pem Test_fixtures.key with
  | Ok key -> key
  | Error (`Msg msg) -> failwith ("bad key fixture: " ^ msg)

let server_config ?(require_client_cert = false) () =
  let cert = certificate () in
  let key = private_key () in
  Mirage_crypto_rng_unix.use_default ();
  let authenticator =
    if require_client_cert then
      Some (X509.Authenticator.chain_of_trust ~time:(fun () -> Some (Ptime_clock.now ())) [ cert ])
    else None
  in
  match Tls.Config.server ?authenticator ~certificates:(`Single ([ cert ], key)) () with
  | Ok config -> config
  | Error (`Msg msg) -> failwith ("bad TLS server config: " ^ msg)

let handler ?require_client_cert behavior clock flow =
  try
    let tls = Tls_eio.server_of_flow (server_config ?require_client_cert ()) flow in
    Test_mock.serve_behavior ~clock behavior (tls :> Test_mock.flow)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> ()

let with_mock ?require_client_cert behavior client =
  Test_mock.with_server (handler ?require_client_cert behavior) client
