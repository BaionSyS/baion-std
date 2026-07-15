{-# LANGUAGE OverloadedStrings #-}

-- | BAION canonical JSON for Haskell — public standalone library.
-- Conformance tests: canonical JSON output + SHA-256 digests against
-- the shared cross-implementation reference fixture.
module ConformanceTest (conformanceTests) where

import Baion.STD
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as AKM
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Tasty
import Test.Tasty.HUnit

-- Shared cross-implementation fixture lives one level above this dir
-- (baion-std/conformance_reference.json); the local fallback keeps the
-- suite runnable if this dir is checked out alone.
fixturePaths :: [FilePath]
fixturePaths =
  [ "../conformance_reference.json",
    "test/fixtures/conformance_reference.json"
  ]

loadReference :: IO A.Value
loadReference = do
  path <- firstExisting fixturePaths
  content <- BSC.readFile path
  case A.eitherDecodeStrict' content of
    Left err -> error ("Failed to parse reference: " ++ err)
    Right v -> return v
  where
    firstExisting [] = error "conformance_reference.json not found"
    firstExisting (p : ps) = do
      ok <- doesFileExist p
      if ok then return p else firstExisting ps

getStr :: A.Value -> String -> String
getStr (A.Object obj) key = case AKM.lookup (AK.fromText (T.pack key)) obj of
  Just (A.String t) -> T.unpack t
  _ -> error ("missing key: " ++ key)
getStr _ _ = error "not an object"

getVal :: A.Value -> String -> A.Value
getVal (A.Object obj) key = case AKM.lookup (AK.fromText (T.pack key)) obj of
  Just v -> v
  Nothing -> error ("missing key: " ++ key)
getVal _ _ = error "not an object"

-- Digest the canonical string's UTF-8 bytes — sha256Hex packs Char8
-- and would truncate non-ASCII canonical output to Latin-1.
canonicalSha256Hex :: String -> String
canonicalSha256Hex = sha256HexBytes . TE.encodeUtf8 . T.pack

-- Canonicalize a named fixture document and check both the canonical
-- JSON string and the SHA-256 hex of its UTF-8 bytes.
checkDocument :: String -> Assertion
checkDocument key = do
  ref_ <- loadReference
  let canonical = canonicalizeJson (getVal ref_ key)
  canonical @?= getStr ref_ (key ++ "_canonical_json")
  canonicalSha256Hex canonical @?= getStr ref_ (key ++ "_sha256_hex")

conformanceTests :: TestTree
conformanceTests =
  testGroup
    "Conformance"
    [ testCase "Test 1: reference document canonical JSON + SHA-256" $
        checkDocument "reference_document",
      testCase "Test 2: unicode document canonical JSON + SHA-256" $
        checkDocument "reference_document_unicode",
      testCase "Test 3: edge-case document canonical JSON + SHA-256" $
        checkDocument "reference_document_edges",
      testCase "Test 4: plain SHA-256 vector" testSha256Vector,
      testCase "Test 5: integer-valued floats" testIntegerValuedFloats,
      testCase "Test 6: U+0000 in string value rejected" testNulValueRejected,
      testCase "Test 7: U+0000 in object key rejected" testNulKeyRejected,
      testCase "Test 8: literal backslash-u0000 text allowed" testEscapedNulTextAllowed,
      testCase "Test 9: duplicate key at top level rejected" $
        assertDuplicateRejected "{\"a\":1,\"a\":2}",
      testCase "Test 10: duplicate key in nested object rejected" $
        assertDuplicateRejected "{\"x\":{\"b\":1,\"b\":2}}",
      testCase "Test 11: escape-spelled duplicate key rejected" $
        assertDuplicateRejected "{\"a\":1,\"\\u0061\":2}",
      testCase "Test 12: duplicate key in object-in-array rejected" $
        assertDuplicateRejected "[{\"k\":1,\"k\":2}]",
      testCase "Test 13: distinct keys sharing a prefix accepted" $
        assertNoDuplicate "{\"aa\":1,\"ab\":2}",
      testCase "Test 14: repeated array values are not duplicate keys" $
        assertNoDuplicate "{\"b\":1,\"a\":[1,2]}",
      testCase "Test 15: strict decode rejects trailing garbage" $
        assertDecodeRejected "{\"a\":1} x",
      testCase "Test 16: strict decode rejects a second document" $
        assertDecodeRejected "{\"a\":1}{\"b\":2}",
      testCase "Test 17: strict decode rejects a trailing comma" $
        assertDecodeRejected "{\"a\":1,}",
      testCase "Test 18: strict decode rejects empty input" $
        assertDecodeRejected "",
      testCase "Test 19: strict decode allows trailing whitespace" $
        assertDecodeAccepted "{\"a\":1} \n\t",
      testCase "Test 20: exponent-spelled number rejected (1E2 vs 100)" $ do
        assertNumberRejected "{\"x\":1E2}"
        assertNumberRejected "{\"x\":1e5}"
        assertNumberAccepted "{\"x\":100}",
      testCase "Test 21: exponent spelling rejected regardless of value" $ do
        assertNumberRejected "{\"x\":1e21}"
        assertNumberRejected "{\"x\":1e-7}"
        assertNumberRejected "{\"x\":1e400}",
      testCase "Test 22: integer beyond +9007199254740992 rejected" $ do
        assertNumberRejected "{\"x\":9007199254740993}"
        assertNumberAccepted "{\"x\":9007199254740992}",
      testCase "Test 23: integer beyond -9007199254740992 rejected" $ do
        assertNumberRejected "{\"x\":-9007199254740993}"
        assertNumberAccepted "{\"x\":-9007199254740992}",
      testCase "Test 24: fraction below 1e-6 rejected, boundary kept" $ do
        assertNumberRejected "{\"x\":0.0000001}"
        assertNumberAccepted "{\"x\":0.000001}"
        assertNumberAccepted "{\"x\":0.1}"
        assertNumberAccepted "{\"x\":-0.0}",
      testCase "Test 25: exponent-like spellings inside strings pass" $ do
        assertNumberAccepted "{\"x\":\"1e21\"}"
        assertNumberAccepted "{\"x\":\"a\\\"1E5\",\"y\":100}",
      testCase "Test 26: sub-0.01 fractions emit plain decimal, never exponent" $ do
        assertCanonicalizes "{\"x\":0.001}" "{\"x\":0.001}"
        assertCanonicalizes "{\"x\":0.0001}" "{\"x\":0.0001}"
        assertCanonicalizes "{\"x\":0.000123}" "{\"x\":0.000123}"
        assertCanonicalizes "{\"x\":0.00001}" "{\"x\":0.00001}"
        assertCanonicalizes "{\"x\":0.000001}" "{\"x\":0.000001}",
      testCase "Test 27: fraction near 1e21 collapses to 21-digit integer via double" $
        assertCanonicalizes
          "{\"x\":100000000000000000000.5}"
          "{\"x\":100000000000000000000}",
      testCase "Test 28: integer tokens keep plain-integer printing" $ do
        assertCanonicalizes "{\"x\":9007199254740992}" "{\"x\":9007199254740992}"
        assertCanonicalizes "{\"x\":-42}" "{\"x\":-42}"
        assertCanonicalizes "{\"x\":0}" "{\"x\":0}",
      testCase "Test 29: signed zero and mid-range fractions unchanged" $ do
        assertCanonicalizes "{\"x\":-0.0}" "{\"x\":0}"
        assertCanonicalizes "{\"x\":-0.375}" "{\"x\":-0.375}"
        assertCanonicalizes "{\"x\":0.1}" "{\"x\":0.1}"
        assertCanonicalizes "{\"x\":123.456}" "{\"x\":123.456}"
        assertCanonicalizes "{\"x\":1.5}" "{\"x\":1.5}"
        assertCanonicalizes "{\"x\":1.0}" "{\"x\":1}"
    ]

-- STRICT single-document contract (tests 15-19): aeson >= 2.2's
-- eitherDecodeStrict' must consume the whole input as exactly one
-- JSON document (trailing whitespace only). Pinned here so an aeson
-- upgrade cannot silently relax the CLI's parse discipline.
assertDecodeRejected :: String -> Assertion
assertDecodeRejected raw =
  case A.eitherDecodeStrict' (BSC.pack raw) :: Either String A.Value of
    Left _ -> return ()
    Right v ->
      assertFailure
        ("expected strict-decode rejection for " ++ show raw ++ ", got: " ++ show v)

assertDecodeAccepted :: String -> Assertion
assertDecodeAccepted raw =
  case A.eitherDecodeStrict' (BSC.pack raw) :: Either String A.Value of
    Left err -> assertFailure ("expected acceptance for " ++ show raw ++ ", got: " ++ err)
    Right _ -> return ()

-- Number rendering contract (tests 26-29): canonical output must be
-- ECMAScript-ToString plain decimal over DOUBLE semantics, matching
-- the C/Go/OCaml reference lineages byte-for-byte. Sub-0.01 fractions
-- are where the old %g formatter drifted into exponent notation.
assertCanonicalizes :: String -> String -> Assertion
assertCanonicalizes raw expected =
  case A.eitherDecodeStrict' (BSC.pack raw) :: Either String A.Value of
    Left err -> assertFailure ("fixture must parse: " ++ err)
    Right v -> canonicalizeJson v @?= expected

-- Number-domain contract (tests 20-25): lexical check over raw bytes,
-- error text must carry both "unsupported" and "number" so pipeline
-- greps can classify the failure.
assertNumberRejected :: String -> Assertion
assertNumberRejected raw =
  case checkNumberDomain (BSC.pack raw) of
    Left err ->
      assertBool
        ("error message must mention unsupported number, got: " ++ err)
        ( T.isInfixOf "unsupported" (T.pack err)
            && T.isInfixOf "number" (T.pack err)
        )
    Right () ->
      assertFailure ("expected number-domain rejection for: " ++ raw)

assertNumberAccepted :: String -> Assertion
assertNumberAccepted raw =
  case checkNumberDomain (BSC.pack raw) of
    Left err -> assertFailure ("expected acceptance for " ++ raw ++ ", got: " ++ err)
    Right () -> return ()

testSha256Vector :: Assertion
testSha256Vector = do
  ref_ <- loadReference
  let input = getStr ref_ "reference_sha256_input"
  sha256Hex input @?= getStr ref_ "reference_sha256_hex"

-- Integer-valued floats canonicalize without trailing decimal
-- (fixed 2026-05-04: earlier float formatting diverged from RFC 8785).
-- Build the value with explicit numeric
-- (Scientific) values; canonicalizeJson must strip ".0" from integer-valued
-- Scientifics per RFC 8785 / ECMA-262.
testIntegerValuedFloats :: Assertion
testIntegerValuedFloats = do
  ref_ <- loadReference
  let v =
        A.object
          [ ("frac", A.Number 1.5),
            ("neg", A.Number (-7.0)),
            ("vals", A.Array (mconcat [pure (A.Number 1.0), pure (A.Number 2.0), pure (A.Number 3.0)]))
          ]
  let canonical = canonicalizeJson v
  let expected = getStr ref_ "reference_integer_valued_floats_canonical_json"
  canonical @?= expected

-- U+0000 contract (CROSS-LINEAGE): any string — key or value, any
-- depth — containing NUL is rejected by checked canonicalization.
-- aeson decodes the six-char JSON escape "\\u0000" to a real NUL in
-- Text, so the rejection walk in the library is the only guard.
isRejectedForNul :: Either String String -> Assertion
isRejectedForNul (Left err) =
  assertBool
    ("error message must mention U+0000, got: " ++ err)
    (T.isInfixOf "U+0000" (T.pack err))
isRejectedForNul (Right c) =
  assertFailure ("expected U+0000 rejection, canonicalized to: " ++ c)

testNulValueRejected :: Assertion
testNulValueRejected =
  case A.eitherDecodeStrict' (BSC.pack "{\"x\":\"a\\u0000b\"}") of
    Left err -> assertFailure ("fixture must parse: " ++ err)
    Right v -> isRejectedForNul (canonicalizeJsonChecked v)

testNulKeyRejected :: Assertion
testNulKeyRejected =
  case A.eitherDecodeStrict' (BSC.pack "{\"a\\u0000\":1}") of
    Left err -> assertFailure ("fixture must parse: " ++ err)
    Right v -> isRejectedForNul (canonicalizeJsonChecked v)

-- Duplicate-key contract (CROSS-LINEAGE): objects with duplicate
-- member names — any depth, compared by DECODED key text so the
-- escape spelling backslash-u0061 collides with "a" — are rejected.
-- The check runs on the
-- RAW bytes because aeson's KeyMap has already dropped the duplicate
-- by the time a Value exists.
assertDuplicateRejected :: String -> Assertion
assertDuplicateRejected raw =
  case checkNoDuplicateKeys (BSC.pack raw) of
    Left err ->
      assertBool
        ("error message must mention duplicate key, got: " ++ err)
        ( T.isInfixOf "duplicate" (T.pack err)
            && T.isInfixOf "key" (T.pack err)
        )
    Right () ->
      assertFailure ("expected duplicate-key rejection for: " ++ raw)

assertNoDuplicate :: String -> Assertion
assertNoDuplicate raw =
  case checkNoDuplicateKeys (BSC.pack raw) of
    Left err -> assertFailure ("expected acceptance, got: " ++ err)
    Right () -> return ()

-- Literal backslash + "u0000" text (JSON source "a\\\\u0000b") decodes
-- to a backslash character, not a NUL — it must pass unchanged.
testEscapedNulTextAllowed :: Assertion
testEscapedNulTextAllowed =
  case A.eitherDecodeStrict' (BSC.pack "{\"x\":\"a\\\\u0000b\"}") of
    Left err -> assertFailure ("fixture must parse: " ++ err)
    Right v ->
      canonicalizeJsonChecked v @?= Right "{\"x\":\"a\\\\u0000b\"}"
