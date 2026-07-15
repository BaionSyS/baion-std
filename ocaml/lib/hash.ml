(* BAION canonical JSON for OCaml — SHA-256 hex helper.
   Public standalone library. *)

(* CROSS-LINEAGE CONTRACT: identical UTF-8 input must produce identical
   hex output across all lineage libraries. SHA-256 is FIPS 180-4 (OCaml
   uses the digestif library; vendored or stdlib in other lineages). *)

(** Return SHA-256 lowercase hex string of the input bytes. *)
let sha256_hex (input : string) : string =
  let digest = Digestif.SHA256.digest_string input in
  Digestif.SHA256.to_hex digest
