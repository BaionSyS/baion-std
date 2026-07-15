{-# LANGUAGE OverloadedStrings #-}

-- | BAION canonical JSON for Haskell — public standalone library.
-- Deterministic canonicalization of arbitrary JSON values
-- (RFC 8785-style: sorted object keys, minimal escapes, ECMAScript
-- ToString plain-decimal number formatting over double semantics).
module Baion.STD.CanonicalJson
  ( canonicalizeJson,
    canonicalizeJsonChecked,
    checkControlBytes,
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
import Data.Char (ord)
import Data.List (foldl')
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

-- | Reject raw control bytes (0x00-0x1F) per RFC 8259: inside string
-- literals every control byte must be escape-spelled; between tokens
-- only TAB/LF/CR (0x09/0x0A/0x0D, plus 0x20 which is not a control
-- byte) are legal whitespace. aeson >= 2.2's Decoding lexer happens to
-- enforce both today, but that is an implementation detail of a
-- dependency — this pass pins the contract on the RAW bytes so an
-- aeson upgrade (or a library caller bypassing the CLI's decoder)
-- cannot silently relax it, and the rejection carries the uniform
-- cross-lineage error text instead of a parser-internal message.
-- Sibling of 'checkNumberDomain': same escape-aware string-skipping
-- walk. Escape TEXT like backslash-t or backslash-u001F is bytes
-- 0x5C 0x74 / 0x5C 0x75..., all >= 0x20 — a byte-level check cannot
-- false-positive on it. Multi-byte UTF-8 continuation bytes are
-- >= 0x80, so byte-wise scanning is safe.
-- CROSS-LINEAGE CONTRACT: all 7 lineages reject raw control bytes
-- identically (C++/Rust/Go/D already did; Haskell relied on aeson).
checkControlBytes :: BS.ByteString -> Either String ()
checkControlBytes = goTop
  where
    goTop bs = case BS.uncons bs of
      Nothing -> Right ()
      Just (c, rest)
        | c == 0x22 -> inString rest -- '"'
        | c < 0x20 && c /= 0x09 && c /= 0x0a && c /= 0x0d ->
            Left (controlErr "between tokens" c)
        | otherwise -> goTop rest

    -- Inside a string literal every byte < 0x20 is illegal — including
    -- the byte after a backslash (no valid escape character is a
    -- control byte), so the escaped byte is checked before being
    -- consumed. Unterminated strings fall off the end silently: the
    -- CLI's strict decoder owns malformed-input errors.
    inString bs = case BS.uncons bs of
      Nothing -> Right ()
      Just (c, rest)
        | c < 0x20 -> Left (controlErr "inside a string literal" c)
        | c == 0x5c -> case BS.uncons rest of -- '\\'
            Nothing -> Right ()
            Just (c2, rest2)
              | c2 < 0x20 -> Left (controlErr "inside a string literal" c2)
              | otherwise -> inString rest2
        | c == 0x22 -> goTop rest -- closing '"'
        | otherwise -> inString rest

    controlErr loc c =
      printf
        ( "unsupported raw control byte 0x%02X %s: control characters"
            ++ " must be escaped (RFC 8259 / cross-lineage contract)"
        )
        (fromIntegral c :: Int)
        (loc :: String)

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
-- All numbers render through DOUBLE semantics — even exact-integer
-- Scientifics. The other six lineages hold only a double by this
-- point, so an exact-Integer fast path here would diverge for
-- fraction tokens whose exact value is an unrepresentable integer
-- (e.g. 9007199254740993.0, which every double lineage renders as
-- 9007199254740992). Gated integer tokens (|i| <= 2^53) are exactly
-- representable, so this path prints them identically to `show`.
canonicalizeValue (A.Number n) = showDouble (S.toRealFloat n)
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
-- 'Numeric.floatToDigits' 10 yields a round-tripping digit string
-- with no trailing zeros, but NOT always the minimal one ES-262
-- specifies: GHC's Burger–Dybvig loop compares against the rounding
-- interval with strict inequalities regardless of mantissa parity,
-- so when the shortest decimal sits EXACTLY on an interval boundary
-- that IEEE round-half-even makes inclusive (even mantissa), it
-- emits one digit too many. Found by the agreement fuzzer as a
-- seven-lineage hash split (2026-07-15): 65219416364867774.9377591
-- parses to 0x436CF696D61C5C18, whose shortest spelling
-- 6521941636486778e1 is the exact upper midpoint — floatToDigits
-- returned the 17-digit exact integer 65219416364867776 while every
-- other lineage emitted 65219416364867780. 'shortenScaled' below
-- greedily drops trailing digits while the value still round-trips,
-- restoring the ES-262 minimum.
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
-- x = 0.D × 10^e = D × 10^(e − k); after shortening we track the
-- value as m × 10^scale, so n = scale + length (show m).
positiveToString :: Double -> String
positiveToString d =
  let (ds0, n0) = floatToDigits 10 d
      m0 = foldl' (\acc x -> acc * 10 + toInteger x) 0 ds0
      (m, scale) = shortenScaled d m0 (n0 - length ds0)
      ds = show m
   in assembleEs262 ds (scale + length ds)

-- | Greedy ES-262 shortening pass over (m, scale) with value
-- m × 10^scale == d exactly round-tripped. Each step tries the two
-- one-digit-shorter candidates (truncate, truncate+1); a candidate
-- survives only if it still converts to exactly d ('S.toRealFloat'
-- is correctly rounded). When both survive, ES-262 §7.1.12.1 picks
-- the spelling closest to the value, breaking a tie toward the even
-- significand. Carry (q+1 rolling to a power of 10, e.g. 999 -> 100)
-- is safe: digits are recomputed from the Integer each round.
shortenScaled :: Double -> Integer -> Int -> (Integer, Int)
shortenScaled d = go
  where
    go m scale
      | m < 10 = (m, scale)
      | otherwise =
          let (q, r) = m `divMod` 10
              cands = if r == 0 then [q] else [q, q + 1]
           in case [c | c <- cands, sciValue c (scale + 1) == d] of
                [] -> (m, scale)
                [c] -> go c (scale + 1)
                cs -> go (closerToD cs (scale + 1)) (scale + 1)
    sciValue c e = S.toRealFloat (S.scientific c e) :: Double
    closerToD [a, b] e
      | dist a < dist b = a
      | dist b < dist a = b
      | even a = a
      | otherwise = b
      where
        dist c = abs (fromInteger c * (10 ^^ e) - toRational d)
    closerToD cs _ = head cs -- unreachable: cands has at most 2 members

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
