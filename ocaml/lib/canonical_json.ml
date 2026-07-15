(* BAION canonical JSON for OCaml — public standalone library.

   Generic canonical-form serializer: sorted keys, no whitespace,
   minimal string escaping (RFC 8785 style).

   CAUTION: yojson's Assoc preserves insertion order but does NOT
   guarantee sorted keys. We sort keys before serialization. *)

(* Write a JSON-quoted string with minimal escaping (RFC 8785 §3.2.2.2).
   Only escapes: quotes, backslash, and control chars 0x00-0x1F.
   Forward slash is NOT escaped. *)
let write_json_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\x08' -> Buffer.add_string buf "\\b" (* backspace *)
      | '\x0C' -> Buffer.add_string buf "\\f" (* form feed *)
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

(** Recursively write a JSON value in canonical form. *)
let rec canonicalize_value buf (v : Yojson.Safe.t) =
  match v with
  | `Null -> Buffer.add_string buf "null"
  | `Bool true -> Buffer.add_string buf "true"
  | `Bool false -> Buffer.add_string buf "false"
  | `Int i -> Buffer.add_string buf (string_of_int i)
  | `Intlit s -> Buffer.add_string buf s
  | `Float f ->
      if Float.is_nan f || Float.is_infinite f then Buffer.add_string buf "null"
      else if f = Float.round f && Float.abs f < 1e15 then
        (* CROSS-LINEAGE CONTRACT: integer-valued floats serialize without
           trailing decimal (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1). All
           lineage libraries emit 1.0 → "1", -3.0 → "-3", 1.5 → "1.5";
           disagreement on this branch breaks SHA-256 digest parity. *)
        Buffer.add_string buf (Int64.to_string (Int64.of_float f))
      else Buffer.add_string buf (Printf.sprintf "%.17g" f)
  | `String s -> write_json_string buf s
  | `List items ->
      Buffer.add_char buf '[';
      List.iteri
        (fun i item ->
          if i > 0 then Buffer.add_char buf ',';
          canonicalize_value buf item)
        items;
      Buffer.add_char buf ']'
  | `Assoc pairs ->
      (* CRITICAL: sort keys lexicographically *)
      let sorted =
        List.sort (fun (k1, _) (k2, _) -> String.compare k1 k2) pairs
      in
      Buffer.add_char buf '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char buf ',';
          write_json_string buf k;
          Buffer.add_char buf ':';
          canonicalize_value buf v)
        sorted;
      Buffer.add_char buf '}'

(** Canonicalize any JSON value to a canonical string. Keys sorted
    lexicographically at every nesting level, no whitespace. *)
let canonicalize_json (v : Yojson.Safe.t) : string =
  let buf = Buffer.create 256 in
  canonicalize_value buf v;
  Buffer.contents buf
