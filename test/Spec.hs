{-# LANGUAGE DuplicateRecordFields  #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-ambiguous-fields #-}

module Main (main) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Data.Time (UTCTime (..), fromGregorian, addUTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- GENERATORS
-- Orphan Arbitrary instances live here, not in Domain.hs — the domain has
-- no business knowing about QuickCheck. Kept deliberately simple: enough
-- variation to exercise the properties below, not a fully general fuzzer.
-- ═══════════════════════════════════════════════════════════════════════════

genUUID :: Gen UUID
genUUID = UUID.fromWords <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary DoctorId where arbitrary = DoctorId <$> genUUID
instance Arbitrary PatientId where arbitrary = PatientId <$> genUUID
instance Arbitrary ServiceId where arbitrary = ServiceId <$> genUUID
instance Arbitrary SlotId where arbitrary = SlotId <$> genUUID
instance Arbitrary AppointmentId where arbitrary = AppointmentId <$> genUUID
instance Arbitrary AppointmentRequestId where arbitrary = AppointmentRequestId <$> genUUID

-- A small, fixed pool of moments rather than arbitrary UTCTime — keeps
-- generated FIFO orderings meaningfully distinct without needing a custom
-- Arbitrary UTCTime instance.
genMoment :: Gen UTCTime
genMoment = do
  daysOffset <- choose (0, 365 :: Integer)
  pure $ addUTCTime (fromIntegral daysOffset * 86400) baseMoment
  where baseMoment = UTCTime (fromGregorian 2026 1 1) 0

instance Arbitrary Duration where
  arbitrary = elements [OneHour, HalfAnHour]

genSlotDetails :: Gen SlotDetails
genSlotDetails = SlotDetails
  <$> arbitrary <*> arbitrary <*> arbitrary <*> genMoment <*> arbitrary

genAppointmentRequestDetails :: Gen AppointmentRequestDetails
genAppointmentRequestDetails = AppointmentRequestDetails
  <$> arbitrary <*> arbitrary <*> arbitrary <*> genMoment

-- Builds a request with a SPECIFIC serviceId/doctorId, so tests can control
-- whether it matches a given slot rather than relying on chance collisions.
genRequestFor :: ServiceId -> Maybe DoctorId -> Gen AppointmentRequest
genRequestFor sid mDoc = do
  details <- genAppointmentRequestDetails
  let details' = (details :: AppointmentRequestDetails) { serviceId = sid }
  tier <- elements [0, 1, 2 :: Int]
  case tier of
    0 -> pure (EmergencyRequest details')
    1 -> pure (UrgentRequest details')
    _ -> pure (RoutineRequest details' mDoc Anytime)

main :: IO ()
main = hspec $ do

  describe "DueAt" $ do
    it "Anytime is satisfied by any time" $
      satisfiesDueAt (UTCTime (fromGregorian 2026 6 22) 0) Anytime `shouldBe` True

    prop "mkWithin rejects lo > hi" $ \loOffset hiOffset ->
      let base = UTCTime (fromGregorian 2026 1 1) 0
          lo   = addUTCTime (fromIntegral (loOffset :: Int)) base
          hi   = addUTCTime (fromIntegral (hiOffset :: Int)) base
      in if lo > hi
           then mkWithin lo hi === Nothing
           else mkWithin lo hi =/= Nothing

  describe "bestMatch" $ do
    prop "always chooses the highest-priority eligible request" $ do
      sid <- arbitrary
      slotDoc <- arbitrary
      slotDetails <- genSlotDetails
      let slot = PendingSlot (slotDetails { serviceId = sid, doctorId = slotDoc })
      n <- choose (1, 6)
      reqs <- vectorOf n (genRequestFor sid Nothing)
      pure $ case bestMatch slot reqs of
        Nothing     -> property (all (not . matches slot) reqs)
        Just winner ->
          let eligible = filter (matches slot) reqs
          in priorityOf winner === minimum (map priorityOf eligible)

    prop "is FIFO within the same priority tier" $ do
      sid <- arbitrary
      slotDetails <- genSlotDetails
      let slot = PendingSlot (slotDetails { serviceId = sid })
      -- Two Urgent requests at different times — the earlier one must win,
      -- since nothing else distinguishes them.
      d1 <- genAppointmentRequestDetails
      offsetSecs <- choose (1, 100000 :: Integer)
      let earlier = (d1 :: AppointmentRequestDetails) { serviceId = sid }
          later   = d1 { serviceId = sid, createdAt = addUTCTime (fromIntegral offsetSecs) d1.createdAt }
          reqEarlier = UrgentRequest earlier
          reqLater   = UrgentRequest later
      pure $ bestMatch slot [reqLater, reqEarlier] === Just reqEarlier

  describe "matches" $ do
    prop "RoutineRequest's doctor preference is respected" $ do
      sid <- arbitrary
      doc1 <- arbitrary
      doc2 <- arbitrary `suchThat` (/= doc1)
      details <- genAppointmentRequestDetails
      slotDetails <- genSlotDetails
      let req           = RoutineRequest (details { serviceId = sid }) (Just doc1) Anytime
          matchingSlot  = PendingSlot (slotDetails { serviceId = sid, doctorId = doc1 })
          mismatchSlot  = PendingSlot (slotDetails { serviceId = sid, doctorId = doc2 })
      pure $ matches matchingSlot req .&&. not (matches mismatchSlot req)

  describe "bookAppointment" $
    prop "always creates a Routine appointment" $ do
      details <- genSlotDetails
      (aid :: AppointmentId) <- arbitrary
      (pid :: PatientId)     <- arbitrary
      let (_, appt) = bookAppointment (releaseSlot (PendingSlot details)) aid pid
      pure $ case appt of
        Open oa -> (openAppointmentDetails oa).priority === Routine
        Closed{} -> property False  -- bookAppointment never produces Closed

  describe "assignAppointment" $
    prop "preserves the matched request's priority" $ do
      sid <- arbitrary
      slotDetails <- genSlotDetails
      req <- genRequestFor sid Nothing
      aid <- arbitrary
      let slot = PendingSlot (slotDetails { serviceId = sid })
          (_, appt) = assignAppointment slot req aid
      pure $ case appt of
        Open oa -> (openAppointmentDetails oa).priority === priorityOf req
        Closed{} -> property False  -- assignAppointment never produces Closed
