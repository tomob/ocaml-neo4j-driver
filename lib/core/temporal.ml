(* Temporal value types for the Neo4j driver.

   Modelled on the Neo4j Python driver's time module (neo4j.time). The
   representations are wire-compatible with the Bolt protocol:

   - Date     : days since 1970-01-01 (proleptic Gregorian).
   - Time     : ticks (nanoseconds since midnight) + optional UTC offset.
   - DateTime : epoch seconds (UTC-based) + sub-second nanoseconds + optional
                time zone (offset or IANA zone name).
   - Duration : months, days, seconds and nanoseconds.

   Named time zones are handled opaquely: the epoch is UTC-based, so the UTC
   wall clock is always derivable, but converting a wall clock in a named zone
   to an epoch (and Ptime interop for named zones) requires a time zone
   database and is not supported; such conversions return [None]. *)

let seconds_per_day = 86_400L
let ns_per_day = 86_400_000_000_000L
let ps_per_day = 86_400_000_000_000_000L
let min_year = 1
let max_year = 9999

let pow10 n =
  let rec go acc = function 0 -> acc | k -> go (acc * 10) (k - 1) in
  go 1 n

let floor_div_rem n d =
  let q = Int64.div n d in
  let r = Int64.rem n d in
  if r < 0L then (Int64.sub q 1L, Int64.add r d) else (q, r)

