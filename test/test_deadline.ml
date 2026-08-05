open Neodriver
open Alcotest

let infinite () =
  let d = Deadline.create None in
  check bool "not set" false (Deadline.is_set d);
  check (option (float 1e-9)) "no timeout" None (Deadline.to_timeout d);
  check bool "not expired" false (Deadline.expired d);
  check
    (option (float 1e-9))
    "no original timeout" None
    (Deadline.original_timeout d);
  let d = Deadline.create (Some infinity) in
  check bool "inf not set" false (Deadline.is_set d)

let finite () =
  let d = Deadline.create (Some 10.0) in
  check bool "set" true (Deadline.is_set d);
  check
    (option (float 1e-9))
    "original timeout" (Some 10.0)
    (Deadline.original_timeout d);
  (match Deadline.to_timeout d with
  | Some t -> check bool "within bounds" true (t >= 0.0 && t <= 10.0)
  | None -> fail "finite deadline must have a timeout");
  check bool "not expired" false (Deadline.expired d)

let expired () =
  let d = Deadline.create (Some (-1.0)) in
  check bool "negative deadline expired" true (Deadline.expired d);
  check
    (option (float 1e-9))
    "clamped to zero" (Some 0.0) (Deadline.to_timeout d)

let merge () =
  let a = Deadline.create (Some 10.0) in
  let b = Deadline.create (Some 5.0) in
  let none = Deadline.create None in
  (match Deadline.merge [ a; b ] with
  | Some m ->
      check
        (option (float 1e-9))
        "earliest" (Some 5.0)
        (Deadline.original_timeout m)
  | None -> fail "merge of finite deadlines must return a deadline");
  (match Deadline.merge [ none ] with
  | Some _ -> fail "merge of only unset deadlines should be None"
  | None -> ());
  (match Deadline.merge [] with
  | Some _ -> fail "merge of empty list should be None"
  | None -> ());
  match Deadline.merge_and_timeouts [ None; Some 3.0 ] with
  | Some m ->
      check
        (option (float 1e-9))
        "orig timeout" (Some 3.0)
        (Deadline.original_timeout m)
  | None -> fail "merge_and_timeouts of finite should return"

let to_string () =
  check string "unset string" "Deadline(timeout=none)"
    (Deadline.to_string (Deadline.create None));
  check string "finite string" "Deadline(timeout=5)"
    (Deadline.to_string (Deadline.create (Some 5.0)))

let tests =
  [
    ("[Deadline] infinite", [ test_case "unset deadline" `Quick infinite ]);
    ("[Deadline] finite", [ test_case "finite deadline" `Quick finite ]);
    ("[Deadline] expired", [ test_case "expired deadline" `Quick expired ]);
    ("[Deadline] merge", [ test_case "merge deadlines" `Quick merge ]);
    ("[Deadline] to_string", [ test_case "string rendering" `Quick to_string ]);
  ]
