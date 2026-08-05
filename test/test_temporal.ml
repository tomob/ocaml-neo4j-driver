open Neodriver
open Alcotest
module D = Temporal.Date
module T = Temporal.Time
module DT = Temporal.DateTime
module DU = Temporal.Duration

let date_round_trip () =
  (match D.of_ymd (1970, 1, 1) with
  | Some d -> check int "epoch days" 0 (D.to_days d)
  | None -> fail "1970-01-01");
  (match D.of_ymd (1969, 12, 31) with
  | Some d -> check int "pre-epoch days" (-1) (D.to_days d)
  | None -> fail "1969-12-31");
  (match D.of_ymd (2024, 1, 1) with
  | Some d -> check int "2024 days" 19723 (D.to_days d)
  | None -> fail "2024-01-01");
  (match D.of_iso8601 "1970-01-01" with
  | Some d -> check string "iso 1970" "1970-01-01" (D.to_string d)
  | None -> fail "iso 1970");
  (match D.of_iso8601 "2024-02-29" with
  | Some d -> check string "leap 2024" "2024-02-29" (D.to_string d)
  | None -> fail "leap 2024");
  (match D.of_iso8601 "2023-02-29" with
  | Some _ -> fail "invalid leap day should fail"
  | None -> ());
  (match D.of_iso8601 "2024-13-01" with
  | Some _ -> fail "invalid month should fail"
  | None -> ());
  match D.of_ymd (2024, 1, 1) with
  | Some d ->
      check string "ordinal round trip" "2024-01-01"
        (D.to_string (D.of_ordinal (D.to_ordinal d)))
  | None -> fail "2024-01-01"

