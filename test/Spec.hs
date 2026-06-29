{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
-- Arbitrary instances for Domain's types are necessarily orphans here:
-- Domain.hs deliberately has no QuickCheck dependency (it's pure, with no
-- awareness of testing/serialization/anything external), so any Arbitrary
-- instance for its types has to live in whichever module actually needs
-- it. Standard, expected practice for test suites — not a real warning.
{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Prelude hiding (id)
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

-- Takes serviceId/doctorId as parameters and constructs fresh, rather than
-- generating an arbitrary value and then updating its fields — record
-- update syntax on a field name shared across types (serviceId appears on
-- both SlotDetails and AppointmentRequestDetails) needs its own GHC
-- extension (OverloadedRecordUpdate) that's still immature in several
-- compiler versions; full named construction is unambiguous everywhere,
-- since the constructor name alone pins down the type.
genSlotDetailsFor :: ServiceId -> DoctorId -> Gen SlotDetails
genSlotDetailsFor sid did = do
  newSlotId <- arbitrary
  moment    <- genMoment
  dur       <- arbitrary
  pure SlotDetails { id = newSlotId, doctorId = did, serviceId = sid, start = moment, duration = dur }

genAppointmentRequestDetailsFor :: ServiceId -> Gen AppointmentRequestDetails
genAppointmentRequestDetailsFor sid = do
  rid     <- arbitrary
  pid     <- arbitrary
  created <- genMoment
  pure AppointmentRequestDetails { id = rid, patientId = pid, serviceId = sid, createdAt = created }

-- For tests that don't care about a specific serviceId/doctorId match.
genSlotDetails :: Gen SlotDetails
genSlotDetails = do
  sid <- arbitrary
  did <- arbitrary
  genSlotDetailsFor sid did

-- Builds a request with a SPECIFIC serviceId/doctorId, so tests can control
-- whether it matches a given slot rather than relying on chance collisions.
genRequestFor :: ServiceId -> Maybe DoctorId -> Gen AppointmentRequest
genRequestFor sid mDoc = do
  details <- genAppointmentRequestDetailsFor sid
  tier <- elements [0, 1, 2 :: Int]
  case tier of
    0 -> pure (EmergencyRequest details)
    1 -> pure (UrgentRequest details)
    _ -> pure (RoutineRequest details mDoc Anytime)

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
      did <- arbitrary
      slotDetails <- genSlotDetailsFor sid did
      let slot = PendingSlot slotDetails
      n <- choose (1, 6)
      reqs <- vectorOf n (genRequestFor sid Nothing)
      pure $ case bestMatch slot reqs of
        Nothing     -> property (not (any (matches slot) reqs))
        Just winner ->
          let eligible = filter (matches slot) reqs
          in priorityOf winner === minimum (map priorityOf eligible)

    prop "is FIFO within the same priority tier" $ do
      sid <- arbitrary
      did <- arbitrary
      slotDetails <- genSlotDetailsFor sid did
      let slot = PendingSlot slotDetails
      -- Two Urgent requests at different times — the earlier one must win,
      -- since nothing else distinguishes them.
      earlier <- genAppointmentRequestDetailsFor sid
      offsetSecs <- choose (1, 100000 :: Integer)
      let later      = earlier { createdAt = addUTCTime (fromIntegral offsetSecs) earlier.createdAt }
          reqEarlier = UrgentRequest earlier
          reqLater   = UrgentRequest later
      pure $ bestMatch slot [reqLater, reqEarlier] === Just reqEarlier

  describe "matches" $ do
    prop "RoutineRequest's doctor preference is respected" $ do
      sid <- arbitrary
      doc1 <- arbitrary
      doc2 <- arbitrary `suchThat` (/= doc1)
      details <- genAppointmentRequestDetailsFor sid
      matchingSlotDetails <- genSlotDetailsFor sid doc1
      mismatchSlotDetails <- genSlotDetailsFor sid doc2
      let req          = RoutineRequest details (Just doc1) Anytime
          matchingSlot = PendingSlot matchingSlotDetails
          mismatchSlot = PendingSlot mismatchSlotDetails
      pure $ matches matchingSlot req .&&. not (matches mismatchSlot req)

  describe "bookAppointment" $
    prop "always creates a Routine appointment" $ do
      details <- genSlotDetails
      aid <- arbitrary
      pid <- arbitrary
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
      let slot = PendingSlot slotDetails
          (_, appt) = assignAppointment slot req aid
      pure $ case appt of
        Open oa -> (openAppointmentDetails oa).priority === priorityOf req
        Closed{} -> property False  -- assignAppointment never produces Closed