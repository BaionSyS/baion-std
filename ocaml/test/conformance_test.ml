(* BAION canonical JSON for OCaml — cross-lineage conformance tests.
   Public standalone library.

   Fixture path comes from BAION_CONFORMANCE_REF (default: the shared
   cross-lineage fixture one directory above this repo checkout) because
   the fixture is shared across all lineage libraries — a per-repo copy
   would drift. *)

open Baionstd_public

let fixture_path () =
  match Sys.getenv_opt "BAION_CONFORMANCE_REF" with
  | Some p -> p
  | None -> "../conformance_reference.json"

let load_reference () =
  let content =
    In_channel.with_open_text (fixture_path ()) In_channel.input_all
  in
  Yojson.Safe.from_string content

let get j key =
  match j with
  | `Assoc pairs -> begin
      match List.assoc_opt key pairs with
      | Some v -> v
      | None -> failwith ("missing key: " ^ key)
    end
  | _ -> failwith "not an object"

let get_str j key =
  match get j key with
  | `String s -> s
  | _ -> failwith ("not a string: " ^ key)

(* Canonicalize a fixture document and check both the canonical JSON bytes
   and the SHA-256 of those bytes against the reference values. *)
let check_document key () =
  let ref_ = load_reference () in
  let canonical = Canonical_json.canonicalize_json (get ref_ key) in
  let expected = get_str ref_ (key ^ "_canonical_json") in
  Alcotest.(check string) (key ^ " canonical JSON") expected canonical;
  let expected_hex = get_str ref_ (key ^ "_sha256_hex") in
  Alcotest.(check string)
    (key ^ " sha256")
    expected_hex
    (Hash.sha256_hex canonical)

(* Test integer-valued floats: canonicalize without trailing decimal.
   Build the value using Yojson's `Float variant explicitly so the
   canonicalizer sees float-tagged numbers; RFC 8785 requires 1.0 → "1". *)
