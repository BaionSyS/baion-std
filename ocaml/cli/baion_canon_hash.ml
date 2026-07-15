(* BAION canon-hash CLI for OCaml — public standalone tool.
   Reads UTF-8 JSON on stdin, prints lowercase SHA-256 hex of the
   canonical bytes on stdout. Parse failure, U+0000 anywhere in the
   input's strings, or a duplicate object key at any depth -> stderr +
   exit 1.
   Contract matches the other lineages' CLIs byte-for-byte. *)

let () =
  let input = In_channel.input_all In_channel.stdin in
  (* UTF-8 well-formedness runs first, on the RAW bytes: yojson passes
     invalid byte sequences through string literals verbatim, and every
     later pass assumes it is walking sound UTF-8. *)
  (match Baionstd_public.Canonical_json.check_utf8 input with
  | exception Baionstd_public.Canonical_json.Invalid_utf8 msg ->
      prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
      exit 1
  | () -> ());
  (* Strict token grammar runs on the RAW bytes before parsing: yojson
     accepts unquoted object keys, comments, and NaN/Infinity literals,
     none of which are recoverable after parse. *)
  (match Baionstd_public.Canonical_json.check_strict_tokens input with
  | exception Baionstd_public.Canonical_json.Nonstandard_token msg ->
      prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
      exit 1
  | () -> ());
  (* Raw-control-byte enforcement runs on the RAW bytes before parsing:
     yojson accepts an unescaped 0x01-0x1F byte inside a string literal,
     and by parse time it is indistinguishable from the escaped form. *)
  (match Baionstd_public.Canonical_json.check_no_raw_control_chars input with
  | exception Baionstd_public.Canonical_json.Control_char_rejected msg ->
      prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
      exit 1
  | () -> ());
  (* Number-domain enforcement runs on the RAW bytes before parsing:
     yojson normalizes 1e2 to the same value as 100, so exponent
     spelling is only visible lexically. *)
  (match Baionstd_public.Canonical_json.reject_unsupported_numbers input with
  | exception Baionstd_public.Canonical_json.Number_rejected msg ->
      prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
      exit 1
  | () -> ());
  (* Lone-surrogate enforcement also runs on the RAW bytes: yojson maps
     a lone backslash-udc00 escape to U+FFFD by parse time, so the
     unpaired spelling is only visible lexically. *)
  (match Baionstd_public.Canonical_json.check_no_lone_surrogates input with
  | exception Baionstd_public.Canonical_json.Lone_surrogate msg ->
      prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
      exit 1
  | () -> ());
  match Yojson.Safe.from_string input with
  | exception Yojson.Json_error msg ->
      prerr_endline ("baion_canon_hash: JSON parse error: " ^ msg);
      exit 1
  | json -> begin
      match Baionstd_public.Canonical_json.canonicalize_json json with
      | exception Baionstd_public.Canonical_json.Nul_rejected msg ->
          prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
          exit 1
      | exception Baionstd_public.Canonical_json.Duplicate_key msg ->
          prerr_endline ("baion_canon_hash: invalid input: " ^ msg);
          exit 1
      | canonical -> print_endline (Baionstd_public.Hash.sha256_hex canonical)
    end
