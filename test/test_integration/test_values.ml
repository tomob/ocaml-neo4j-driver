(* Integration tests for value round-trips against a live Neo4j instance: rich
   [Values.t] sent as parameters and echoed back, plus vector round-trips
   (which the TestKit skips) and temporal values including named time zones.
   These run only when the TEST_NEO4J_* environment variables are set;
   otherwise they are skipped. *)

open Neodriver
open Neodriver_eio
open Alcotest

let with_env f = match Test_env.of_env () with Some env -> f env | None -> Alcotest.skip ()
let uri_of env = Printf.sprintf "%s://%s:%d" env.Test_env.scheme env.Test_env.host env.Test_env.port
let auth_of env = Conn.basic_auth ~principal:env.Test_env.user ~credentials:env.Test_env.password ()

let with_driver env f =
  Eio_main.run (fun e ->
      let net = Eio.Stdenv.net e in
      let clock = Eio.Stdenv.mono_clock e in
      Eio.Switch.run (fun sw ->
          match Driver.connect ~uri:(uri_of env) ~auth:(auth_of env) net clock sw with
          | Error error -> fail (Errors.to_string error)
          | Ok driver -> Fun.protect ~finally:(fun () -> Driver.close driver) (fun () -> f driver)))

(* Echo [value] back from the server via [RETURN $p AS p]. *)
let echo session value =
  match Session.run session ~query:"RETURN $p AS p" ~parameters:[ ("p", value) ] with
  | Ok result -> (
      match Neo4jResult.values result with
      | Ok [ [ v ] ] -> v
      | Ok _ -> fail "expected one record with one value"
      | Error e -> fail (Errors.to_string e))
  | Error e -> fail (Errors.to_string e)

(* The value of the single column of a scalar Cypher expression. *)
let cypher session expr =
  match Session.run session ~query:(Printf.sprintf "RETURN %s AS p" expr) ~parameters:[] with
  | Ok result -> (
      match Neo4jResult.values result with
      | Ok [ [ v ] ] -> v
      | Ok _ -> fail "expected one record with one value"
      | Error e -> fail (Errors.to_string e))
  | Error e -> fail (Errors.to_string e)

let rec equal_value a b =
  match (a, b) with
  | Values.Null, Values.Null -> true
  | Values.Bool x, Values.Bool y -> x = y
  | Values.Int x, Values.Int y -> Int64.equal x y
  | Values.Float x, Values.Float y -> Float.equal x y
  | Values.String x, Values.String y -> x = y
  | Values.Bytes x, Values.Bytes y -> Bytes.equal x y
  | Values.List xs, Values.List ys ->
      List.length xs = List.length ys && List.for_all2 equal_value xs ys
  | Values.Map xs, Values.Map ys ->
      List.length xs = List.length ys
      && List.for_all2 (fun (k1, v1) (k2, v2) -> k1 = k2 && equal_value v1 v2) xs ys
  | Values.Point p, Values.Point q -> (
      p.srid = q.srid && Float.equal p.x q.x && Float.equal p.y q.y
      &&
      match (p.z, q.z) with
      | None, None -> true
      | Some z1, Some z2 -> Float.equal z1 z2
      | _ -> false)
  | Values.Date d1, Values.Date d2 -> Temporal.Date.equal d1 d2
  | Values.Time t1, Values.Time t2 -> Temporal.Time.equal t1 t2
  | Values.DateTime d1, Values.DateTime d2 -> (
      Temporal.DateTime.equal d1 d2
      &&
      match (Temporal.DateTime.tz d1, Temporal.DateTime.tz d2) with
      | None, None -> true
      | Some (Temporal.Offset o1), Some (Temporal.Offset o2) -> o1 = o2
      | Some (Temporal.Zone_name z1), Some (Temporal.Zone_name z2) -> z1 = z2
      | _ -> false)
  | Values.Duration d1, Values.Duration d2 -> Temporal.Duration.equal d1 d2
  | Values.Vector v1, Values.Vector v2 -> v1.dtype = v2.dtype && Bytes.equal v1.data v2.data
  | _ -> false

let check_echo session name value = check bool name true (equal_value value (echo session value))

(* Big-endian bytes for a vector of the given dtype. *)
let vector_bytes set size xs =
  let b = Bytes.make (size * List.length xs) '\000' in
  List.iteri (fun i x -> set b (size * i) x) xs;
  b

