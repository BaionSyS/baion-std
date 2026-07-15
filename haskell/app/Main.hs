-- | baion-canon-hash — canonical-JSON SHA-256 CLI.
-- BAION canonical JSON for Haskell — public standalone library.
--
-- UTF-8 JSON on stdin → canonicalize → SHA-256 of the canonical UTF-8
-- bytes → lowercase hex + newline on stdout, exit 0. Parse errors go
-- to stderr with a nonzero exit so pipelines fail loudly.
module Main (main) where

import Baion.STD.CanonicalJson
  ( canonicalizeJsonChecked,
    checkNoDuplicateKeys,
    checkNumberDomain,
  )
import Baion.STD.Hash (sha256HexBytes)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  input <- BS.getContents
  -- STRICT single-document contract: aeson >= 2.2's eitherDecodeStrict'
  -- (Data.Aeson.Decoding path) requires exactly one complete JSON
  -- document with the whole input consumed — trailing garbage, a second
  -- document, a trailing comma, and empty input all fail here (only
  -- trailing whitespace is allowed). Suite tests 15-19 pin this so an
  -- aeson behavior change cannot silently relax it.
  case A.eitherDecodeStrict' input :: Either String A.Value of
    Left err -> do
      hPutStrLn stderr ("baion-canon-hash: parse error: " ++ err)
      exitFailure
    Right v ->
      -- Duplicate-key and number-domain checks both run on the RAW
      -- bytes (aeson's KeyMap drops duplicates at parse, and Scientific
      -- erases the lexical 100-vs-1e2 distinction the number contract
      -- is defined over); then checked canonicalization rejects any
      -- string containing U+0000 (aeson preserves NUL in Text, so the
      -- CLI would otherwise pass it through to the digest).
      case checkNoDuplicateKeys input
        >> checkNumberDomain input
        >> canonicalizeJsonChecked v of
        Left err -> do
          hPutStrLn stderr ("baion-canon-hash: " ++ err)
          exitFailure
        Right canonical ->
          -- CROSS-LINEAGE CONTRACT: digest is over the canonical string's
          -- UTF-8 bytes, matching the other lineages' canonical-bytes hash.
          putStrLn (sha256HexBytes (TE.encodeUtf8 (T.pack canonical)))