let date_arithmetic () =
  (match D.of_ymd (2024, 1, 31) with
  | Some d -> (
      match D.add_months 1 d with
      | Some d' ->
          check string "jan31 +1mo clamps" "2024-02-29" (D.to_string d')
      | None -> fail "jan31 +1mo")
  | None -> fail "2024-01-31");
  (match D.of_ymd (2024, 3, 31) with
  | Some d -> (
      match D.add_months (-1) d with
      | Some d' ->
          check string "mar31 -1mo clamps" "2024-02-29" (D.to_string d')
      | None -> fail "mar31 -1mo")
  | None -> fail "2024-03-31");
  match D.of_ymd (2024, 1, 1) with
  | Some d ->
      check string "add 1 day" "2024-01-02" (D.to_string (D.add_days 1 d))
  | None -> fail "2024-01-01"

let time_round_trip () =
  (match T.of_hms_ns 12 34 56 123456789 with
  | Some t -> check string "hms" "12:34:56.123456789" (T.to_string t)
  | None -> fail "of_hms_ns");
  (match T.of_hms_ns 0 0 0 0 with
  | Some t -> check int64 "midnight ticks" 0L (T.to_ticks t)
  | None -> fail "midnight");
  (match T.of_hms_ns 23 59 59 999999999 with
  | Some t -> check string "max" "23:59:59.999999999" (T.to_string t)
  | None -> fail "max");
  (match T.of_hms_ns 24 0 0 0 with
  | Some _ -> fail "hour 24 should fail"
  | None -> ());
  (match T.of_iso8601 "12:34:56.123456789" with
  | Some t -> check string "iso round" "12:34:56.123456789" (T.to_string t)
  | None -> fail "iso");
  (match T.of_iso8601 "12:00:00Z" with
  | Some t -> check string "iso z" "12:00:00+00:00" (T.to_string t)
  | None -> fail "iso z");
  match T.of_iso8601 "12:00:00+02:00" with
  | Some t -> check string "iso offset" "12:00:00+02:00" (T.to_string t)
  | None -> fail "iso offset"

let time_arithmetic () =
  match T.of_hms_ns 12 0 0 0 with
  | Some t ->
      let t' = T.add 3_600_000_000_000L t in
      check string "add 1h" "13:00:00" (T.to_string t')
  | None -> fail "of_hms_ns"

let datetime_round_trip () =
  (match DT.of_ymd_hms (1970, 1, 1) (0, 0, 0) 0 with
  | Some dt ->
      check string "epoch naive" "1970-01-01T00:00:00" (DT.to_string dt)
  | None -> fail "epoch");
  (match DT.of_ymd_hms ~tz:(Offset 7200) (1970, 1, 1) (0, 0, 0) 0 with
  | Some dt ->
      check int64 "offset epoch" (-7200L) (fst (DT.to_epoch_seconds dt))
  | None -> fail "offset epoch");
  (match
     DT.of_ymd_hms ~tz:(Zone_name "Europe/Warsaw") (2024, 1, 1) (12, 0, 0) 0
   with
  | Some _ -> fail "named zone of_ymd_hms should be None"
  | None -> ());
  (match DT.of_iso8601 "2024-01-01T12:34:56.123456789+02:00" with
  | Some dt ->
      check string "iso round" "2024-01-01T12:34:56.123456789+02:00"
        (DT.to_string dt)
  | None -> fail "iso round");
  (match DT.of_iso8601 "2024-01-01T00:00:00Z" with
  | Some dt ->
      check string "iso z" "2024-01-01T00:00:00+00:00" (DT.to_string dt)
  | None -> fail "iso z");
  match DT.of_iso8601 "2024-01-01 12:00:00" with
  | Some dt -> check string "iso space" "2024-01-01T12:00:00" (DT.to_string dt)
  | None -> fail "iso space"

let datetime_ptime () =
  (match DT.of_ymd_hms (2024, 1, 1) (12, 0, 0) 0 with
  | Some dt -> (
      match DT.to_ptime dt with
      | Some p ->
          let dt' = DT.of_ptime p in
          check bool "ptime round" true (DT.equal dt dt')
      | None -> fail "to_ptime")
  | None -> fail "2024-01-01");
  match DT.of_ymd_hms (1970, 1, 1) (0, 0, 0) 0 with
  | Some dt -> (
      match DT.to_ptime dt with
      | Some p ->
          check bool "epoch ptime" true
            (Ptime.equal p (Option.get (Ptime.of_float_s 0.)))
      | None -> fail "epoch to_ptime")
  | None -> fail "epoch"

let duration_round_trip () =
  let d = DU.of_fields ~months:14 ~days:3 ~seconds:4L ~nanoseconds:500000000 in
  check string "iso" "P1Y2M3DT4.500000000S" (DU.to_string d);
  (match DU.of_iso8601 "P1Y2M3DT4H5M6.5S" with
  | Some d ->
      check string "iso round" "P1Y2M3DT4H5M6.500000000S" (DU.to_string d)
  | None -> fail "iso parse");
  (match DU.of_iso8601 "PT0S" with
  | Some d -> check string "zero" "PT0S" (DU.to_string d)
  | None -> fail "zero");
  (match DU.of_iso8601 "P1DT2H" with
  | Some d -> check string "1dt2h" "P1DT2H" (DU.to_string d)
  | None -> fail "1dt2h");
  match DU.of_iso8601 "garbage" with
  | Some _ -> fail "garbage should fail"
  | None -> ()

let duration_arithmetic () =
  let a = DU.of_fields ~months:1 ~days:0 ~seconds:0L ~nanoseconds:500000000 in
  let b = DU.of_fields ~months:0 ~days:1 ~seconds:0L ~nanoseconds:500000000 in
  let sum = DU.add a b in
  check int "sum months" 1 sum.months;
  check int "sum days" 1 sum.days;
  check int64 "sum seconds carry" 1L sum.seconds;
  check int "sum ns" 0 sum.nanoseconds;
  let diff = DU.sub a b in
  check int "diff months" 1 diff.months;
  check int "diff days" (-1) diff.days;
  check int64 "total seconds" 2592000L (DU.to_total_seconds a)

let duration_span () =
  let d = DU.of_fields ~months:0 ~days:0 ~seconds:90L ~nanoseconds:500000000 in
  match DU.to_span d with
  | Some span ->
      let back = DU.of_span span in
      check int64 "span seconds" 90L back.seconds;
      check int "span ns" 500000000 back.nanoseconds
  | None -> fail "to_span"

let tests =
  [
    ( "[Temporal] Date round_trip",
      [ test_case "round trip" `Quick date_round_trip ] );
    ( "[Temporal] Date arithmetic",
      [ test_case "arithmetic" `Quick date_arithmetic ] );
    ( "[Temporal] Time round_trip",
      [ test_case "round trip" `Quick time_round_trip ] );
    ( "[Temporal] Time arithmetic",
      [ test_case "arithmetic" `Quick time_arithmetic ] );
    ( "[Temporal] DateTime round_trip",
      [ test_case "round trip" `Quick datetime_round_trip ] );
    ("[Temporal] DateTime ptime", [ test_case "ptime" `Quick datetime_ptime ]);
    ( "[Temporal] Duration round_trip",
      [ test_case "round trip" `Quick duration_round_trip ] );
    ( "[Temporal] Duration arithmetic",
      [ test_case "arithmetic" `Quick duration_arithmetic ] );
    ("[Temporal] Duration span", [ test_case "span" `Quick duration_span ]);
  ]
