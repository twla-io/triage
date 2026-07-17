{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
-- Arbitrary instances for Domain types are necessarily orphans here:
-- Domain.hs has no QuickCheck dependency by design. Same reasoning
-- extends to Transport.hs's DTOs below (no QuickCheck dependency
-- either). aeson's own Value needed a ToSchema orphan too, but that one
-- lives in Transport.hs, not here -- Api.hs's own toSwagger call needs
-- it at the library level, not just in this test suite (see
-- Transport.hs's SWAGGER SCHEMA HELPERS section).
{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Prelude hiding (id)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, addUTCTime)
import Data.UUID (UUID)
import Servant.Swagger.Test (validateEveryToJSON)
import qualified Data.Text as Text
import qualified Data.UUID as UUID
import Domain
import Api (API)
import Transport
  ( AcceptIntakeRequestRequest (..)
  , AppointedIntakeRequestDTO (..)
  , AppointmentPartyDTO (..)
  , AvailableSlotDTO (..)
  , CalendarEntryDTO (..)
  , CloseReasonDTO (..)
  , CloseReasonRequestDTO (..)
  , CreateAvailableSlotRequest (..)
  , CreateDoctorRequest (..)
  , CreateHealthcareServiceRequest (..)
  , CreatePatientRequest (..)
  , DoctorDTO (..)
  , DoctorRequirementDTO (..)
  , DurationDTO (..)
  , HealthcareServiceDTO (..)
  , IntakeRequestDTO (..)
  , IntakeRequestPriorityDTO (..)
  , PatientDTO (..)
  , RejectIntakeRequestRequest (..)
  , RoutineDueDTO (..)
  , SubmitIntakeRequestRequest (..)
  )

-- ═══════════════════════════════════════════════════════════════════════════
-- GENERATORS
-- ═══════════════════════════════════════════════════════════════════════════

genUUID :: Gen UUID
genUUID = UUID.fromWords <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary DoctorId            where arbitrary = DoctorId            <$> genUUID
instance Arbitrary PatientId           where arbitrary = PatientId           <$> genUUID
instance Arbitrary HealthcareServiceId where arbitrary = HealthcareServiceId <$> genUUID
instance Arbitrary IntakeRequestId     where arbitrary = IntakeRequestId     <$> genUUID
instance Arbitrary SlotId              where arbitrary = SlotId              <$> genUUID

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

genSubmittedIntakeRequest :: Gen SubmittedIntakeRequest
genSubmittedIntakeRequest = do
  newReqId <- arbitrary
  pid      <- arbitrary
  created  <- genMoment
  pure SubmittedIntakeRequest
    { id = newReqId, patientId = pid, narrative = "needs care"
    , doctorRequirement = AnyDoctor, createdAt = created }

genPriority :: Gen IntakeRequestPriority
genPriority = do
  deadline <- genMoment
  elements
    [ Emergency (EmergencyDue deadline)
    , Urgent    (UrgentDue    deadline)
    , Routine   RoutineAnytime
    ]

genTriagedRequestFor :: HealthcareServiceId -> Gen TriagedIntakeRequest
genTriagedRequestFor sid = do
  baseRequest <- genSubmittedIntakeRequest
  prio        <- genPriority
  acceptIntakeRequest baseRequest sid prio <$> genMoment

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSPORT DTO ARBITRARY INSTANCES
-- Transport.hs's DTOs are different types from their Domain.hs
-- counterparts (even where structurally similar), so these are their own
-- instances, not reused via toDomain/fromDomain -- generated straight
-- from each DTO's own field list, same shape discipline as
-- genSubmittedIntakeRequest/genAvailableSlotFor above. Needed for
-- validateEveryToJSON below, which requires a genuine Arbitrary instance
-- (not just a Gen helper function) per type used as a request/response
-- body anywhere in Api.API.
--
-- RoutineWithinDTO's from/to are generated independently, with no
-- from <= to ordering enforced -- unlike Domain.hs's sealed
-- RoutineWithin, RoutineWithinDTO's own constructor is open, and this
-- test never calls toDomainRoutineDue/mkRoutineWithin at all (it only
-- checks ToJSON's output against ToSchema, a wire-shape check, not a
-- domain-invariant one), so an unordered pair is a legitimate value to
-- generate here.
-- ═══════════════════════════════════════════════════════════════════════════

genText :: Gen Text
genText = Text.pack <$> listOf1 (elements (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ " "))

genMaybeText :: Gen (Maybe Text)
genMaybeText = oneof [pure Nothing, Just <$> genText]

instance Arbitrary DoctorDTO where
  arbitrary = DoctorDTO <$> genUUID <*> genText

instance Arbitrary PatientDTO where
  arbitrary = PatientDTO <$> genUUID <*> genText

instance Arbitrary CreateDoctorRequest where
  arbitrary = CreateDoctorRequest <$> genText

instance Arbitrary CreatePatientRequest where
  arbitrary = CreatePatientRequest <$> genText

instance Arbitrary DurationDTO where
  arbitrary = elements [QuarterOfAnHourDTO, HalfAnHourDTO, OneHourDTO]

instance Arbitrary HealthcareServiceDTO where
  arbitrary = HealthcareServiceDTO <$> genUUID <*> genText <*> arbitrary

instance Arbitrary CreateHealthcareServiceRequest where
  arbitrary = CreateHealthcareServiceRequest <$> genText <*> arbitrary

instance Arbitrary AvailableSlotDTO where
  arbitrary = AvailableSlotDTO <$> genUUID <*> genUUID <*> genUUID <*> genMoment <*> arbitrary

instance Arbitrary CreateAvailableSlotRequest where
  arbitrary = CreateAvailableSlotRequest <$> genUUID <*> genUUID <*> genMoment <*> arbitrary

instance Arbitrary AppointmentPartyDTO where
  arbitrary = elements [ByDoctorDTO, ByPatientDTO]

instance Arbitrary RoutineDueDTO where
  arbitrary = oneof
    [ pure RoutineAnytimeDTO
    , RoutineNotBeforeDTO <$> genMoment
    , RoutineNotAfterDTO  <$> genMoment
    , RoutineWithinDTO    <$> genMoment <*> genMoment
    ]

instance Arbitrary CloseReasonDTO where
  arbitrary = oneof
    [ pure CompletedDTO
    , CancelledDTO <$> arbitrary <*> genMoment <*> genMaybeText
    , NoShowDTO    <$> arbitrary
    ]

instance Arbitrary CloseReasonRequestDTO where
  arbitrary = oneof
    [ pure CompletedRequestDTO
    , CancelledRequestDTO <$> arbitrary <*> genMaybeText
    , NoShowRequestDTO    <$> arbitrary
    ]

instance Arbitrary IntakeRequestPriorityDTO where
  arbitrary = oneof
    [ EmergencyDTO <$> genMoment
    , UrgentDTO    <$> genMoment
    , RoutineDTO   <$> arbitrary
    ]

instance Arbitrary DoctorRequirementDTO where
  arbitrary = oneof [pure AnyDoctorDTO, SpecificDoctorDTO <$> genUUID]

instance Arbitrary AppointedIntakeRequestDTO where
  arbitrary = AppointedIntakeRequestDTO
    <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
    <*> genUUID <*> arbitrary <*> genMoment <*> genUUID <*> genMoment <*> arbitrary

instance Arbitrary IntakeRequestDTO where
  arbitrary = oneof
    [ SubmittedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
    , RejectedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
        <*> genMoment <*> genText
    , AcceptedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
        <*> genUUID <*> arbitrary <*> genMoment
    , AppointedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
        <*> genUUID <*> arbitrary <*> genMoment <*> genUUID <*> genMoment <*> arbitrary
    , WithdrawnFromSubmittedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
        <*> genMoment <*> genMaybeText
    , WithdrawnFromAcceptedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
        <*> genUUID <*> arbitrary <*> genMoment <*> genMoment <*> genMaybeText
    , ClosedDTO
        <$> genUUID <*> genUUID <*> genText <*> arbitrary <*> genMoment
        <*> genUUID <*> arbitrary <*> genMoment <*> genUUID <*> genMoment <*> arbitrary
        <*> arbitrary
    ]

instance Arbitrary SubmitIntakeRequestRequest where
  arbitrary = SubmitIntakeRequestRequest <$> genUUID <*> genText <*> arbitrary

instance Arbitrary AcceptIntakeRequestRequest where
  arbitrary = AcceptIntakeRequestRequest <$> genUUID <*> arbitrary

instance Arbitrary RejectIntakeRequestRequest where
  arbitrary = RejectIntakeRequestRequest <$> genText

instance Arbitrary CalendarEntryDTO where
  arbitrary = oneof [SlotEntryDTO <$> arbitrary, AppointmentEntryDTO <$> arbitrary]

-- ═══════════════════════════════════════════════════════════════════════════
-- TESTS
--
-- Every DTO above already has a hand-written ToSchema (Transport.hs) and
-- ToJSON; aeson's Value -- the one Api.API body type with no DTO of its
-- own, several mutation endpoints' bare {"outcome","detail"} envelope --
-- gets its ToSchema orphan (and Arbitrary, shipped by aeson itself) at
-- the library level in Transport.hs, not here (see that file's SWAGGER
-- SCHEMA HELPERS section). validateEveryToJSON below (servant-swagger)
-- walks Api.API's route types, collects every distinct JSON request/
-- response body type, and checks that an arbitrary value's real ToJSON
-- output actually validates against its own declared ToSchema, for each
-- one.
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
      baseRequest <- genSubmittedIntakeRequest
      now         <- genMoment
      -- Full record construction, not a { field = ... } update on
      -- baseRequest -- Transport's DTOs now also carry a
      -- doctorRequirement field (imported into this file for the
      -- Arbitrary instances above), making the field-update form
      -- genuinely ambiguous under DuplicateRecordFields (GHC:
      -- -Wambiguous-fields). Same fix as commit 85dd19c applied to a
      -- different ambiguous-field case in this file.
      let requirementRequest = SubmittedIntakeRequest
            { id                = baseRequest.id
            , patientId         = baseRequest.patientId
            , narrative         = baseRequest.narrative
            , doctorRequirement = SpecificDoctor doc1
            , createdAt         = baseRequest.createdAt
            }
          req = acceptIntakeRequest requirementRequest sid (Routine RoutineAnytime) now
      pure $  matches slotMatch req
          .&&. not (matches slotNoMatch req)

    prop "Emergency requires slotStart <= deadline" $ do
      sid         <- arbitrary
      did         <- arbitrary
      slot        <- genAvailableSlotFor sid did
      offset      <- choose (1, 100000 :: Integer)
      now         <- genMoment
      baseRequest <- genSubmittedIntakeRequest
      let deadline       = addUTCTime (fromIntegral offset) slot.start
          beforeDeadline = slot
          afterDeadline  = AvailableSlot
            { id                  = slot.id
            , doctorId            = slot.doctorId
            , healthcareServiceId = slot.healthcareServiceId
            , start               = addUTCTime (fromIntegral offset + 1) deadline
            , duration            = slot.duration
            }
          prio           = Emergency (EmergencyDue deadline)
          req            = acceptIntakeRequest baseRequest sid prio now
      pure $  matches beforeDeadline req
          .&&. not (matches afterDeadline req)

  describe "matchIntakeRequestToSlot" $ do
    prop "preserves the triaged request" $ do
      sid  <- arbitrary
      did  <- arbitrary
      slot <- genAvailableSlotFor sid did
      req  <- genTriagedRequestFor sid
      pure $ case matchIntakeRequestToSlot slot req of
        Just appointed -> appointed.triaged === req
        Nothing        -> property True

    prop "hard-copies the slot's doctor/start/duration into the appointment" $ do
      sid  <- arbitrary
      did  <- arbitrary
      slot <- genAvailableSlotFor sid did
      req  <- genTriagedRequestFor sid
      pure $ case matchIntakeRequestToSlot slot req of
        Just appointed ->
              appointed.doctorId === slot.doctorId
          .&&. appointed.start    === slot.start
          .&&. appointed.duration === slot.duration
        Nothing -> property True

  describe "checkIntakeWaitlist" $ do
    prop "chooses Emergency over Urgent and Routine" $ do
      sid         <- arbitrary
      did         <- arbitrary
      slot        <- genAvailableSlotFor sid did
      now         <- genMoment
      baseRequest <- genSubmittedIntakeRequest
      let slotStart  = slot.start
          deadline   = addUTCTime 86400 slotStart
          mkReq prio = acceptIntakeRequest baseRequest sid prio now
          emergency  = mkReq (Emergency (EmergencyDue deadline))
          urgent     = mkReq (Urgent    (UrgentDue    deadline))
          routine    = mkReq (Routine   RoutineAnytime)
      pure $ case checkIntakeWaitlist slot [routine, urgent, emergency] of
        Just appointed -> appointed.triaged.priority === Emergency (EmergencyDue deadline)
        Nothing        -> property False

    prop "returns Nothing when no request matches" $ do
      sid1 <- arbitrary
      sid2 <- arbitrary `suchThat` (/= sid1)
      did  <- arbitrary
      slot <- genAvailableSlotFor sid1 did
      req  <- genTriagedRequestFor sid2
      pure $ checkIntakeWaitlist slot [req] === Nothing

  -- Route-level, not type-level, unlike the eight property tests above —
  -- validateEveryToJSON (servant-swagger) generates its own per-type
  -- Spec internally (one example per distinct JSON body type in
  -- Api.API), so it's spliced straight into this do-block via describe
  -- rather than wrapped in a single prop.
  describe "Api.API request/response bodies: ToJSON matches ToSchema" $
    validateEveryToJSON (Proxy :: Proxy API)
