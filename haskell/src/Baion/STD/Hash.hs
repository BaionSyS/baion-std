-- | BAION canonical JSON for Haskell — public standalone library.
-- SHA-256 lowercase-hex digests over strings and raw bytes.
module Baion.STD.Hash
  ( sha256Hex,
    sha256HexBytes,
  )
where

import qualified Crypto.Hash as H
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC

sha256Hex :: String -> String
sha256Hex input = show (H.hash (BSC.pack input) :: H.Digest H.SHA256)

-- | SHA-256 of raw bytes as lowercase hex. The baion-canon-hash CLI
-- hashes canonical-JSON UTF-8 bytes through this — sha256Hex packs
-- Char8 and would truncate non-ASCII canonical output to Latin-1,
-- diverging from the other lineages' UTF-8 digests.
sha256HexBytes :: BS.ByteString -> String
sha256HexBytes bs = show (H.hash bs :: H.Digest H.SHA256)
