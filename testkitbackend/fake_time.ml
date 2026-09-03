(* TestKit Backend:MockTime support (see fake_time.mli).

   The clock is an Eio resource implementing the [CLOCK] provider interface over
   Mtime, built with [Eio.Resource.T] like any Eio resource. In real mode it
   delegates to the real mono clock; once [install]ed, [now] returns the frozen
   mocked time and [sleep_until] suspends the fiber until [tick] advances the
   mock past the target. Only the harness's FakeTime commands call [install] /
   [tick] / [uninstall], and always between requests (never while a driver
   operation is in flight), so no lock is needed. *)

type mode = Real | Fake of Mtime.t

type state = {
  real : Mtime.t Eio.Time.clock_ty Eio.Resource.t;
  mutable mode : mode;
  cond : Eio.Condition.t;
}

(* A CLOCK implementation for Eio.Time.Mono over the state above. *)
module Clock_impl = struct
  type t = state
  type time = Mtime.t

  let now st = match st.mode with Real -> Eio.Time.Mono.now st.real | Fake mocked -> mocked

  let rec sleep_until st target =
    match st.mode with
    | Real -> Eio.Time.Mono.sleep_until st.real target
    | Fake mocked when Mtime.compare mocked target >= 0 -> ()
    | Fake _ ->
        (* Suspended until a FakeTimeTick broadcasts (or the fiber is
           cancelled, e.g. by a competing Eio.Time.Timeout branch). *)
        Eio.Condition.await_no_mutex st.cond;
        sleep_until st target
end

let create real =
  let st = { real; mode = Real; cond = Eio.Condition.create () } in
  let handler = Eio.Time.Pi.clock (module Clock_impl) in
  let clock = (Eio.Resource.T (st, handler) :> Mtime.t Eio.Time.clock_ty Eio.Resource.t) in
  (st, clock)

let install st =
  if st.mode <> Real then invalid_arg "Fake_time.install: already installed";
  st.mode <- Fake (Eio.Time.Mono.now st.real)

let tick st milliseconds =
  match st.mode with
  | Real -> invalid_arg "Fake_time.tick: no time mocker installed"
  | Fake mocked ->
      let span = Mtime.Span.of_uint64_ns (Int64.mul (Int64.of_int milliseconds) 1_000_000L) in
      st.mode <- Fake (Option.get (Mtime.add_span mocked span));
      Eio.Condition.broadcast st.cond

let uninstall st =
  match st.mode with
  | Real -> invalid_arg "Fake_time.uninstall: no time mocker installed"
  | Fake _ ->
      st.mode <- Real;
      Eio.Condition.broadcast st.cond
