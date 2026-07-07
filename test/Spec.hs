{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
-- Arbitrary instances for Domain types are necessarily orphans here:
-- Domain.hs has no QuickCheck dependency by design.
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
-- ═══════════════════════════════════════════════════════════════════════════

genUUID :: Gen UUID
genUUID = UUID.fromWords <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary DoctorId            where arbitrary = DoctorId            <$> genUUID
instance Arbitrary PatientId           where arbitrary = PatientId           <$> genUUID
instance Arbitrary HealthcareServiceId where arbitrary = HealthcareServiceId <$> genUUID
instance Arbitrary HealthcareRequestId where arbitrary = HealthcareRequestId <$> genUUID
instance Arbitrary SlotId              where arbitrary = SlotId              <$> genUUID
instance Arbitrary AppointmentId       where arbitrary = AppointmentId       <$> genUUID

instance Arbitrary Duration where
  arbitrary = elements [QuarterOfAnHour, HalfAnHour, OneHour]

genMoment :: Gen UTCTime
genMoment = do
  days <- choose (0, 365 :: Integer)
  pure $ addUTCTime (fromIntegral days * 86400) base
  where base = UTCTime (fromGregorian 2026 1 1) 0

-- AvailableSlot is the full slot value now (no separate details/wrapper
-- type since Slot/BookedSlot were folded away) — construct it directly.
genAvailableSlotFor :: HealthcareServiceId -> DoctorId -> Gen AvailableSlot
genAvailableSlotFor sid did = do
  newSlotId <- arbitrary
  moment    <- genMoment
  dur       <- arbitrary
  pure AvailableSlot
    { id = newSlotId, doctorId = did
    , healthcareServiceId = sid, start = moment, duration = dur }

genRequestDetails :: Gen HealthcareRequestDetails
genRequestDetails = do
  newReqId <- arbitrary
  pid      <- arbitrary
  created  <- genMoment
  pure HealthcareRequestDetails
    { id = newReqId, patientId = pid, narrative = "needs care"
    , doctorRequirement = AnyDoctor, createdAt = created }

genPriority :: Gen HealthcareRequestPriority
genPriority = do
  deadline <- genMoment
  elements
    [ Emergency (EmergencyDue deadline)
    , Urgent    (UrgentDue    deadline)
    , Routine   RoutineAnytime
    ]

genTriagedRequestFor :: HealthcareServiceId -> Gen TriagedHealthcareRequest
genTriagedRequestFor sid = do
  reqDetails <- genRequestDetails
  prio       <- genPriority
  triageHealthcareRequest reqDetails sid prio <$> genMoment

-- ═══════════════════════════════════════════════════════════════════════════
-- TESTS
-- ═══════════════════════════════════════════════════════════════════════════

main :: IO ()
main = hspec $ do

  describe "mkRoutineWithin" $
    prop "rejects from > to" $ \offsetA offsetB ->
      let base = UTCTime (fromGregorian 2026 1 1) 0
          a    = addUTCTime (fromIntegral (offsetA :: Int)) base
          b    = addUTCTime (fromIntegral (offsetB :: Int)) base
      in if a > b
           then mkRoutineWithin a b === Nothing
           else mkRoutineWithin a b =/= Nothing

  describe "matches" $ do
    prop "requires service to match" $ do
      sid1 <- arbitrary
      sid2 <- arbitrary `suchThat` (/= sid1)
      did  <- arbitrary
      slot <- genAvailableSlotFor sid1 did
      req  <- genTriagedRequestFor sid2
      pure $ not (matches slot req)

    prop "SpecificDoctor requirement is respected" $ do
      sid         <- arbitrary
      doc1        <- arbitrary
      doc2        <- arbitrary `suchThat` (/= doc1)
      slotMatch   <- genAvailableSlotFor sid doc1
      slotNoMatch <- genAvailableSlotFor sid doc2
      reqDetails  <- genRequestDetails
      now         <- genMoment
      let req = triageHealthcareRequest
                  reqDetails { doctorRequirement = SpecificDoctor doc1 }
                  sid (Routine RoutineAnytime) now
      pure $  matches slotMatch req
          .&&. not (matches slotNoMatch req)

    prop "Emergency requires slotStart <= deadline" $ do
      sid        <- arbitrary
      did        <- arbitrary
      slot       <- genAvailableSlotFor sid did
      offset     <- choose (1, 100000 :: Integer)
      now        <- genMoment
      reqDetails <- genRequestDetails
      let deadline       = addUTCTime (fromIntegral offset) slot.start
          beforeDeadline = slot
          afterDeadline  = slot
            { start = addUTCTime (fromIntegral offset + 1) deadline }
          prio           = Emergency (EmergencyDue deadline)
          req            = triageHealthcareRequest reqDetails sid prio now
      pure $  matches beforeDeadline req
          .&&. not (matches afterDeadline req)

  describe "satisfyHealthcareRequest" $ do
    prop "openAppointmentRequest preserves the triaged request" $ do
      sid  <- arbitrary
      did  <- arbitrary
      slot <- genAvailableSlotFor sid did
      req  <- genTriagedRequestFor sid
      aid  <- arbitrary
      pure $ case satisfyHealthcareRequest slot aid req of
        Just oa -> openAppointmentRequest oa === req
        Nothing -> property True

    prop "hard-copies the slot's doctor/start/duration into the appointment" $ do
      sid  <- arbitrary
      did  <- arbitrary
      slot <- genAvailableSlotFor sid did
      req  <- genTriagedRequestFor sid
      aid  <- arbitrary
      pure $ case satisfyHealthcareRequest slot aid req of
        Just (OpenAppointment _ _ doctorId' start' duration') ->
              doctorId' === slot.doctorId
          .&&. start'    === slot.start
          .&&. duration' === slot.duration
        Nothing -> property True

  describe "reassignSlot" $
    prop "delegates to satisfyHealthcareRequest against the new slot" $ do
      sid  <- arbitrary
      did1 <- arbitrary
      did2 <- arbitrary
      slot1 <- genAvailableSlotFor sid did1
      slot2 <- genAvailableSlotFor sid did2
      req  <- genTriagedRequestFor sid
      aid  <- arbitrary
      pure $ case satisfyHealthcareRequest slot1 aid req of
        Nothing -> property True
        Just oa -> reassignSlot oa slot2 === satisfyHealthcareRequest slot2 aid req

  describe "checkWaitlist" $ do
    prop "chooses Emergency over Urgent and Routine" $ do
      sid        <- arbitrary
      did        <- arbitrary
      slot       <- genAvailableSlotFor sid did
      now        <- genMoment
      reqDetails <- genRequestDetails
      let slotStart  = slot.start
          deadline   = addUTCTime 86400 slotStart
          mkReq prio = triageHealthcareRequest reqDetails sid prio now
          emergency  = mkReq (Emergency (EmergencyDue deadline))
          urgent     = mkReq (Urgent    (UrgentDue    deadline))
          routine    = mkReq (Routine   RoutineAnytime)
      aid <- arbitrary
      pure $ case checkWaitlist slot aid [routine, urgent, emergency] of
        Just oa -> (openAppointmentRequest oa).priority === Emergency (EmergencyDue deadline)
        Nothing -> property False

    prop "returns Nothing when no request matches" $ do
      sid1 <- arbitrary
      sid2 <- arbitrary `suchThat` (/= sid1)
      did  <- arbitrary
      slot <- genAvailableSlotFor sid1 did
      req  <- genTriagedRequestFor sid2
      aid  <- arbitrary
      pure $ checkWaitlist slot aid [req] === Nothing
