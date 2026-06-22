module Main (main) where

import Test.Hspec
import Data.Time (UTCTime (..), fromGregorian)
import Domain

aMoment :: UTCTime
aMoment = UTCTime (fromGregorian 2026 6 22) 0

main :: IO ()
main = hspec $ do
  describe "DueAt" $ do
    it "Anytime is satisfied by any time" $ do
      satisfiesDueAt aMoment Anytime `shouldBe` True

  -- Real tests go here as the domain model and application layer grow.
  -- See triage-db-codegen / triage-api-codegen / triage-ui-codegen skills
  -- for conventions when generating code that needs testing alongside this.