(* --- Proleptic Gregorian calendar (Howard Hinnant's algorithms) --- *)

let days_from_civil (y, m, d) =
  let y = if m <= 2 then y - 1 else y in
  let era = if y >= 0 then y / 400 else (y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * if m > 2 then m - 3 else m + 9) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z =
  let z = z + 719468 in
  let era = if z >= 0 then z / 146097 else (z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = if m <= 2 then y + 1 else y in
  (y, m, d)

let days_in_month (y, m) =
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0 then 29 else 28
  | _ -> invalid_arg "days_in_month"

(* Proleptic Gregorian ordinal of 1970-01-01. *)
let epoch_ordinal = 719163

(* --- Time zones --- *)

type tz = Offset of int | Zone_name of string

let tz_to_string = function
  | Offset offset ->
      let sign = if offset < 0 then "-" else "+" in
      let abs = abs offset in
      Printf.sprintf "%s%02d:%02d" sign (abs / 3600) (abs mod 3600 / 60)
  | Zone_name name -> name

(* --- Date --- *)

type date = int

module Date = struct
  type t = date

  let of_days days = days
  let to_days t = t

  let of_ymd (y, m, d) =
    if
      y < min_year || y > max_year || m < 1 || m > 12 || d < 1
      || d > days_in_month (y, m)
    then None
    else Some (of_days (days_from_civil (y, m, d)))

  let to_ymd t = civil_from_days t
  let to_ordinal t = t + epoch_ordinal
  let of_ordinal ordinal = of_days (ordinal - epoch_ordinal)
  let add_days n t = t + n
  let diff_days a b = a - b
  let compare a b = compare a b
  let equal a b = a = b

  let add_months n t =
    let y, m, d = to_ymd t in
    let total = (y * 12) + (m - 1) + n in
    let y' = total / 12 in
    let m' = (total mod 12) + 1 in
    if y' < min_year || y' > max_year then None
    else of_ymd (y', m', min d (days_in_month (y', m')))

  let to_iso8601 t =
    let y, m, d = to_ymd t in
    Printf.sprintf "%04d-%02d-%02d" y m d

  let of_iso8601 s =
    match String.split_on_char '-' s with
    | [ y; m; d ] -> (
        match
          (int_of_string_opt y, int_of_string_opt m, int_of_string_opt d)
        with
        | Some y, Some m, Some d -> of_ymd (y, m, d)
        | _ -> None)
    | _ -> None

  let to_string = to_iso8601
end

(* --- Time --- *)

type time = { ticks : int64; tz_offset_seconds : int option }

module Time = struct
  type t = time

  let of_ticks ?tz_offset_seconds ticks = { ticks; tz_offset_seconds }
  let to_ticks t = t.ticks
  let tz_offset_seconds t = t.tz_offset_seconds

  let of_hms_ns ?tz_offset_seconds h m s ns =
    if
      h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59 || ns < 0
      || ns > 999_999_999
    then None
    else
      let ticks =
        Int64.add
          (Int64.mul 3_600_000_000_000L (Int64.of_int h))
          (Int64.add
             (Int64.mul 60_000_000_000L (Int64.of_int m))
             (Int64.add
                (Int64.mul 1_000_000_000L (Int64.of_int s))
                (Int64.of_int ns)))
      in
      Some { ticks; tz_offset_seconds }

  let to_hms_ns t =
    let ns = Int64.to_int (Int64.rem t.ticks 1_000_000_000L) in
    let s = Int64.to_int (Int64.rem (Int64.div t.ticks 1_000_000_000L) 60L) in
    let m = Int64.to_int (Int64.rem (Int64.div t.ticks 60_000_000_000L) 60L) in
    let h = Int64.to_int (Int64.div t.ticks 3_600_000_000_000L) in
    (h, m, s, ns)

  let add nanoseconds t = { t with ticks = Int64.add t.ticks nanoseconds }
  let sub nanoseconds t = { t with ticks = Int64.sub t.ticks nanoseconds }
  let compare a b = compare a.ticks b.ticks
  let equal a b = a.ticks = b.ticks && a.tz_offset_seconds = b.tz_offset_seconds

  let to_iso8601 t =
    let h, m, s, ns = to_hms_ns t in
    let base = Printf.sprintf "%02d:%02d:%02d" h m s in
    let frac = if ns = 0 then "" else Printf.sprintf ".%09d" ns in
    match t.tz_offset_seconds with
    | None -> base ^ frac
    | Some offset -> base ^ frac ^ tz_to_string (Offset offset)

  (* Parse the time-of-day part of an ISO 8601 string:
     "HH:MM:SS[.fraction][Z|+-HH:MM]". Returns the time and its offset, if
     any. *)
  let parse_time_of_day s =
    let len = String.length s in
    if len < 8 || s.[2] <> ':' || s.[5] <> ':' then None
    else
      let int_sub lo hi = int_of_string_opt (String.sub s lo (hi - lo)) in
      match (int_sub 0 2, int_sub 3 5, int_sub 6 8) with
      | Some h, Some m, Some sec -> (
          let i = ref 8 in
          let ns = ref 0 in
          if !i < len && s.[!i] = '.' then begin
            incr i;
            let digits = ref 0 in
            while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
              if !digits < 9 then begin
                ns := (!ns * 10) + (Char.code s.[!i] - Char.code '0');
                incr digits
              end;
              incr i
            done;
            ns := !ns * pow10 (9 - !digits)
          end;
          (* [None] = malformed offset, [Some None] = no offset. *)
          let tz =
            if !i < len then
              match s.[!i] with
              | 'Z' ->
                  incr i;
                  Some (Some (Offset 0))
              | '+' | '-' ->
                  if !i + 5 < len && s.[!i + 3] = ':' then
                    match
                      (int_sub (!i + 1) (!i + 3), int_sub (!i + 4) (!i + 6))
                    with
                    | Some oh, Some om ->
                        incr i;
                        let offset = (oh * 3600) + (om * 60) in
                        Some
                          (Some
                             (Offset
                                (if s.[!i - 1] = '-' then -offset else offset)))
                    | _ -> None
                  else None
              | _ -> None
            else Some None
          in
          match tz with
          | None -> None
          | Some tz -> (
              match
                of_hms_ns
                  ?tz_offset_seconds:
                    (match tz with Some (Offset o) -> Some o | _ -> None)
                  h m sec !ns
              with
              | Some t -> Some (t, tz)
              | None -> None))
      | _ -> None

  let of_iso8601 s =
    match parse_time_of_day s with Some (t, _) -> Some t | None -> None

  let to_string = to_iso8601
end

(* --- Duration --- *)

type duration = { months : int; days : int; seconds : int64; nanoseconds : int }

module Duration = struct
  type t = duration

  let of_fields ~months ~days ~seconds ~nanoseconds =
    { months; days; seconds; nanoseconds }

  let to_fields t = (t.months, t.days, t.seconds, t.nanoseconds)

  let neg t =
    {
      months = -t.months;
      days = -t.days;
      seconds = Int64.neg t.seconds;
      nanoseconds = -t.nanoseconds;
    }

  let add a b =
    let seconds = Int64.add a.seconds b.seconds in
    let nanoseconds = a.nanoseconds + b.nanoseconds in
    let seconds, nanoseconds =
      if nanoseconds >= 1_000_000_000 then
        (Int64.add seconds 1L, nanoseconds - 1_000_000_000)
      else if nanoseconds < 0 then
        (Int64.sub seconds 1L, nanoseconds + 1_000_000_000)
      else (seconds, nanoseconds)
    in
    {
      months = a.months + b.months;
      days = a.days + b.days;
      seconds;
      nanoseconds;
    }

  let sub a b = add a (neg b)

  let compare a b =
    compare
      (a.months, a.days, a.seconds, a.nanoseconds)
      (b.months, b.days, b.seconds, b.nanoseconds)

  let equal a b = compare a b = 0

  let to_total_seconds t =
    Int64.add
      (Int64.mul (Int64.of_int ((t.months * 30) + t.days)) seconds_per_day)
      t.seconds

  let to_iso8601 t =
    let negative =
      t.months < 0 || t.days < 0
      || Int64.compare t.seconds 0L < 0
      || t.nanoseconds < 0
    in
    let t = if negative then neg t else t in
    let years = t.months / 12 in
    let months = t.months mod 12 in
    let hours = Int64.div t.seconds 3_600L in
    let minutes = Int64.div (Int64.rem t.seconds 3_600L) 60L in
    let seconds = Int64.rem t.seconds 60L in
    let buffer = Buffer.create 16 in
    if negative then Buffer.add_char buffer '-';
    Buffer.add_char buffer 'P';
    if years > 0 then Printf.bprintf buffer "%dY" years;
    if months > 0 then Printf.bprintf buffer "%dM" months;
    if t.days > 0 then Printf.bprintf buffer "%dD" t.days;
    if hours > 0L || minutes > 0L || seconds > 0L || t.nanoseconds > 0 then begin
      Buffer.add_char buffer 'T';
      if hours > 0L then Printf.bprintf buffer "%LdH" hours;
      if minutes > 0L then Printf.bprintf buffer "%LdM" minutes;
      if seconds > 0L || t.nanoseconds > 0 then begin
        Printf.bprintf buffer "%Ld" seconds;
        if t.nanoseconds > 0 then Printf.bprintf buffer ".%09d" t.nanoseconds;
        Buffer.add_char buffer 'S'
      end
    end;
    if Buffer.length buffer = 1 + if negative then 1 else 0 then
      Buffer.add_string buffer "T0S";
    Buffer.contents buffer

  let of_iso8601 s =
    let len = String.length s in
    let i = ref 0 in
    let negative = !i < len && s.[!i] = '-' in
    if negative then incr i;
    if !i >= len || s.[!i] <> 'P' then None
    else begin
      incr i;
      let months = ref 0 in
      let days = ref 0 in
      let seconds = ref 0L in
      let nanoseconds = ref 0 in
      let time_part = ref false in
      let ok = ref true in
      let read_number () =
        let start = !i in
        while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
          incr i
        done;
        if !i = start then None
        else int_of_string_opt (String.sub s start (!i - start))
      in
      while !ok && !i < len do
        if s.[!i] = 'T' then begin
          incr i;
          time_part := true
        end
        else
          match read_number () with
          | None -> ok := false
          | Some n ->
              if !i < len && s.[!i] = '.' then begin
                (* fractional seconds: "<n>.<frac>S" *)
                incr i;
                let frac = ref 0 in
                let digits = ref 0 in
                while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
                  if !digits < 9 then begin
                    frac := (!frac * 10) + (Char.code s.[!i] - Char.code '0');
                    incr digits
                  end;
                  incr i
                done;
                if !i < len && s.[!i] = 'S' && !time_part then begin
                  incr i;
                  seconds := Int64.add !seconds (Int64.of_int n);
                  nanoseconds := !frac * pow10 (9 - !digits)
                end
                else ok := false
              end
              else if !i < len then
                match s.[!i] with
                | 'Y' when not !time_part ->
                    incr i;
                    months := !months + (n * 12)
                | 'M' when not !time_part ->
                    incr i;
                    months := !months + n
                | 'D' when not !time_part ->
                    incr i;
                    days := !days + n
                | 'H' when !time_part ->
                    incr i;
                    seconds :=
                      Int64.add !seconds (Int64.mul (Int64.of_int n) 3_600L)
                | 'M' when !time_part ->
                    incr i;
                    seconds :=
                      Int64.add !seconds (Int64.mul (Int64.of_int n) 60L)
                | 'S' when !time_part ->
                    incr i;
                    seconds := Int64.add !seconds (Int64.of_int n)
                | _ -> ok := false
              else ok := false
      done;
      if not !ok then None
      else
        Some
          {
            months = (if negative then - !months else !months);
            days = (if negative then - !days else !days);
            seconds = (if negative then Int64.neg !seconds else !seconds);
            nanoseconds = (if negative then - !nanoseconds else !nanoseconds);
          }
    end

  (* Ptime spans cannot represent months. *)
  let to_span t =
    if t.months <> 0 then None
    else
      let total_ps =
        Int64.add
          (Int64.mul t.seconds 1_000_000_000_000L)
          (Int64.mul (Int64.of_int t.nanoseconds) 1_000L)
      in
      let days, ps = floor_div_rem total_ps ps_per_day in
      Ptime.Span.of_d_ps (Int64.to_int days, ps)

  let of_span span =
    let days, ps = Ptime.Span.to_d_ps span in
    let seconds = Int64.div ps 1_000_000_000_000L in
    let nanoseconds =
      Int64.to_int (Int64.div (Int64.rem ps 1_000_000_000_000L) 1_000L)
    in
    { months = 0; days; seconds; nanoseconds }

  let to_string = to_iso8601
end

(* --- DateTime --- *)

type datetime = { epoch_seconds : int64; nanoseconds : int; tz : tz option }

module DateTime = struct
  type t = datetime

  let of_epoch_seconds ?tz epoch_seconds nanoseconds =
    { epoch_seconds; nanoseconds; tz }

  let to_epoch_seconds t = (t.epoch_seconds, t.nanoseconds)
  let tz t = t.tz

  (* Wall-clock seconds in the time zone of [t]. *)
  let wall_seconds t =
    match t.tz with
    | Some (Offset offset) -> Int64.add t.epoch_seconds (Int64.of_int offset)
    | _ -> t.epoch_seconds

  let to_ymd_hms t =
    let days, rem = floor_div_rem (wall_seconds t) seconds_per_day in
    let days = Int64.to_int days in
    let h = Int64.to_int (Int64.div rem 3_600L) in
    let m = Int64.to_int (Int64.div (Int64.rem rem 3_600L) 60L) in
    let s = Int64.to_int (Int64.rem rem 60L) in
    (civil_from_days days, (h, m, s), t.nanoseconds)

  let of_ymd_hms ?tz (y, mo, d) (h, m, s) ns =
    match Date.of_ymd (y, mo, d) with
    | None -> None
    | Some _ -> (
        if
          h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59 || ns < 0
          || ns > 999_999_999
        then None
        else
          match tz with
          | Some (Zone_name _) -> None
          | _ ->
              let wall =
                Int64.add
                  (Int64.mul
                     (Int64.of_int (days_from_civil (y, mo, d)))
                     seconds_per_day)
                  (Int64.of_int ((h * 3600) + (m * 60) + s))
              in
              let epoch =
                match tz with
                | Some (Offset offset) -> Int64.sub wall (Int64.of_int offset)
                | _ -> wall
              in
              Some { epoch_seconds = epoch; nanoseconds = ns; tz })

  let compare a b =
    match Int64.compare a.epoch_seconds b.epoch_seconds with
    | 0 -> compare a.nanoseconds b.nanoseconds
    | c -> c

  let equal a b = compare a b = 0

  (* --- arithmetic --- *)

  let normalize_time (h, m, s, ns) add_seconds add_ns =
    let total =
      Int64.add
        (Int64.mul 3_600_000_000_000L (Int64.of_int h))
        (Int64.add
           (Int64.mul 60_000_000_000L (Int64.of_int m))
           (Int64.add
              (Int64.mul 1_000_000_000L (Int64.of_int s))
              (Int64.of_int ns)))
    in
    let total =
      Int64.add total
        (Int64.add (Int64.mul add_seconds 1_000_000_000L) (Int64.of_int add_ns))
    in
    let days, rem = floor_div_rem total ns_per_day in
    let h' = Int64.to_int (Int64.div rem 3_600_000_000_000L) in
    let m' =
      Int64.to_int
        (Int64.div (Int64.rem rem 3_600_000_000_000L) 60_000_000_000L)
    in
    let s' =
      Int64.to_int (Int64.div (Int64.rem rem 60_000_000_000L) 1_000_000_000L)
    in
    let ns' = Int64.to_int (Int64.rem rem 1_000_000_000L) in
    (Int64.to_int days, (h', m', s', ns'))

  let add (d : Duration.t) t =
    match t.tz with
    | Some (Zone_name _) -> None
    | tz -> (
        let (y, mo, day), (h, m, s), ns = to_ymd_hms t in
        let carry, (h', m', s', ns') =
          normalize_time (h, m, s, ns) d.seconds d.nanoseconds
        in
        match
          Date.add_months d.months (Date.of_days (days_from_civil (y, mo, day)))
        with
        | None -> None
        | Some date ->
            let date = Date.add_days (d.days + carry) date in
            let y', mo', d' = civil_from_days (Date.to_days date) in
            of_ymd_hms ?tz (y', mo', d') (h', m', s') ns')

  let sub (d : Duration.t) t =
    add
      {
        months = -d.months;
        days = -d.days;
        seconds = Int64.neg d.seconds;
        nanoseconds = -d.nanoseconds;
      }
      t

  (* Difference [a - b] expressed in days, seconds and nanoseconds. *)
  let diff a b =
    match (a.tz, b.tz) with
    | Some (Zone_name _), _ | _, Some (Zone_name _) -> None
    | _ ->
        let seconds = Int64.sub (wall_seconds a) (wall_seconds b) in
        let nanoseconds = a.nanoseconds - b.nanoseconds in
        let seconds, nanoseconds =
          if nanoseconds < 0 then
            (Int64.sub seconds 1L, nanoseconds + 1_000_000_000)
          else (seconds, nanoseconds)
        in
        let days = Int64.div seconds seconds_per_day in
        let seconds = Int64.rem seconds seconds_per_day in
        Some { months = 0; days = Int64.to_int days; seconds; nanoseconds }

  (* --- ISO 8601 --- *)

  let to_iso8601 t =
    let (y, mo, d), (h, m, s), ns = to_ymd_hms t in
    let date = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d" y mo d h m s in
    let frac = if ns = 0 then "" else Printf.sprintf ".%09d" ns in
    let suffix =
      match t.tz with
      | Some (Offset offset) -> tz_to_string (Offset offset)
      | Some (Zone_name _) | None -> ""
    in
    date ^ frac ^ suffix

  let of_iso8601 s =
    let sep =
      match String.index_opt s 'T' with
      | Some i -> Some i
      | None -> String.index_opt s ' '
    in
    match sep with
    | None -> None
    | Some i -> (
        let date_s = String.sub s 0 i in
        let time_s = String.sub s (i + 1) (String.length s - i - 1) in
        match (Date.of_iso8601 date_s, Time.parse_time_of_day time_s) with
        | Some date, Some (time, tz) ->
            let y, mo, d = Date.to_ymd date in
            let h, m, sec, ns = Time.to_hms_ns time in
            of_ymd_hms ?tz (y, mo, d) (h, m, sec) ns
        | _ -> None)

  (* --- Ptime interop (offset / naive only) --- *)

  let to_ptime t =
    match t.tz with
    | Some (Zone_name _) -> None
    | _ -> (
        let (y, mo, d), (h, m, s), ns = to_ymd_hms t in
        let tz_offset_s = match t.tz with Some (Offset o) -> o | _ -> 0 in
        match Ptime.of_date_time ((y, mo, d), ((h, m, s), tz_offset_s)) with
        | None -> None
        | Some ptime ->
            let ns_span =
              match
                Ptime.Span.of_d_ps (0, Int64.mul (Int64.of_int ns) 1_000L)
              with
              | Some span -> span
              | None -> Ptime.Span.zero
            in
            Ptime.add_span ptime ns_span)

  let of_ptime ?tz ptime =
    let (y, mo, d), ((h, m, s), _) = Ptime.to_date_time ptime in
    let _, ps = Ptime.Span.to_d_ps (Ptime.to_span ptime) in
    let nanoseconds =
      Int64.to_int (Int64.rem (Int64.div ps 1_000L) 1_000_000_000L)
    in
    let epoch_seconds =
      Int64.add
        (Int64.mul (Int64.of_int (days_from_civil (y, mo, d))) seconds_per_day)
        (Int64.of_int ((h * 3600) + (m * 60) + s))
    in
    { epoch_seconds; nanoseconds; tz }

  let to_string = to_iso8601
end
