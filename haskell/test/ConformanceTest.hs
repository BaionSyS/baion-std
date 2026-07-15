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
      testCase "Test 5: integer-valued floats" testIntegerValuedFloats
    ]

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
