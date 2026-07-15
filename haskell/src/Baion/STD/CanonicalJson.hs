{-# LANGUAGE OverloadedStrings #-}

-- | BAION canonical JSON for Haskell — public standalone library.
-- Deterministic canonicalization of arbitrary JSON values
-- (RFC 8785-style: sorted object keys, minimal escapes, shortest
-- round-tripping number formatting).
module Baion.STD.CanonicalJson
  ( canonicalizeJson,
    canonicalizeJsonChecked,
    writeJsonString,
  )
where

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as AKM
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import qualified Data.Scientific as S
import qualified Data.Text as T
import qualified Data.Vector as V
import Text.Printf (printf)

canonicalizeJson :: A.Value -> String
canonicalizeJson = canonicalizeValue

-- | Canonicalize with the cross-lineage U+0000 contract enforced:
-- any string (object key or string value, at any depth) containing
-- U+0000 (NUL) is rejected. aeson happily preserves NUL in 'T.Text',
-- so the walk must happen here — a NUL that reached the digest would
-- silently diverge from lineages whose string types are NUL-hostile.
-- CROSS-LINEAGE CONTRACT: all 7 lineages reject U+0000 identically.
canonicalizeJsonChecked :: A.Value -> Either String String
canonicalizeJsonChecked v
  | containsNul v =
      Left "input contains U+0000 (NUL) in a string; rejected by canonical-JSON contract"
  | otherwise = Right (canonicalizeValue v)

-- | Recursive walk: does any string (key or value) contain U+0000?
containsNul :: A.Value -> Bool
containsNul (A.String t) = T.any (== '\NUL') t
containsNul (A.Array arr) = V.any containsNul arr
containsNul (A.Object obj) =
  any
    (\(k, val) -> T.any (== '\NUL') (AK.toText k) || containsNul val)
    (AKM.toList obj)
containsNul _ = False

canonicalizeValue :: A.Value -> String
canonicalizeValue A.Null = "null"
canonicalizeValue (A.Bool True) = "true"
canonicalizeValue (A.Bool False) = "false"
canonicalizeValue (A.Number n)
  | S.isInteger n = case S.floatingOrInteger n of
      Right i -> show (i :: Integer)
      Left d -> showDouble d
  | otherwise = showDouble (S.toRealFloat n)
canonicalizeValue (A.String t) = writeJsonString (T.unpack t)
canonicalizeValue (A.Array arr) =
  "[" ++ commaJoin (map canonicalizeValue (V.toList arr)) ++ "]"
canonicalizeValue (A.Object obj) =
  let sorted =
        Map.toAscList
          ( Map.fromList
              [(AK.toText k, v) | (k, v) <- AKM.toList obj]
          )
   in "{"
        ++ commaJoin
          [ writeJsonString (T.unpack k) ++ ":" ++ canonicalizeValue v
          | (k, v) <- sorted
          ]
        ++ "}"

-- | Show a Double in canonical-JSON form per RFC 8785 / ECMA-262
-- §7.1.12.1. Integer-valued doubles emit without trailing decimal.
-- Fractional doubles use the shortest precision that round-trips
-- exactly (mirrors the D lineage's formatShortest's %g shortest-search loop;
-- prevents printf "%.17g" from padding 1.5 → "1.50000000000000000",
-- which was the pre-2026-05-04 Haskell divergence).
showDouble :: Double -> String
showDouble d
  | isNaN d || isInfinite d = "null"
  | d == fromInteger (round d) && abs d < 1e15 =
      show (round d :: Integer)
  | otherwise = shortestRoundTrip d

-- | Search for the smallest precision whose %g formatting round-trips
-- back to the original Double. CROSS-LINEAGE CONTRACT: behavior must
-- match formatShortest in `d/source/baionstd/canonical_json.d`.
shortestRoundTrip :: Double -> String
shortestRoundTrip d = go (1 :: Int)
  where
    go p
      | p > 17 = printf "%.17g" d -- fallback (unreachable for finite IEEE-754)
      | (readMaybe (printf "%.*g" p d) :: Maybe Double) == Just d =
          printf "%.*g" p d
      | otherwise = go (p + 1)
    readMaybe s = case reads s of
      [(x, "")] -> Just x
      _ -> Nothing

commaJoin :: [String] -> String
commaJoin [] = ""
commaJoin [x] = x
commaJoin (x : xs) = x ++ "," ++ commaJoin xs

writeJsonString :: String -> String
writeJsonString s = "\"" ++ concatMap escapeChar s ++ "\""
  where
    escapeChar '"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\b' = "\\b"
    escapeChar '\f' = "\\f"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c
      | ord c < 0x20 = printf "\\u%04x" (ord c)
      | otherwise = [c]