let i8_bytes xs = vector_bytes Bytes.set_uint8 1 xs
let i16_bytes xs = vector_bytes Bytes.set_int16_be 2 xs
let i32_bytes xs = vector_bytes Bytes.set_int32_be 4 xs
let i64_bytes xs = vector_bytes Bytes.set_int64_be 8 xs
let f32_bytes xs = vector_bytes (fun b o x -> Bytes.set_int32_be b o (Int32.bits_of_float x)) 4 xs
let f64_bytes xs = vector_bytes (fun b o x -> Bytes.set_int64_be b o (Int64.bits_of_float x)) 8 xs

(* Scalar, collection and spatial/temporal round-trips. *)
let echo_round_trips () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          check_echo session "null" Values.Null;
          check_echo session "bool" (Values.Bool true);
          check_echo session "int" (Values.Int (-42L));
          check_echo session "float" (Values.Float 3.5);
          check_echo session "string" (Values.String "hello world");
          check_echo session "bytes" (Values.Bytes (Bytes.of_string "abc\000def"));
          check_echo session "list" (Values.List [ Values.Int 1L; Values.String "x"; Values.Null ]);
          check_echo session "map"
            (Values.Map [ ("a", Values.Int 1L); ("b", Values.List [ Values.Bool false ]) ]);
          check_echo session "point 2d" (Values.Point { srid = 7203; x = 1.5; y = -2.0; z = None });
          check_echo session "point 3d"
            (Values.Point { srid = 4979; x = 12.25; y = 33.5; z = Some 100.0 });
          let date = Option.get (Temporal.Date.of_ymd (2024, 2, 29)) in
          check_echo session "date" (Values.Date date);
          let time = Option.get (Temporal.Time.of_hms_ns ~tz_offset_seconds:3600 12 34 56 0) in
          check_echo session "time" (Values.Time time);
          let dt =
            Option.get
              (Temporal.DateTime.of_ymd_hms ~tz:(Temporal.Offset 7200) (2020, 1, 2) (3, 4, 5) 0)
          in
          check_echo session "datetime offset" (Values.DateTime dt);
          let duration =
            Temporal.Duration.of_fields ~months:1 ~days:2 ~seconds:(-3L) ~nanoseconds:4
          in
          check_echo session "duration" (Values.Duration duration);
          Session.close session))

(* Vector round-trips for every dtype (not covered by the TestKit, which skips
   the API_TYPE_VECTOR feature). *)
let vector_round_trips () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let vectors =
            [
              ("i8", Values.I8, i8_bytes [ 1; -2; 3 ]);
              ("i16", Values.I16, i16_bytes [ 1; 256; -1 ]);
              ("i32", Values.I32, i32_bytes [ 1l; 2l; 3l ]);
              ("i64", Values.I64, i64_bytes [ 1L; -2L ]);
              ("f32", Values.F32, f32_bytes [ 1.5; -0.0 ]);
              ("f64", Values.F64, f64_bytes [ 1.5; 2.25; -3.0 ]);
            ]
          in
          List.iter
            (fun (name, dtype, data) ->
              let value = Values.Vector { Values.dtype; data } in
              check_echo session ("vector " ^ name) value)
            vectors;
          Session.close session))

(* Temporal values with named time zones, including a pre-1970 instant (the LMT
   fallback path). The instant and zone name must survive the round trip. *)
let named_zones () =
  with_env (fun env ->
      with_driver env (fun driver ->
          let session = Driver.session driver in
          let assert_named_zone name expected_ymd expr =
            match cypher session expr with
            | Values.DateTime dt -> (
                match Temporal.DateTime.tz dt with
                | Some (Temporal.Zone_name zone) -> (
                    check string (name ^ " zone") "Europe/Warsaw" zone;
                    match expected_ymd with
                    | Some (y, mo, d) ->
                        let (yy, mm, dd), _, _ = Temporal.DateTime.to_ymd_hms dt in
                        check int (name ^ " year") y yy;
                        check int (name ^ " month") mo mm;
                        check int (name ^ " day") d dd
                    | None -> ())
                | _ -> fail (name ^ ": expected a named zone"))
            | _ -> fail (name ^ ": expected a datetime")
          in
          assert_named_zone "modern"
            (Some (2020, 7, 1))
            "datetime(\"2020-07-01T12:00:00[Europe/Warsaw]\")";
          assert_named_zone "pre-1970" None "datetime(\"1900-06-01T12:00:00[Europe/Warsaw]\")";
          Session.close session))

let tests =
  [
    ( "[Integration > Values] echo round-trips",
      [ test_case "scalars, collections, spatial, temporal" `Quick echo_round_trips ] );
    ( "[Integration > Values] vector round-trips",
      [ test_case "all vector dtypes" `Quick vector_round_trips ] );
    ( "[Integration > Values] named time zones",
      [ test_case "modern and pre-1970" `Quick named_zones ] );
  ]
