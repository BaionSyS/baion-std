(* BAION canon-hash CLI for OCaml — public standalone tool.
   Reads UTF-8 JSON on stdin, prints lowercase SHA-256 hex of the
   canonical bytes on stdout. Parse failure, U+0000 anywhere in the
   input's strings, or a duplicate object key at any depth -> stderr +
   exit 1.
   Contract matches the other lineages' CLIs byte-for-byte. *)

let () =
  let input = In_channel.input_all In_channel.stdin in
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
