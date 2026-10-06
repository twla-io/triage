{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
-- Arbitrary instances for Domain types are necessarily orphans here:
-- Domain.hs has no QuickCheck dependency by design. Transport.hs's DTOs
-- get no Arbitrary instances: their values are built from Domain values
-- by their fromDomain functions.
{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Prelude hiding (id)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Data.List (sortOn)
import Data.Maybe (isJust)

import Control.Lens ((%~), (&), (.~), (?~), (^.), _Just)
import Data.Aeson (ToJSON, Value (Null), toJSON)
import Data.OpenApi
  ( AdditionalProperties (..), OpenApiItems (..), Referenced (..), Schema, ToSchema, declareSchema
  , additionalProperties, allOf, anyOf, enum_, items, not_, nullable, oneOf, properties )
import Data.OpenApi.Declare (runDeclare)
import Data.OpenApi.Schema.Validation (validateJSON)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, addUTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain
import qualified Api as A
import qualified Service as S
import qualified Transport as T

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
    , createdAt = created }

genPriority :: Gen IntakeRequestPriority
genPriority = do
  deadline <- genMoment
  elements
    [ Emergency (MustBeSeenBy deadline)
    , Urgent    (MustBeSeenBy deadline)
    , Routine   RoutineAnytime
    ]

-- Only for bounds already known to satisfy notBefore <= notAfter; goes
-- through mkRoutineWindow since RoutineWindow's constructor isn't exported.
validWithin :: UTCTime -> UTCTime -> RoutineDue
validWithin notBefore notAfter = case mkRoutineWindow notBefore notAfter of
  Just window -> RoutineWithin window
  Nothing     -> error "validWithin: notBefore > notAfter"

-- Offsets by whole days, so ordered bounds are built rather than filtered
-- for (a suchThat on genMoment's finite range can loop forever).
laterThan, earlierThan, atOrEarlierThan :: UTCTime -> Gen UTCTime
laterThan       t = (\d -> addUTCTime (fromIntegral (d :: Integer) * 86400) t)    <$> choose (1, 365)
earlierThan     t = (\d -> addUTCTime (fromIntegral (d :: Integer) * (-86400)) t) <$> choose (1, 365)
atOrEarlierThan t = (\d -> addUTCTime (fromIntegral (d :: Integer) * (-86400)) t) <$> choose (0, 365)

-- Draws from a handful of moments so equal values actually come up.
genRoutineDue :: Gen RoutineDue
genRoutineDue = oneof
  [ pure RoutineAnytime
  , RoutineNotBefore <$> moment
  , RoutineNotAfter  <$> moment
  , do a <- moment
       b <- moment
       pure (validWithin (min a b) (max a b))
  ]
  where
    moment = elements [addUTCTime (fromIntegral h * 3600) base | h <- [0 .. 3 :: Int]]
    base   = UTCTime (fromGregorian 2026 1 1) 0

genTriagedRequestFor :: HealthcareServiceId -> Gen TriagedIntakeRequest
genTriagedRequestFor sid = do
  baseRequest <- genSubmittedIntakeRequest
  prio        <- genPriority
  acceptIntakeRequest baseRequest sid prio AnyDoctor <$> genMoment

genService :: Gen HealthcareService
genService = do
  sid <- arbitrary
  HealthcareService sid "a service" <$> arbitrary

-- Built from explicit parts rather than record updates: start/doctorId/
-- duration are shared field names across AvailableSlot and
-- AppointedIntakeRequest, so an update on them would be ambiguous.
genAvailableSlotAt :: DoctorId -> UTCTime -> Duration -> Gen AvailableSlot
genAvailableSlotAt did moment dur = do
  newSlotId <- arbitrary
  sid       <- arbitrary
  pure AvailableSlot
    { id = newSlotId, doctorId = did
    , healthcareServiceId = sid, start = moment, duration = dur }

genDoctorCalendarEntryAt :: DoctorId -> UTCTime -> Duration -> Gen DoctorCalendarEntry
genDoctorCalendarEntryAt did moment dur = oneof
  [ Slot <$> genAvailableSlotAt did moment dur
  , do req <- arbitrary >>= genTriagedRequestFor
       pure $ Appointment AppointedIntakeRequest
         { triaged = req, doctorId = did, start = moment, duration = dur }
  ]

-- Starts on a quarter-hour grid over three hours, so entries of the same
-- doctor overlap, touch, and miss each other often enough to matter.
genGridMoment :: Gen UTCTime
genGridMoment = do
  quarter <- choose (0, 12 :: Integer)
  pure (addUTCTime (fromIntegral quarter * 900) (UTCTime (fromGregorian 2026 1 1) 0))

genDoctorCalendarEntryFor :: DoctorId -> Gen DoctorCalendarEntry
genDoctorCalendarEntryFor did = do
  moment <- genGridMoment
  genDoctorCalendarEntryAt did moment =<< arbitrary

-- Short lists: on a thirteen-start grid, long ones almost always overlap.
genDoctorCalendarEntries :: Gen [DoctorCalendarEntry]
genDoctorCalendarEntries = do
  doctors <- vectorOf 2 arbitrary
  n       <- choose (0, 4)
  vectorOf n (elements doctors >>= genDoctorCalendarEntryFor)

doctorCalendarEntryDoctorOf :: DoctorCalendarEntry -> DoctorId
doctorCalendarEntryDoctorOf (Slot s)        = s.doctorId
doctorCalendarEntryDoctorOf (Appointment a) = a.doctorId

doctorCalendarEntryEndOf :: DoctorCalendarEntry -> UTCTime
doctorCalendarEntryEndOf e = addUTCTime (durationToNominalDiffTime (dur e)) (doctorCalendarEntryStart e)
  where
    dur (Slot s)        = s.duration
    dur (Appointment a) = a.duration

-- Reference definition, checked against every existing entry: same
-- doctor, half-open intervals intersect.
overlapsNaive :: DoctorCalendarEntry -> DoctorCalendarEntry -> Bool
overlapsNaive a b =
     doctorCalendarEntryDoctorOf a == doctorCalendarEntryDoctorOf b
  && doctorCalendarEntryStart a < doctorCalendarEntryEndOf b
  && doctorCalendarEntryStart b < doctorCalendarEntryEndOf a

-- ═══════════════════════════════════════════════════════════════════════════
-- WIRE-FORMAT GENERATORS
-- Every case of every sum type and every outcome of every answer, so each
-- DTO and answer is checked on real Domain values converted by its
-- fromDomain function.
-- ═══════════════════════════════════════════════════════════════════════════

genAnyPriority :: Gen IntakeRequestPriority
genAnyPriority = oneof
  [ Emergency . MustBeSeenBy <$> genMoment
  , Urgent    . MustBeSeenBy <$> genMoment
  , Routine <$> genRoutineDue
  ]

genRoutineWindow :: Gen RoutineWindow
genRoutineWindow = do
  a <- genMoment
  b <- genMoment
  case mkRoutineWindow (min a b) (max a b) of
    Just window -> pure window
    Nothing     -> error "genRoutineWindow: min > max"

genDoctorRequirement :: Gen DoctorRequirement
genDoctorRequirement = oneof [pure AnyDoctor, SpecificDoctor <$> arbitrary]

genAnyTriaged :: Gen TriagedIntakeRequest
genAnyTriaged =
  acceptIntakeRequest <$> genSubmittedIntakeRequest <*> arbitrary <*> genAnyPriority
                      <*> genDoctorRequirement <*> genMoment

genAppointed :: Gen AppointedIntakeRequest
genAppointed = AppointedIntakeRequest <$> genAnyTriaged <*> arbitrary <*> genMoment <*> arbitrary

genAnySlot :: Gen AvailableSlot
genAnySlot = do
  sid <- arbitrary
  did <- arbitrary
  genAvailableSlotFor sid did

genParty :: Gen AppointmentParty
genParty = elements [minBound .. maxBound]

genNote :: Gen (Maybe Text)
genNote = elements [Nothing, Just "a note"]

genCancellation :: Gen Cancellation
genCancellation = Cancellation <$> genParty <*> genMoment <*> genNote

genCloseReason :: Gen CloseReason
genCloseReason = oneof
  [ pure Completed
  , Cancelled <$> genCancellation
  , NoShow . Absence <$> genParty
  ]

genRejected :: Gen RejectedIntakeRequest
genRejected = RejectedIntakeRequest <$> genSubmittedIntakeRequest <*> genMoment <*> pure "no"

genWithdrawnFrom :: Gen WithdrawnFrom
genWithdrawnFrom = oneof [FromSubmitted <$> genSubmittedIntakeRequest, FromAccepted <$> genAnyTriaged]

genWithdrawn :: Gen WithdrawnIntakeRequest
genWithdrawn = WithdrawnIntakeRequest <$> genWithdrawnFrom <*> genMoment <*> genNote

genStale :: Gen StaleIntakeRequest
genStale = StaleIntakeRequest <$> genAnyTriaged <*> genMoment

genClosed :: Gen ClosedIntakeRequest
genClosed = ClosedIntakeRequest <$> genAppointed <*> genCloseReason

genIntakeRequest :: Gen IntakeRequest
genIntakeRequest = oneof
  [ Submitted <$> genSubmittedIntakeRequest
  , Rejected  <$> genRejected
  , Accepted  <$> genAnyTriaged
  , Appointed <$> genAppointed
  , Withdrawn <$> genWithdrawn
  , Stale     <$> genStale
  , Closed    <$> genClosed
  ]

genDoctor :: Gen Doctor
genDoctor = (\did -> Doctor did "Dr A") <$> arbitrary

genPatient :: Gen Patient
genPatient = (\pid -> Patient pid "Patient P") <$> arbitrary

-- Request bodies.

genCancellationRequest :: Gen T.CancellationRequest
genCancellationRequest = T.CancellationRequest <$> (T.fromDomainAppointmentParty <$> genParty) <*> genNote

genCloseReasonRequest :: Gen T.CloseReasonRequest
genCloseReasonRequest = oneof
  [ pure T.CloseReasonRequestCompleted
  , T.CloseReasonRequestCancelled <$> genCancellationRequest
  , T.CloseReasonRequestNoShow . T.fromDomainAbsence . Absence <$> genParty
  ]

-- Answers: every Service value each use case can return, rendered by the
-- same function its handler uses.

genDoctorNotFound :: Gen S.DoctorNotFound
genDoctorNotFound = S.DoctorNotFound <$> arbitrary

genPatientNotFound :: Gen S.PatientNotFound
genPatientNotFound = S.PatientNotFound <$> arbitrary

genHealthcareServiceNotFound :: Gen S.HealthcareServiceNotFound
genHealthcareServiceNotFound = S.HealthcareServiceNotFound <$> arbitrary

genIntakeRequestNotFound :: Gen S.IntakeRequestNotFound
genIntakeRequestNotFound = S.IntakeRequestNotFound <$> arbitrary

genIntakeRequestInWrongState :: Gen S.IntakeRequestInWrongState
genIntakeRequestInWrongState = S.IntakeRequestInWrongState <$> genIntakeRequest

genAcceptSubmittedIntakeRequestError :: Gen S.AcceptSubmittedIntakeRequestError
genAcceptSubmittedIntakeRequestError = oneof
  [ S.AcceptSubmittedIntakeRequestIntakeRequestNotFound <$> genIntakeRequestNotFound
  , S.AcceptSubmittedIntakeRequestHealthcareServiceNotFound <$> genHealthcareServiceNotFound
  , S.AcceptSubmittedIntakeRequestDoctorNotFound <$> genDoctorNotFound
  ]

genMatchAcceptedIntakeRequestToSlotError :: Gen S.MatchAcceptedIntakeRequestToSlotError
genMatchAcceptedIntakeRequestToSlotError = oneof
  [ S.MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound <$> genIntakeRequestNotFound
  , S.MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState <$> genIntakeRequestInWrongState
  , pure (S.MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot S.IntakeRequestDoesNotMatchSlot)
  ]

genMarkAcceptedIntakeRequestStaleError :: Gen S.MarkAcceptedIntakeRequestStaleError
genMarkAcceptedIntakeRequestStaleError = oneof
  [ S.MarkAcceptedIntakeRequestStaleIntakeRequestNotFound <$> genIntakeRequestNotFound
  , S.MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState <$> genIntakeRequestInWrongState
  ]

genCloseAppointedIntakeRequestError :: Gen S.CloseAppointedIntakeRequestError
genCloseAppointedIntakeRequestError = oneof
  [ S.CloseAppointedIntakeRequestIntakeRequestNotFound <$> genIntakeRequestNotFound
  , S.CloseAppointedIntakeRequestIntakeRequestInWrongState <$> genIntakeRequestInWrongState
  ]

genCreateAvailableSlotError :: Gen S.CreateAvailableSlotError
genCreateAvailableSlotError = oneof
  [ S.CreateAvailableSlotDoctorNotFound <$> genDoctorNotFound
  , S.CreateAvailableSlotHealthcareServiceNotFound <$> genHealthcareServiceNotFound
  ]

orFact :: Gen e -> Gen a -> Gen (Either e a)
orFact e a = oneof [Left <$> e, Right <$> a]

genTransition :: Gen a -> Gen (S.TransitionOutcome a)
genTransition g = oneof [S.Transitioned <$> g, S.MovedOn <$> genIntakeRequest]

genMatchIntakeRequestToSlotOutcome :: Gen S.MatchIntakeRequestToSlotOutcome
genMatchIntakeRequestToSlotOutcome = oneof
  [ S.IntakeRequestMatchedToSlot <$> genAppointed
  , S.AvailableSlotConsumed <$> arbitrary
  , S.IntakeRequestMovedOn <$> genIntakeRequest
  ]

genMatchByPriorityOutcome :: Gen S.MatchByPriorityOutcome
genMatchByPriorityOutcome = oneof [pure S.NoIntakeRequestMatched, S.MatchIntakeRequestToSlotOutcome <$> genMatchIntakeRequestToSlotOutcome]

genAddAvailableSlotOutcome :: Gen S.AddAvailableSlotOutcome
genAddAvailableSlotOutcome = oneof [S.AvailableSlotAdded <$> genAnySlot, pure S.AvailableSlotOverlapsDoctorCalendar]

-- Short lists, possibly empty.
shortListOf :: Gen a -> Gen [a]
shortListOf g = choose (0, 3) >>= \n -> vectorOf n g

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA CHECK
-- ═══════════════════════════════════════════════════════════════════════════

-- openapi3's validator ignores nullable, so for the check only, every
-- nullable schema becomes oneOf itself or null. The published schema is
-- unchanged.
admitNull :: Schema -> Schema
admitNull s = case (s ^. nullable, s ^. enum_) of
  (Just True, Nothing) ->
    mempty & oneOf ?~ [Inline (inner & nullable .~ Nothing), Inline (mempty & enum_ ?~ [Null])]
  _ -> inner
  where
    inner = s
      & properties %~ fmap onRef
      & items . _Just %~ onItems
      & oneOf . _Just %~ map onRef
      & allOf . _Just %~ map onRef
      & anyOf . _Just %~ map onRef
      & not_ . _Just %~ onRef
      & additionalProperties . _Just %~ onAdditional
    onRef (Inline x) = Inline (admitNull x)
    onRef r          = r
    onItems (OpenApiItemsObject r) = OpenApiItemsObject (onRef r)
    onItems (OpenApiItemsArray rs) = OpenApiItemsArray (map onRef rs)
    onAdditional (AdditionalPropertiesSchema r) = AdditionalPropertiesSchema (onRef r)
    onAdditional a                              = a

-- A value's JSON is valid against its own schema; for a oneOf, against
-- exactly one case (the validator rejects a value matching several).
matchesSchema :: forall a. (ToJSON a, ToSchema a) => a -> Property
matchesSchema x =
  counterexample (show (toJSON x)) $
    validateJSON (fmap admitNull defs) (admitNull schema) (toJSON x) === []
  where
    (defs, schema) = runDeclare (declareSchema (Proxy @a)) mempty

-- ═══════════════════════════════════════════════════════════════════════════

main :: IO ()
main = hspec $ do

  describe "mkRoutineWindow" $
    prop "rejects notBefore > notAfter" $ \offsetA offsetB ->
      let base = UTCTime (fromGregorian 2026 1 1) 0
          a    = addUTCTime (fromIntegral (offsetA :: Int)) base
          b    = addUTCTime (fromIntegral (offsetB :: Int)) base
      in if a > b
           then mkRoutineWindow a b === Nothing
           else mkRoutineWindow a b =/= Nothing

  describe "RoutineDue ordering" $ do
    prop "earlier upper bound takes precedence regardless of lower bounds" $ do
      hi1 <- genMoment
      hi2 <- laterThan hi1
      lo1 <- atOrEarlierThan hi1
      lo2 <- atOrEarlierThan hi2
      pure $  compare (validWithin lo1 hi1) (validWithin lo2 hi2) === LT
         .&&. compare (validWithin lo2 hi2) (validWithin lo1 hi1) === GT

    prop "equal upper bounds put the later lower bound first" $ do
      hi    <- genMoment
      late  <- atOrEarlierThan hi
      early <- earlierThan late
      pure $  compare (validWithin late hi) (validWithin early hi) === LT
         .&&. compare (validWithin early hi) (validWithin late hi) === GT

    prop "identical windows compare as EQ" $ do
      a <- genMoment
      b <- genMoment
      let lo = min a b
          hi = max a b
      pure $ compare (validWithin lo hi) (validWithin lo hi) === EQ

    prop "compare is EQ exactly when values are equal" $ do
      a <- genRoutineDue
      b <- genRoutineDue
      pure $ (compare a b == EQ) === (a == b)

  describe "matches" $ do
    prop "requires service to match" $ do
      sid1 <- arbitrary
      sid2 <- arbitrary `suchThat` (/= sid1)
      did  <- arbitrary
      slot <- genAvailableSlotFor sid1 did
      req  <- genTriagedRequestFor sid2
      pure $ not (matches slot req)

    prop "the doctor requirement decided at triage is respected" $ do
      sid         <- arbitrary
      doc1        <- arbitrary
      doc2        <- arbitrary `suchThat` (/= doc1)
      slotMatch   <- genAvailableSlotFor sid doc1
      slotNoMatch <- genAvailableSlotFor sid doc2
      baseRequest <- genSubmittedIntakeRequest
      now         <- genMoment
      let req = acceptIntakeRequest baseRequest sid (Routine RoutineAnytime) (SpecificDoctor doc1) now
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
          prio           = Emergency (MustBeSeenBy deadline)
          req            = acceptIntakeRequest baseRequest sid prio AnyDoctor now
      pure $  matches beforeDeadline req
          .&&. not (matches afterDeadline req)

  describe "matchIntakeRequestToSlot" $ do
    prop "preserves the triaged request" $ do
      sid  <- arbitrary
      did  <- arbitrary
      slot <- genAvailableSlotFor sid did
      req  <- genTriagedRequestFor sid
      pure $ case matchIntakeRequestToSlot slot req of
        Just appt -> appt.triaged === req
        Nothing        -> property True

    prop "hard-copies the slot's doctor/start/duration into the appointment" $ do
      sid  <- arbitrary
      did  <- arbitrary
      slot <- genAvailableSlotFor sid did
      req  <- genTriagedRequestFor sid
      pure $ case matchIntakeRequestToSlot slot req of
        Just appt ->
              appt.doctorId === slot.doctorId
          .&&. appt.start    === slot.start
          .&&. appt.duration === slot.duration
        Nothing -> property True

  describe "matchByPriority" $ do
    prop "chooses Emergency over Urgent and Routine" $ do
      sid         <- arbitrary
      did         <- arbitrary
      slot        <- genAvailableSlotFor sid did
      now         <- genMoment
      baseRequest <- genSubmittedIntakeRequest
      let slotStart  = slot.start
          deadline   = addUTCTime 86400 slotStart
          mkReq prio = acceptIntakeRequest baseRequest sid prio AnyDoctor now
          emergency  = mkReq (Emergency (MustBeSeenBy deadline))
          urgent     = mkReq (Urgent    (MustBeSeenBy deadline))
          routine    = mkReq (Routine   RoutineAnytime)
      pure $ case matchByPriority slot [routine, urgent, emergency] of
        Just appt -> appt.triaged.priority === Emergency (MustBeSeenBy deadline)
        Nothing        -> property False

    prop "returns Nothing when no request matches" $ do
      sid1 <- arbitrary
      sid2 <- arbitrary `suchThat` (/= sid1)
      did  <- arbitrary
      slot <- genAvailableSlotFor sid1 did
      req  <- genTriagedRequestFor sid2
      pure $ matchByPriority slot [req] === Nothing

    prop "on equal-deadline windows, chooses the narrower one even when listed second" $ do
      sid         <- arbitrary
      did         <- arbitrary
      slot        <- genAvailableSlotFor sid did
      now         <- genMoment
      baseRequest <- genSubmittedIntakeRequest
      let deadline   = addUTCTime 86400 slot.start
          wideDue    = validWithin (addUTCTime (-172800) slot.start) deadline
          narrowDue  = validWithin (addUTCTime (-3600)   slot.start) deadline
          mkReq due  = acceptIntakeRequest baseRequest sid (Routine due) AnyDoctor now
          wide       = mkReq wideDue
          narrow     = mkReq narrowDue
      pure $ case matchByPriority slot [wide, narrow] of
        Just appt ->
              property (matches slot wide)
          .&&. property (matches slot narrow)
          .&&. appt.triaged.priority === Routine narrowDue
        Nothing -> property False

    prop "on equal priorities, chooses the earlier triaged, then the earlier submitted, in any input order" $ do
      sid         <- arbitrary
      did         <- arbitrary
      slot        <- genAvailableSlotFor sid did
      now         <- genMoment
      first       <- genSubmittedIntakeRequest
      second      <- genSubmittedIntakeRequest
      sameTriage  <- arbitrary
      let submittedAt = addUTCTime (-120) now
          mkReq s askedAt acceptedAt =
            acceptIntakeRequest s { createdAt = askedAt } sid (Routine RoutineAnytime) AnyDoctor acceptedAt
          -- Equal triage: the earlier submitted wins. Different triage: the
          -- earlier triaged wins, though it was submitted later.
          (winner, loser)
            | sameTriage = ( mkReq first  submittedAt                  now
                           , mkReq second (addUTCTime 60 submittedAt)  now )
            | otherwise  = ( mkReq first  (addUTCTime 60 submittedAt)  now
                           , mkReq second submittedAt                  (addUTCTime 60 now) )
      reversed <- arbitrary
      let input = if reversed then [loser, winner] else [winner, loser]
      pure $ fmap (.triaged) (matchByPriority slot input) === Just winner

  describe "mkDoctorCalendar" $ do
    prop "succeeds exactly when no two entries of the same doctor overlap" $ do
      entries <- genDoctorCalendarEntries
      let pairs = [ (a, b) | (i, a) <- zip [0 :: Int ..] entries
                           , (j, b) <- zip [0 ..] entries, i < j ]
      pure $ isJust (mkDoctorCalendar entries)
         === not (any (uncurry overlapsNaive) pairs)

    prop "doctorCalendarEntries gives back exactly the entries it was built from" $ do
      entries <- genDoctorCalendarEntries
      let key e = (doctorCalendarEntryDoctorOf e, doctorCalendarEntryStart e)
      pure $ case mkDoctorCalendar entries of
        Just calendar -> sortOn key (doctorCalendarEntries calendar) === sortOn key entries
        Nothing       -> property Discard

  describe "addAvailableSlot" $ do
    prop "succeeds exactly when the calendar's entries plus the slot still form a calendar" $ do
      entries <- genDoctorCalendarEntries
      did     <- elements (map doctorCalendarEntryDoctorOf entries ++ [DoctorId UUID.nil])
      moment  <- genGridMoment
      service <- genService
      newId   <- arbitrary
      let slot = AvailableSlot
            { id = newId, doctorId = did, healthcareServiceId = service.id
            , start = moment, duration = service.duration }
      pure $ case mkDoctorCalendar entries of
        Just calendar ->
          isJust (addAvailableSlot calendar newId did service moment)
            === isJust (mkDoctorCalendar (entries ++ [Slot slot]))
        Nothing -> property Discard

    prop "gives the new slot its service's duration" $ do
      did     <- arbitrary
      moment  <- genMoment
      service <- genService
      newId   <- arbitrary
      pure $ case mkDoctorCalendar [] >>= \c -> addAvailableSlot c newId did service moment of
        Just (slot, _) ->
          slot === AvailableSlot
            { id = newId, doctorId = did, healthcareServiceId = service.id
            , start = moment, duration = service.duration }
        Nothing -> counterexample "an empty calendar rejected a slot" False

    prop "accepts a slot starting exactly where another entry ends" $ do
      did     <- arbitrary
      entry   <- genDoctorCalendarEntryFor did
      service <- genService
      newId   <- arbitrary
      pure $ isJust (mkDoctorCalendar [entry] >>= \c -> addAvailableSlot c newId did service (doctorCalendarEntryEndOf entry))

    prop "never rejects a slot because of another doctor's entry" $ do
      did1    <- arbitrary
      did2    <- arbitrary `suchThat` (/= did1)
      entry   <- genDoctorCalendarEntryFor did1
      service <- genService
      newId   <- arbitrary
      pure $ isJust (mkDoctorCalendar [entry] >>= \c -> addAvailableSlot c newId did2 service (doctorCalendarEntryStart entry))
  describe "wire format: every DTO's ToJSON matches its OpenAPI 3 schema" $ do
    prop "IDs" $ \did pid sid rid slid ->
           matchesSchema (T.fromDomainDoctorId did)
      .&&. matchesSchema (T.fromDomainPatientId pid)
      .&&. matchesSchema (T.fromDomainHealthcareServiceId sid)
      .&&. matchesSchema (T.fromDomainIntakeRequestId rid)
      .&&. matchesSchema (T.fromDomainSlotId slid)
    prop "Duration"               $ forAll arbitrary (matchesSchema . T.fromDomainDuration)
    prop "Doctor"                 $ forAll genDoctor (matchesSchema . T.fromDomainDoctor)
    prop "Patient"                $ forAll genPatient (matchesSchema . T.fromDomainPatient)
    prop "HealthcareService"      $ forAll genService (matchesSchema . T.fromDomainHealthcareService)
    prop "DoctorRequirement"      $ forAll genDoctorRequirement (matchesSchema . T.fromDomainDoctorRequirement)
    prop "MustBeSeenBy"           $ forAll genMoment (matchesSchema . T.fromDomainMustBeSeenBy . MustBeSeenBy)
    prop "RoutineWindow"          $ forAll genRoutineWindow (matchesSchema . T.fromDomainRoutineWindow)
    prop "RoutineDue"             $ forAll genRoutineDue (matchesSchema . T.fromDomainRoutineDue)
    prop "IntakeRequestPriority"  $ forAll genAnyPriority (matchesSchema . T.fromDomainIntakeRequestPriority)
    prop "SubmittedIntakeRequest" $
      forAll genSubmittedIntakeRequest (matchesSchema . T.fromDomainSubmittedIntakeRequest)
    prop "RejectedIntakeRequest"  $ forAll genRejected (matchesSchema . T.fromDomainRejectedIntakeRequest)
    prop "TriagedIntakeRequest"   $ forAll genAnyTriaged (matchesSchema . T.fromDomainTriagedIntakeRequest)
    prop "AppointedIntakeRequest" $ forAll genAppointed (matchesSchema . T.fromDomainAppointedIntakeRequest)
    prop "WithdrawnFrom"          $ forAll genWithdrawnFrom (matchesSchema . T.fromDomainWithdrawnFrom)
    prop "WithdrawnIntakeRequest" $ forAll genWithdrawn (matchesSchema . T.fromDomainWithdrawnIntakeRequest)
    prop "StaleIntakeRequest"     $ forAll genStale (matchesSchema . T.fromDomainStaleIntakeRequest)
    prop "AppointmentParty"       $ forAll genParty (matchesSchema . T.fromDomainAppointmentParty)
    prop "Cancellation"           $ forAll genCancellation (matchesSchema . T.fromDomainCancellation)
    prop "Absence"                $ forAll genParty (matchesSchema . T.fromDomainAbsence . Absence)
    prop "CloseReason"            $ forAll genCloseReason (matchesSchema . T.fromDomainCloseReason)
    prop "ClosedIntakeRequest"    $ forAll genClosed (matchesSchema . T.fromDomainClosedIntakeRequest)
    prop "IntakeRequest (every case)" $ forAll genIntakeRequest (matchesSchema . T.fromDomainIntakeRequest)
    prop "AvailableSlot"          $ forAll genAnySlot (matchesSchema . T.fromDomainAvailableSlot)
    prop "DoctorCalendarEntry"    $ forAll genDoctorCalendarEntries
                                      (conjoin . map (matchesSchema . T.fromDomainDoctorCalendarEntry))

  describe "wire format: every request body's ToJSON matches its OpenAPI 3 schema" $ do
    prop "CreateDoctorRequest"  $ matchesSchema (T.CreateDoctorRequest "Dr A")
    prop "CreatePatientRequest" $ matchesSchema (T.CreatePatientRequest "Patient P")
    prop "CreateHealthcareServiceRequest" $ forAll arbitrary $ \d ->
      matchesSchema (T.CreateHealthcareServiceRequest "Consultation" (T.fromDomainDuration d))
    prop "SubmitIntakeRequestRequest" $ \pid ->
      matchesSchema (T.SubmitIntakeRequestRequest (T.fromDomainPatientId pid) "needs care")
    prop "AcceptSubmittedIntakeRequestRequest" $ forAll genAnyTriaged $ \tr ->
      matchesSchema (T.AcceptSubmittedIntakeRequestRequest
        (T.fromDomainHealthcareServiceId tr.healthcareServiceId)
        (T.fromDomainIntakeRequestPriority tr.priority)
        (T.fromDomainDoctorRequirement tr.doctorRequirement))
    prop "RejectSubmittedIntakeRequestRequest" $ matchesSchema (T.RejectSubmittedIntakeRequestRequest "no")
    prop "MatchAcceptedIntakeRequestToSlotRequest" $ \slid ->
      matchesSchema (T.MatchAcceptedIntakeRequestToSlotRequest (T.fromDomainSlotId slid))
    prop "WithdrawIntakeRequestRequest" $ forAll genNote (matchesSchema . T.WithdrawIntakeRequestRequest)
    prop "CancellationRequest" $ forAll genCancellationRequest matchesSchema
    prop "CloseReasonRequest"  $ forAll genCloseReasonRequest matchesSchema
    prop "CloseAppointedIntakeRequestRequest" $
      forAll genCloseReasonRequest (matchesSchema . T.CloseAppointedIntakeRequestRequest)
    prop "CreateAvailableSlotRequest" $ forAll genAnySlot $ \slot ->
      matchesSchema (T.CreateAvailableSlotRequest (T.fromDomainDoctorId slot.doctorId)
        (T.fromDomainHealthcareServiceId slot.healthcareServiceId) slot.start)

  describe "wire format: every answer's ToJSON matches its OpenAPI 3 schema" $ do
    prop "CreateDoctorAnswer" $ forAll genDoctor (matchesSchema . A.renderCreateDoctorAnswer)
    prop "CreatePatientAnswer" $ forAll genPatient (matchesSchema . A.renderCreatePatientAnswer)
    prop "CreateHealthcareServiceAnswer" $
      forAll genService (matchesSchema . A.renderCreateHealthcareServiceAnswer)
    prop "SubmitIntakeRequestAnswer" $
      forAll (orFact genPatientNotFound genSubmittedIntakeRequest)
        (matchesSchema . A.renderSubmitIntakeRequestAnswer)
    prop "AcceptSubmittedIntakeRequestAnswer" $
      forAll (orFact genAcceptSubmittedIntakeRequestError (genTransition genAnyTriaged))
        (matchesSchema . A.renderAcceptSubmittedIntakeRequestAnswer)
    prop "RejectSubmittedIntakeRequestAnswer" $
      forAll (orFact genIntakeRequestNotFound (genTransition genRejected))
        (matchesSchema . A.renderRejectSubmittedIntakeRequestAnswer)
    prop "MatchAcceptedIntakeRequestToSlotAnswer" $
      forAll (orFact genMatchAcceptedIntakeRequestToSlotError genMatchIntakeRequestToSlotOutcome)
        (matchesSchema . A.renderMatchAcceptedIntakeRequestToSlotAnswer)
    prop "WithdrawIntakeRequestAnswer" $
      forAll (orFact genIntakeRequestNotFound (genTransition genWithdrawn))
        (matchesSchema . A.renderWithdrawIntakeRequestAnswer)
    prop "MarkAcceptedIntakeRequestStaleAnswer" $
      forAll (orFact genMarkAcceptedIntakeRequestStaleError (genTransition genStale))
        (matchesSchema . A.renderMarkAcceptedIntakeRequestStaleAnswer)
    prop "CloseAppointedIntakeRequestAnswer" $
      forAll (orFact genCloseAppointedIntakeRequestError (genTransition genClosed))
        (matchesSchema . A.renderCloseAppointedIntakeRequestAnswer)
    prop "MatchAvailableSlotByPriorityAnswer" $
      forAll genMatchByPriorityOutcome (matchesSchema . A.renderMatchAvailableSlotByPriorityAnswer)
    prop "CreateAvailableSlotAnswer" $
      forAll (orFact genCreateAvailableSlotError genAddAvailableSlotOutcome)
        (matchesSchema . A.renderCreateAvailableSlotAnswer)
    prop "FetchDoctorAnswer" $
      forAll (orFact genDoctorNotFound genDoctor) (matchesSchema . A.renderFetchDoctorAnswer)
    prop "FetchDoctorsAnswer" $
      forAll (shortListOf genDoctor) (matchesSchema . A.renderFetchDoctorsAnswer)
    prop "FetchPatientAnswer" $
      forAll (orFact genPatientNotFound genPatient) (matchesSchema . A.renderFetchPatientAnswer)
    prop "FetchPatientsAnswer" $
      forAll (shortListOf genPatient) (matchesSchema . A.renderFetchPatientsAnswer)
    prop "FetchHealthcareServiceAnswer" $
      forAll (orFact genHealthcareServiceNotFound genService)
        (matchesSchema . A.renderFetchHealthcareServiceAnswer)
    prop "FetchHealthcareServicesAnswer" $
      forAll (shortListOf genService) (matchesSchema . A.renderFetchHealthcareServicesAnswer)
    prop "FetchAvailableSlotAnswer" $
      forAll ((,) <$> arbitrary <*> oneof [pure Nothing, Just <$> genAnySlot])
        (matchesSchema . uncurry A.renderFetchAvailableSlotAnswer)
    prop "FetchIntakeRequestAnswer" $
      forAll (orFact genIntakeRequestNotFound genIntakeRequest)
        (matchesSchema . A.renderFetchIntakeRequestAnswer)
    prop "FetchSubmittedIntakeRequestsAnswer" $
      forAll (shortListOf genSubmittedIntakeRequest)
        (matchesSchema . A.renderFetchSubmittedIntakeRequestsAnswer)
    prop "FetchAcceptedIntakeRequestsAnswer" $
      forAll (shortListOf genAnyTriaged) (matchesSchema . A.renderFetchAcceptedIntakeRequestsAnswer)
    prop "FetchAppointedIntakeRequestsAnswer" $
      forAll (shortListOf genAppointed) (matchesSchema . A.renderFetchAppointedIntakeRequestsAnswer)
    prop "FetchRejectedIntakeRequestsByRejectedAtAnswer" $
      forAll (shortListOf genRejected)
        (matchesSchema . A.renderFetchRejectedIntakeRequestsByRejectedAtAnswer)
    prop "FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer" $
      forAll (shortListOf genWithdrawn)
        (matchesSchema . A.renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer)
    prop "FetchStaleIntakeRequestsByStaleAtAnswer" $
      forAll (shortListOf genStale) (matchesSchema . A.renderFetchStaleIntakeRequestsByStaleAtAnswer)
    prop "FetchClosedIntakeRequestsByStartAnswer" $
      forAll (shortListOf genClosed) (matchesSchema . A.renderFetchClosedIntakeRequestsByStartAnswer)
    prop "FetchDoctorCalendarEntriesOverlappingAnswer" $
      forAll genDoctorCalendarEntries
        (matchesSchema . A.renderFetchDoctorCalendarEntriesOverlappingAnswer)
