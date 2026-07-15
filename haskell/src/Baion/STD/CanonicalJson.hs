{-# LANGUAGE OverloadedStrings #-}

-- | BAION canonical JSON for Haskell — public standalone library.
-- Deterministic canonicalization of arbitrary JSON values
-- (RFC 8785-style: sorted object keys, minimal escapes, shortest
-- round-tripping number formatting).
module Baion.STD.CanonicalJson
  ( canonicalizeJson,
    canonicalizeJsonChecked,
    checkNoDuplicateKeys,
    writeJsonString,
  )
where

import qualified Data.Aeson as A
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens
  ( TkArray (..),
    TkRecord (..),
    Tokens (..),
  )
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as AKM
import qualified Data.ByteString as BS
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import qualified Data.Scientific as S
import qualified Data.Set as Set
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

-- | Reject any JSON object (at any depth) carrying duplicate member
-- names. This must scan the RAW input: aeson's KeyMap silently drops
-- duplicates at parse time, so the information is gone from 'A.Value'.
-- The aeson >= 2.2 token stream ('bsToTokens') surfaces every 'TkPair'
-- with its DECODED key ('AK.Key'), so escape-spelled duplicates like
-- {"a":1,"a":2} compare equal, as the contract requires.
-- Lexer errors ('TkErr' family) are deliberately NOT reported here —
-- the CLI decodes with aeson first, so a malformed input never reaches
-- this scan with an error message the decoder wouldn't own.
-- CROSS-LINEAGE CONTRACT: all 7 lineages reject duplicate keys
-- identically (Haskell previously kept-FIRST, the odd one of three
-- divergent behaviors).
checkNoDuplicateKeys :: BS.ByteString -> Either String ()
checkNoDuplicateKeys bs = case scanTokens (bsToTokens bs) of
  Left key ->
    Left
      ( "duplicate object key "
          ++ show (AK.toText key)
          ++ "; rejected by canonical-JSON contract"
      )
  Right _ -> Right ()
  where
    -- Left key = duplicate found (short-circuit); Right (Just k) =
    -- value consumed cleanly, continue with k; Right Nothing = lexer
    -- error, stop scanning (the decoder owns malformed-input errors).
    scanTokens :: Tokens k e -> Either AK.Key (Maybe k)
    scanTokens (TkLit _ k) = Right (Just k)
    scanTokens (TkText _ k) = Right (Just k)
    scanTokens (TkNumber _ k) = Right (Just k)
    scanTokens (TkArrayOpen a) = scanArray a
    scanTokens (TkRecordOpen r) = scanRecord Set.empty r
    scanTokens (TkErr _) = Right Nothing

    scanArray :: TkArray k e -> Either AK.Key (Maybe k)
    scanArray (TkItem t) = scanTokens t >>= maybe (Right Nothing) scanArray
    scanArray (TkArrayEnd k) = Right (Just k)
    scanArray (TkArrayErr _) = Right Nothing

    scanRecord :: Set.Set AK.Key -> TkRecord k e -> Either AK.Key (Maybe k)
    scanRecord seen (TkPair key t)
      | key `Set.member` seen = Left key
      | otherwise =
          scanTokens t
            >>= maybe (Right Nothing) (scanRecord (Set.insert key seen))
    scanRecord _ (TkRecordEnd k) = Right (Just k)
    scanRecord _ (TkRecordErr _) = Right Nothing

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
