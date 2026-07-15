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
      ( "hash",
        [
          Alcotest.test_case "SHA-256 reference vector" `Quick
            test_sha256_reference;
          Alcotest.test_case "SHA-256 FIPS vectors" `Quick test_sha256_hex;
          Alcotest.test_case "hash over canonical form" `Quick
            test_hash_over_canonical;
        ] );
    ]
