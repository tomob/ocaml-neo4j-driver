(* Kerberos authentication: the ticket from KRB_TICKET is sent as the
   "kerberos" scheme's credentials. Building the driver does not connect (the
   driver is lazy); a real connection needs a server configured for Kerberos. *)

open Neodriver

let ticket = Common.env "KRB_TICKET" ""

let () =
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run (fun sw ->
          let driver = Common.connect ~auth:(Conn.kerberos_auth ticket) net clock sw in
          Printf.printf "built a driver with the kerberos scheme (%d-byte ticket)\n"
            (String.length ticket);
          Driver.close driver))