let test_integer_valued_floats () =
  let ref_ = load_reference () in
  let v : Yojson.Safe.t =
    `Assoc
      [
        ("frac", `Float 1.5);
        ("neg", `Float (-7.0));
        ("vals", `List [ `Float 1.0; `Float 2.0; `Float 3.0 ]);
      ]
  in
  let canonical = Canonical_json.canonicalize_json v in
  let expected =
    get_str ref_ "reference_integer_valued_floats_canonical_json"
  in
  Alcotest.(check string) "integer-valued floats" expected canonical

(* Plain SHA-256 vector from the shared fixture *)
let test_sha256_reference () =
  let ref_ = load_reference () in
  let input = get_str ref_ "reference_sha256_input" in
  let expected_hex = get_str ref_ "reference_sha256_hex" in
  Alcotest.(check string)
    "sha256(reference input)" expected_hex (Hash.sha256_hex input)

(* SHA-256 hex against FIPS 180-4 published vectors *)
let test_sha256_hex () =
  Alcotest.(check string)
    "sha256(\"abc\")"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (Hash.sha256_hex "abc");
  Alcotest.(check string)
    "sha256(\"\")"
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (Hash.sha256_hex "")

(* End-to-end: hash of the canonical form is stable regardless of input
   key order and whitespace. *)
let test_hash_over_canonical () =
  let a = Yojson.Safe.from_string {|{"b":1,"a":[1,2]}|} in
  let b = Yojson.Safe.from_string {| { "a" : [ 1 , 2 ] , "b" : 1 } |} in
  Alcotest.(check string)
    "hash invariant under key order/whitespace"
    (Hash.sha256_hex (Canonical_json.canonicalize_json a))
    (Hash.sha256_hex (Canonical_json.canonicalize_json b))

(* U+0000 rejection: any string (object key or value, any depth) that
   contains NUL after parsing must be refused before canonicalization.
   yojson decodes the six-character escape in the JSON source to a real
   NUL, so {|"a\u0000b"|} below carries an actual U+0000. *)
let test_nul_rejected_in_value () =
  let v = Yojson.Safe.from_string {|{"x":"a\u0000b"}|} in
  Alcotest.check_raises "NUL in string value rejected"
    (Canonical_json.Nul_rejected "string value contains U+0000")
    (fun () -> ignore (Canonical_json.canonicalize_json v))

let test_nul_rejected_in_key () =
  let v = Yojson.Safe.from_string {|{"a\u0000":1}|} in
  Alcotest.check_raises "NUL in object key rejected"
    (Canonical_json.Nul_rejected "object key contains U+0000")
    (fun () -> ignore (Canonical_json.canonicalize_json v))

(* Escaped backslash followed by the text u0000 decodes to a literal
   backslash + "u0000" — no NUL — and must canonicalize normally. *)
let test_backslash_u0000_text_allowed () =
  let v = Yojson.Safe.from_string {|{"x":"a\\u0000b"}|} in
  Alcotest.(check string)
    "literal backslash + u0000 text passes"
    {|{"x":"a\\u0000b"}|}
    (Canonical_json.canonicalize_json v)

(* Duplicate object keys: yojson's Assoc keeps every member (including
   repeats), so the reject walk sees both entries and must refuse them
   before canonicalization — at top level, nested, or inside arrays. *)
let test_duplicate_key_top_level () =
  let v = Yojson.Safe.from_string {|{"a":1,"a":2}|} in
  Alcotest.check_raises "duplicate key at top level rejected"
    (Canonical_json.Duplicate_key "duplicate object key: a")
    (fun () -> ignore (Canonical_json.canonicalize_json v))

let test_duplicate_key_nested () =
  let v = Yojson.Safe.from_string {|{"x":{"b":1,"b":2}}|} in
  Alcotest.check_raises "duplicate key in nested object rejected"
    (Canonical_json.Duplicate_key "duplicate object key: b")
    (fun () -> ignore (Canonical_json.canonicalize_json v))

(* yojson decodes the backslash-u0061 escape to "a" while parsing, so the
   two keys below are the SAME decoded name and must collide — this is
   the "compare decoded key names" clause of the contract. *)
let test_duplicate_key_escaped () =
  let v = Yojson.Safe.from_string {|{"a":1,"\u0061":2}|} in
  Alcotest.check_raises "escaped spelling of same key rejected"
    (Canonical_json.Duplicate_key "duplicate object key: a")
    (fun () -> ignore (Canonical_json.canonicalize_json v))

let test_duplicate_key_in_array () =
  let v = Yojson.Safe.from_string {|[{"k":1,"k":2}]|} in
  Alcotest.check_raises "duplicate key in object inside array rejected"
    (Canonical_json.Duplicate_key "duplicate object key: k")
    (fun () -> ignore (Canonical_json.canonicalize_json v))

(* Distinct keys that merely share a prefix must NOT be flagged. *)
let test_distinct_keys_allowed () =
  let v = Yojson.Safe.from_string {|{"aa":1,"ab":2}|} in
  Alcotest.(check string)
    "distinct sibling keys pass"
    {|{"aa":1,"ab":2}|}
    (Canonical_json.canonicalize_json v)

let test_no_duplicates_mixed_allowed () =
  let v = Yojson.Safe.from_string {|{"b":1,"a":[1,2]}|} in
  Alcotest.(check string)
    "object with array value and unique keys passes"
    {|{"a":[1,2],"b":1}|}
    (Canonical_json.canonicalize_json v)

(* Number-domain enforcement is a LEXICAL pass over the raw text —
   yojson parses 1e2 and 100 to the same value, so the exponent
   spelling is only distinguishable before parsing. *)
let test_exponent_notation_rejected () =
  Alcotest.check_raises "1e2 spelling rejected"
    (Canonical_json.Number_rejected
       "unsupported number (exponent notation): 1e2")
    (fun () -> Canonical_json.reject_unsupported_numbers {|{"x":1e2}|});
  Alcotest.check_raises "uppercase 1E5 spelling rejected"
    (Canonical_json.Number_rejected
       "unsupported number (exponent notation): 1E5")
    (fun () -> Canonical_json.reject_unsupported_numbers {|{"x":1E5}|})

let test_plain_100_allowed () =
  Canonical_json.reject_unsupported_numbers {|{"x":100}|};
  (* 'e' inside a STRING literal is not a number token and must pass. *)
  Canonical_json.reject_unsupported_numbers {|{"note":"1e2 and \"1E5\""}|};
  (* 'e' inside true/false keywords must not trip the scanner. *)
  Canonical_json.reject_unsupported_numbers {|{"a":true,"b":false,"c":null}|}

(* Integer bound compares digit strings, never floats: 9007199254740993
   rounds to 9007199254740992.0 and would slip past a float compare. *)
let test_integer_beyond_2_53_rejected () =
  Alcotest.check_raises "2^53 + 1 rejected"
    (Canonical_json.Number_rejected
       "unsupported number (integer exceeds 2^53): 9007199254740993")
    (fun () ->
      Canonical_json.reject_unsupported_numbers {|{"x":9007199254740993}|});
  Alcotest.check_raises "-(2^53 + 1) rejected"
    (Canonical_json.Number_rejected
       "unsupported number (integer exceeds 2^53): -9007199254740993")
    (fun () ->
      Canonical_json.reject_unsupported_numbers {|{"x":-9007199254740993}|});
  (* 2^53 itself is the last representable integer and must pass. *)
  Canonical_json.reject_unsupported_numbers
    {|{"max_safe":9007199254740992,"neg":-9007199254740992}|}

let test_fraction_out_of_range_rejected () =
  Alcotest.check_raises "fraction below 1e-6 rejected"
    (Canonical_json.Number_rejected
       "unsupported number (fraction out of canonical range): 0.0000001")
    (fun () ->
      Canonical_json.reject_unsupported_numbers {|{"x":0.0000001}|});
  (* 1e-6 written plainly sits exactly on the boundary and must pass. *)
  Canonical_json.reject_unsupported_numbers {|{"x":0.000001}|};
  Canonical_json.reject_unsupported_numbers {|{"x":0.1,"y":123.456,"z":0.5}|}

(* Lone-surrogate enforcement is a LEXICAL pass over the raw text —
   yojson maps a lone \udc00 escape to U+FFFD by parse time, which is
   indistinguishable from a genuine U+FFFD in the input, so the
   unpaired spelling is only visible before parsing. *)
let test_lone_low_surrogate_rejected () =
  Alcotest.check_raises "lone low surrogate escape rejected"
    (Canonical_json.Lone_surrogate
       "unsupported unpaired surrogate escape in string")
    (fun () -> Canonical_json.check_no_lone_surrogates {|{"s":"\udc00"}|})

let test_lone_high_surrogate_rejected () =
  Alcotest.check_raises "lone high surrogate escape rejected"
    (Canonical_json.Lone_surrogate
       "unsupported unpaired surrogate escape in string")
    (fun () -> Canonical_json.check_no_lone_surrogates {|{"s":"\ud800"}|});
  (* Case-insensitive hex: uppercase spelling is the same code unit. *)
  Alcotest.check_raises "uppercase lone high surrogate escape rejected"
    (Canonical_json.Lone_surrogate
       "unsupported unpaired surrogate escape in string")
    (fun () -> Canonical_json.check_no_lone_surrogates {|{"s":"\uD800"}|})

let test_surrogate_pair_allowed () =
  (* A well-formed high+low escape pair (U+1F600, 😀) must pass: the
     high half consumes its immediately-following low half. *)
  Canonical_json.check_no_lone_surrogates {|{"s":"\ud83d\ude00"}|};
  (* Two pairs back-to-back: pair consumption must not skip past the
     start of the second pair. *)
  Canonical_json.check_no_lone_surrogates {|{"s":"\ud83d\ude00\ud83d\ude01"}|}

let test_literal_backslash_udc00_allowed () =
  (* \\udc00 is a LITERAL backslash followed by the text "udc00": the
     escape starts only on the odd trailing backslash of a run, so an
     even run pairs off into literal backslashes and must pass. *)
  Canonical_json.check_no_lone_surrogates {|{"s":"\\udc00"}|}

(* Shortest-roundtrip float formatting: 0.1 must canonicalize as "0.1",
   not the %.17g spelling "0.10000000000000001" (RFC 8785 §3.2.2.3 /
   ECMA-262 §7.1.12.1). *)
let test_shortest_roundtrip_floats () =
  let check label expected v =
    Alcotest.(check string)
      label expected
      (Canonical_json.canonicalize_json v)
  in
  check "0.1 shortest form" {|{"x":0.1}|} (`Assoc [ ("x", `Float 0.1) ]);
  check "123.456 shortest form" {|{"x":123.456}|}
    (`Assoc [ ("x", `Float 123.456) ]);
  check "0.5 unchanged" {|{"x":0.5}|} (`Assoc [ ("x", `Float 0.5) ]);
  check "negative fraction" {|{"x":-0.1}|} (`Assoc [ ("x", `Float (-0.1)) ]);
  check "boundary 1e-6 as plain decimal" {|{"x":0.000001}|}
    (`Assoc [ ("x", `Float 1e-6) ]);
  (* Any zero — including negative zero — emits exactly "0". *)
  check "negative zero is 0" {|{"x":0}|} (`Assoc [ ("x", `Float (-0.0)) ]);
  (* Integer-valued floats keep the existing no-".0" behavior. *)
  check "1.0 stays integer form" {|{"x":1}|} (`Assoc [ ("x", `Float 1.0) ])

let () =
  Alcotest.run "BAION Canonical JSON Conformance"
    [
      ( "canonical_json",
        [
          Alcotest.test_case "reference document" `Quick
            (check_document "reference_document");
          Alcotest.test_case "unicode document" `Quick
            (check_document "reference_document_unicode");
          Alcotest.test_case "edge-case document" `Quick
            (check_document "reference_document_edges");
        ] );
      ( "integer_valued_floats",
        [
          Alcotest.test_case "Test integer-valued floats" `Quick
            test_integer_valued_floats;
        ] );
      ( "nul_rejection",
        [
          Alcotest.test_case "U+0000 in string value rejected" `Quick
            test_nul_rejected_in_value;
          Alcotest.test_case "U+0000 in object key rejected" `Quick
            test_nul_rejected_in_key;
          Alcotest.test_case "literal backslash + u0000 text allowed" `Quick
            test_backslash_u0000_text_allowed;
        ] );
      ( "duplicate_key_rejection",
        [
          Alcotest.test_case "duplicate key at top level rejected" `Quick
            test_duplicate_key_top_level;
          Alcotest.test_case "duplicate key in nested object rejected" `Quick
            test_duplicate_key_nested;
          Alcotest.test_case "escaped spelling of same key rejected" `Quick
            test_duplicate_key_escaped;
          Alcotest.test_case "duplicate key inside array rejected" `Quick
            test_duplicate_key_in_array;
          Alcotest.test_case "distinct sibling keys allowed" `Quick
            test_distinct_keys_allowed;
          Alcotest.test_case "unique keys with array value allowed" `Quick
            test_no_duplicates_mixed_allowed;
        ] );
      ( "number_domain",
        [
          Alcotest.test_case "exponent notation rejected" `Quick
            test_exponent_notation_rejected;
          Alcotest.test_case "plain 100 and string/keyword 'e' allowed" `Quick
            test_plain_100_allowed;
          Alcotest.test_case "integer beyond 2^53 rejected" `Quick
            test_integer_beyond_2_53_rejected;
          Alcotest.test_case "fraction out of range rejected" `Quick
            test_fraction_out_of_range_rejected;
        ] );
      ( "lone_surrogate_rejection",
        [
          Alcotest.test_case "lone low surrogate escape rejected" `Quick
            test_lone_low_surrogate_rejected;
          Alcotest.test_case "lone high surrogate escape rejected" `Quick
            test_lone_high_surrogate_rejected;
          Alcotest.test_case "surrogate pair escapes allowed" `Quick
            test_surrogate_pair_allowed;
          Alcotest.test_case "literal backslash + udc00 text allowed" `Quick
            test_literal_backslash_udc00_allowed;
        ] );
      ( "float_formatting",
        [
          Alcotest.test_case "shortest-roundtrip float formatting" `Quick
            test_shortest_roundtrip_floats;
        ] );
      ( "hash",
        [
          Alcotest.test_case "SHA-256 reference vector" `Quick
            test_sha256_reference;
          Alcotest.test_case "SHA-256 FIPS vectors" `Quick test_sha256_hex;
          Alcotest.test_case "hash over canonical form" `Quick
            test_hash_over_canonical;
        ] );
    ]
