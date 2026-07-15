module Main where

import ConformanceTest (conformanceTests)
import Test.Tasty

main :: IO ()
main =
  defaultMain $
    testGroup
      "BAION canonical JSON (Haskell)"
      [ conformanceTests
      ]
