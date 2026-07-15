-- | baion-canon-hash — canonical-JSON SHA-256 CLI.
-- BAION canonical JSON for Haskell — public standalone library.
--
-- UTF-8 JSON on stdin → canonicalize → SHA-256 of the canonical UTF-8
-- bytes → lowercase hex + newline on stdout, exit 0. Parse errors go
-- to stderr with a nonzero exit so pipelines fail loudly.
module Main (main) where

import Baion.STD.CanonicalJson (canonicalizeJson)
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
  case A.eitherDecodeStrict' input :: Either String A.Value of
    Left err -> do
      hPutStrLn stderr ("baion-canon-hash: parse error: " ++ err)
      exitFailure
    Right v ->
      -- CROSS-LINEAGE CONTRACT: digest is over the canonical string's
      -- UTF-8 bytes, matching the other lineages' canonical-bytes hash.
      putStrLn (sha256HexBytes (TE.encodeUtf8 (T.pack (canonicalizeJson v))))
