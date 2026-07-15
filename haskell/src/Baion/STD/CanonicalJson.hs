{-# LANGUAGE OverloadedStrings #-}

-- | BAION canonical JSON for Haskell — public standalone library.
-- Deterministic canonicalization of arbitrary JSON values
-- (RFC 8785-style: sorted object keys, minimal escapes, ECMAScript
-- ToString plain-decimal number formatting over double semantics).
module Baion.STD.CanonicalJson
  ( canonicalizeJson,
    canonicalizeJsonChecked,
    checkNoDuplicateKeys,
    checkNumberDomain,
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
import Data.Char (intToDigit, ord)
import qualified Data.Map.Strict as Map
import qualified Data.Scientific as S
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Vector as V
import Numeric (floatToDigits)
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

-- | Reject number tokens outside the cross-lineage number domain.
-- This must scan the RAW input: aeson decodes every number spelling
-- into 'S.Scientific', so by the time a 'A.Value' exists the lexical
-- distinction between @100@ and @1e2@ is gone — and the contract is
-- lexical (exponent SPELLING is rejected even when the value is safe).
-- Sibling of 'checkNoDuplicateKeys': a linear pass over the raw bytes
-- that skips string literals escape-aware; outside strings, a digit or
-- @-@ can only begin a number token in well-formed JSON (the CLI runs
-- this only after a successful strict decode), so the maximal run of
-- number-token bytes IS the token.
-- CROSS-LINEAGE CONTRACT: all 7 lineages reject identically:
--   * any exponent spelling (e/E), regardless of value;
--   * integer tokens (no @.@) beyond +/-9007199254740992, compared as
--     digit strings so 9007199254740993 is caught despite rounding to
--     a representable Double;
--   * fraction tokens whose Double value v has
--     (v /= 0 && abs v < 1e-6) || abs v >= 1e21.
checkNumberDomain :: BS.ByteString -> Either String ()
checkNumberDomain = goTop
  where
    goTop bs = case BS.uncons bs of
      Nothing -> Right ()
      Just (c, rest)
        | c == 0x22 -> goTop (skipString rest) -- '"'
        | isNumStart c ->
            let (tok, rest') = BS.span isNumByte bs
             in checkToken (map (toEnum . fromIntegral) (BS.unpack tok))
                  >> goTop rest'
        | otherwise -> goTop rest

    isNumStart c = c == 0x2d || (c >= 0x30 && c <= 0x39) -- '-' / digit
    isNumByte c =
      (c >= 0x30 && c <= 0x39) -- digit
        || c == 0x2d -- '-'
        || c == 0x2b -- '+'
        || c == 0x2e -- '.'
        || c == 0x65 -- 'e'
        || c == 0x45 -- 'E'

    -- Inside a string literal: any backslash consumes the next byte
    -- (enough to keep \" from ending the scan; multi-byte UTF-8 never
    -- contains 0x22/0x5c continuation bytes, so byte-wise is safe).
    skipString bs = case BS.uncons bs of
      Nothing -> BS.empty
      Just (c, rest)
        | c == 0x5c -> skipString (BS.drop 1 rest) -- '\\'
        | c == 0x22 -> rest -- closing '"'
        | otherwise -> skipString rest

    checkToken :: String -> Either String ()
    checkToken s
      | any (\c -> c == 'e' || c == 'E') s =
          Left
            ( "unsupported number "
                ++ show s
                ++ ": scientific (exponent) notation is outside the"
                ++ " cross-lineage number contract"
            )
      | '.' `elem` s = case reads s :: [(Double, String)] of
          [(v, "")]
            | (v /= 0 && abs v < 1e-6) || abs v >= 1e21 ->
                Left
                  ( "unsupported number "
                      ++ show s
                      ++ ": fraction magnitude outside the cross-lineage"
                      ++ " range [1e-6, 1e21)"
                  )
            | otherwise -> Right ()
          -- Unreachable after a successful strict decode; reject rather
          -- than let an unparseable spelling reach the digest.
          _ -> Left ("unsupported number " ++ show s ++ ": unparseable token")
      | otherwise =
          -- Integer token: digit-string comparison, never floats —
          -- 9007199254740993 rounds to a representable Double and
          -- would slip through a numeric compare.
          let digits = dropWhile (== '-') s
              maxSafe = "9007199254740992"
              beyond =
                length digits > length maxSafe
                  || (length digits == length maxSafe && digits > maxSafe)
           in if beyond
                then
                  Left
                    ( "unsupported number "
                        ++ show s
                        ++ ": integer beyond +/-9007199254740992"
                        ++ " (cross-lineage safe-integer bound)"
                    )
                else Right ()

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

-- | Show a Double in canonical-JSON form per ECMA-262 §7.1.12.1
-- (Number::toString radix 10), plain decimal only — the reference
-- rendering shared by the C/Go/OCaml lineages. The previous %g
-- shortest-search loop switched to scientific notation below 0.01
-- and near 1e21 ("1.0e-3"), which diverged from the reference for
-- every fraction in those bands (fixed 2026-07-15).
-- 'Numeric.floatToDigits' 10 yields exactly the minimal (shortest
-- round-tripping) digit string ES-262 specifies, with no trailing
-- zeros, so reassembly is pure positional bookkeeping.
-- CROSS-LINEAGE CONTRACT: byte-identical to ECMAScript ToString for
-- doubles inside the gated fraction domain [1e-6, 1e21).
showDouble :: Double -> String
showDouble d
  | isNaN d || isInfinite d = "null"
  | d == 0 = "0" -- ES-262: ToString of +0 AND -0 is "0"
  | d < 0 = '-' : positiveToString (negate d)
  | otherwise = positiveToString d

-- ES-262 notation: value = D × 10^(n − k) with D the minimal digit
-- string and k = length D. floatToDigits 10 x = (digits, e) means
-- x = 0.D × 10^e = D × 10^(e − k), so n = e directly.
positiveToString :: Double -> String
positiveToString d =
  let (ds, n) = floatToDigits 10 d
   in assembleEs262 (map intToDigit ds) n

assembleEs262 :: String -> Int -> String
assembleEs262 ds n
  | k <= n && n <= 21 = ds ++ replicate (n - k) '0'
  | 0 < n && n <= k = take n ds ++ "." ++ drop n ds
  | (-5) <= n && n <= 0 = "0." ++ replicate (negate n) '0' ++ ds
  -- NON-CANONICAL defensive fallback: the number-domain gate pins
  -- |v| inside [1e-6, 1e21), so ES-262's exponent branches are
  -- unreachable through the CLI; emit the ES-262 exponent form
  -- rather than crash if a library caller bypasses the gate.
  | otherwise =
      let mantissa = case ds of
            [c] -> [c]
            (c : rest) -> c : '.' : rest
            [] -> "0"
          e = n - 1
          sign = if e >= 0 then "+" else ""
       in mantissa ++ "e" ++ sign ++ show e
  where
    k = length ds

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
