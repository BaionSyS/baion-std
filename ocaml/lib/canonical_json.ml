(* BAION canonical JSON for OCaml — public standalone library.

   Generic canonical-form serializer: sorted keys, no whitespace,
   minimal string escaping (RFC 8785 style).

   CAUTION: yojson's Assoc preserves insertion order but does NOT
   guarantee sorted keys. We sort keys before serialization. *)

(** Raised when an input contains U+0000 in any string (key or value). *)
exception Nul_rejected of string

(* CROSS-LINEAGE CONTRACT: any input whose strings (object keys or string
   values, at any depth) contain U+0000 must be rejected by all seven
   lineage libraries. yojson preserves NUL inside parsed OCaml strings
   (both from a raw 0x00 byte and from a backslash-u0000 escape), so we walk the
   parsed value explicitly rather than relying on the parser to refuse it. *)
let rec reject_nul (v : Yojson.Safe.t) =
  match v with
  | `String s when String.contains s '\000' ->
      raise (Nul_rejected "string value contains U+0000")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> ()
  | `List items -> List.iter reject_nul items
  | `Assoc pairs ->
      List.iter
        (fun (k, item) ->
          if String.contains k '\000' then
            raise (Nul_rejected "object key contains U+0000");
          reject_nul item)
        pairs

(** Raised when an object carries the same member name twice (any depth). *)
exception Duplicate_key of string

(** Raised when the raw input carries a number outside the canonical
    domain: exponent notation, an integer beyond 2^53, or a fraction
    outside [1e-6, 1e21). *)
exception Number_rejected of string

(* 2^53 — the largest integer every lineage can represent exactly. *)
let max_safe_integer_digits = "9007199254740992"

(* Reject one raw number token. Integer comparison is done on the digit
   string (never through a float) because 9007199254740993 rounds to
   9007199254740992.0 and would slip past a float compare. *)
let check_number_token tok =
  if String.exists (fun c -> c = 'e' || c = 'E') tok then
    raise
      (Number_rejected ("unsupported number (exponent notation): " ^ tok))
  else if String.contains tok '.' then (
    match float_of_string_opt tok with
    | None -> () (* malformed token: leave it to the JSON parser's error *)
    | Some v ->
        let a = Float.abs v in
        if (v <> 0. && a < 1e-6) || a >= 1e21 then
          raise
            (Number_rejected
               ("unsupported number (fraction out of canonical range): "
              ^ tok)))
  else
    let digits =
      if tok.[0] = '-' then String.sub tok 1 (String.length tok - 1) else tok
    in
    (* JSON forbids leading zeros, but strip them defensively so a
       malformed "0009" never inflates the length compare below. *)
    let digits =
      let dl = String.length digits in
      let j = ref 0 in
      while !j < dl - 1 && digits.[!j] = '0' do
        incr j
      done;
      String.sub digits !j (dl - !j)
    in
    let dl = String.length digits in
    let ml = String.length max_safe_integer_digits in
    if dl > ml || (dl = ml && String.compare digits max_safe_integer_digits > 0)
    then
      raise
        (Number_rejected ("unsupported number (integer exceeds 2^53): " ^ tok))

(* CROSS-LINEAGE CONTRACT: number-domain enforcement is a LEXICAL pass
   over the raw input text. yojson parses 1e2 and 100 to the same value,
   so by parse time the exponent spelling is unrecoverable — the scan
   must happen on the bytes. Same skip-strings technique as the D
   lineage's hasDuplicateKeys: walk the raw text, skip string literals
   (honoring backslash escapes so an escaped quote never ends the
   string early), and inspect every number token. 'e' inside true/false
   never trips this because tokens only start at a digit or '-'. *)
let reject_unsupported_numbers (raw : string) : unit =
  let len = String.length raw in
  let i = ref 0 in
  while !i < len do
    let c = raw.[!i] in
    if c = '"' then begin
      incr i;
      let closed = ref false in
      while (not !closed) && !i < len do
        match raw.[!i] with
        | '\\' -> i := !i + 2
        | '"' ->
            closed := true;
            incr i
        | _ -> incr i
      done
    end
    else if c = '-' || (c >= '0' && c <= '9') then begin
      let start = !i in
      while
        !i < len
        &&
        match raw.[!i] with
        | '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true
        | _ -> false
      do
        incr i
      done;
      check_number_token (String.sub raw start (!i - start))
    end
    else incr i
  done

(** Raised when the raw input carries an unpaired UTF-16 surrogate escape. *)
exception Lone_surrogate of string

(* Parse four hex digits at raw.[pos..pos+3] as a UTF-16 code unit.
   Returns None on truncation or a non-hex digit — a malformed \u escape
   is the JSON parser's error to report, not ours. *)
let hex4 raw pos =
  let len = String.length raw in
  if pos + 4 > len then None
  else
    let v = ref 0 in
    let ok = ref true in
    for k = pos to pos + 3 do
      let d =
        match raw.[k] with
        | '0' .. '9' as c -> Char.code c - Char.code '0'
        | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
        | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
        | _ ->
            ok := false;
            0
      in
      v := (!v * 16) + d
    done;
    if !ok then Some !v else None

(* CROSS-LINEAGE CONTRACT: unpaired UTF-16 surrogate escapes must be
   rejected by all seven lineage libraries. This is a LEXICAL pass over
   the raw input (mirrors Go's CheckNoLoneSurrogates): yojson maps a
   lone \udc00 to U+FFFD by parse time, indistinguishable from a
   genuine U+FFFD in the input, so the scan must happen on the bytes.
   (The lone HIGH half \ud800 yojson already refuses at parse; the
   lone LOW half is the gap this closes.)

   Backslash-run parity decides whether a \u is an ACTIVE escape: an
   escape starts only on the odd trailing backslash of a run, so
   \\udc00 (a literal backslash + the text "udc00") is not a surrogate
   and passes. Escapes only occur inside strings in well-formed JSON;
   a stray backslash elsewhere is a syntax error the parse pass rejects
   anyway, so scanning the whole input is safe. *)
let check_no_lone_surrogates (raw : string) : unit =
  let len = String.length raw in
  let i = ref 0 in
  while !i < len do
    if raw.[!i] <> '\\' then incr i
    else begin
      let j = ref !i in
      while !j < len && raw.[!j] = '\\' do
        incr j
      done;
      let run = !j - !i in
      i := !j;
      if run mod 2 = 1 then
        if !j < len && raw.[!j] = 'u' then begin
          match hex4 raw (!j + 1) with
          | None -> i := !j + 1 (* malformed escape: parser reports it *)
          | Some cp when cp >= 0xD800 && cp <= 0xDBFF ->
              (* High surrogate: valid only when immediately followed by
                 an escaped low surrogate; consume the pair so its low
                 half is never re-seen as lone. *)
              let paired =
                !j + 11 <= len
                && raw.[!j + 5] = '\\'
                && raw.[!j + 6] = 'u'
                &&
                match hex4 raw (!j + 7) with
                | Some lo -> lo >= 0xDC00 && lo <= 0xDFFF
                | None -> false
              in
              if not paired then
                raise
                  (Lone_surrogate
                     "unsupported unpaired surrogate escape in string");
              i := !j + 11
          | Some cp when cp >= 0xDC00 && cp <= 0xDFFF ->
              (* Low surrogate reached without a consuming high half. *)
              raise
                (Lone_surrogate
                   "unsupported unpaired surrogate escape in string")
          | Some _ -> i := !j + 5
        end
        else i := !j + 1
    end
  done

(* CROSS-LINEAGE CONTRACT: objects with duplicate member names (at any
   depth) must be rejected by all seven lineage libraries. yojson's
   Assoc is a plain pair list that preserves EVERY member — including
   repeats — and decodes backslash-u escapes into the key string before
   we see it, so a plain String.compare on parsed keys catches both the
   literal and the escaped spelling of the same name. We sort a copy of
   the key list and scan adjacent entries rather than trusting the
   parser (which never refuses duplicates). *)
let rec reject_duplicate_keys (v : Yojson.Safe.t) =
  match v with
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> ()
  | `List items -> List.iter reject_duplicate_keys items
  | `Assoc pairs ->
      let keys = List.sort String.compare (List.map fst pairs) in
      let rec scan = function
        | a :: (b :: _ as rest) ->
            if String.equal a b then
              raise (Duplicate_key ("duplicate object key: " ^ a));
            scan rest
        | _ -> ()
      in
      scan keys;
      List.iter (fun (_, item) -> reject_duplicate_keys item) pairs

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

(* ECMAScript-style shortest-roundtrip float formatting (RFC 8785
   §3.2.2.3 / ECMA-262 §7.1.12.1) for finite, non-integer-valued floats.
   CROSS-LINEAGE CONTRACT: 0.1 must serialize as "0.1", not the %.17g
   spelling "0.10000000000000001" — every lineage emits the SHORTEST
   digit string that round-trips to the same IEEE 754 double.

   Shortest digits: the first precision p in 0..16 whose %.*e output
   parses back to the exact value. Reassembly is always plain decimal —
   the number-domain guard restricts fractions to |v| in [1e-6, 1e21),
   so ECMA's exponent-notation branch is unreachable here. *)
let format_shortest_float f =
  if f = 0. then "0" (* covers -0.0: canonical form is exactly "0" *)
  else
    let a = Float.abs f in
    let rec shortest p =
      if p > 16 then Printf.sprintf "%.17e" a
      else
        let s = Printf.sprintf "%.*e" p a in
        if float_of_string s = a then s else shortest (p + 1)
    in
    let s = shortest 0 in
    let epos = String.index s 'e' in
    let mantissa = String.sub s 0 epos in
    let exp =
      int_of_string (String.sub s (epos + 1) (String.length s - epos - 1))
    in
    let digits = String.concat "" (String.split_on_char '.' mantissa) in
    (* Minimal p never ends in '0' (a shorter p would round-trip too),
       but strip defensively so a stray zero can't shift the layout. *)
    let digits =
      let l = ref (String.length digits) in
      while !l > 1 && digits.[!l - 1] = '0' do
        decr l
      done;
      String.sub digits 0 !l
    in
    let k = String.length digits in
    let n = exp + 1 in
    let body =
      if n >= k then digits ^ String.make (n - k) '0'
      else if n > 0 then
        String.sub digits 0 n ^ "." ^ String.sub digits n (k - n)
      else "0." ^ String.make (-n) '0' ^ digits
    in
    if f < 0. then "-" ^ body else body

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
      else Buffer.add_string buf (format_shortest_float f)
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
    lexicographically at every nesting level, no whitespace.
    @raise Nul_rejected if any string (key or value) contains U+0000.
    @raise Duplicate_key if any object repeats a member name. *)
let canonicalize_json (v : Yojson.Safe.t) : string =
  reject_nul v;
  reject_duplicate_keys v;
  let buf = Buffer.create 256 in
  canonicalize_value buf v;
  Buffer.contents buf
