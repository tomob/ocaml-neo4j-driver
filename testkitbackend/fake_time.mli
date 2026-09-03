(* TestKit Backend:MockTime support: a mono clock whose current time is frozen
   by FakeTimeInstall and only advances on FakeTimeTick, until FakeTimeUninstall
   restores the real clock. All drivers of a backend connection share the same
   [state], so every time-dependent driver decision (auth-token expiry, pool
   connection age/liveness, retries) sees the mocked time. *)

type state

val create :
  Mtime.t Eio.Time.clock_ty Eio.Resource.t -> state * Mtime.t Eio.Time.clock_ty Eio.Resource.t
(** [create real] is ([state], [clock]) where [clock] reads the real mono clock until an install and
    the frozen mocked time afterwards (ticks advance it). The real clock keeps being used for actual
    sleeping in real mode. *)

val install : state -> unit
(** Freeze the clock at the current real time (idempotent; must not already be installed). *)

val tick : state -> int -> unit
(** Advance the mocked time by the given number of milliseconds (only between an install and an
    uninstall) and wake fibers waiting on the clock. *)

val uninstall : state -> unit
(** Restore the real clock (idempotent; must currently be installed). *)
