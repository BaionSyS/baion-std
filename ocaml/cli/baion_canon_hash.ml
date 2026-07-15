(* BAION canon-hash CLI for OCaml — public standalone tool.
   Reads UTF-8 JSON on stdin, prints lowercase SHA-256 hex of the
   canonical bytes on stdout. Parse failure -> stderr + exit 1.
   Contract matches the other lineages' CLIs byte-for-byte. *)

let () =
  let input = In_channel.input_all In_channel.stdin in
  match Yojson.Safe.from_string input with
  | exception Yojson.Json_error msg ->
      prerr_endline ("baion_canon_hash: JSON parse error: " ^ msg);
      exit 1
  | json ->
      let canonical = Baionstd_public.Canonical_json.canonicalize_json json in
      print_endline (Baionstd_public.Hash.sha256_hex canonical)
