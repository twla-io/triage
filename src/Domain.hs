{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- For conventions on generating downstream layers from these types, see:
--   triage-db-codegen      — database schema generation
--   triage-service-codegen — Service.hs orchestration layer generation
--   triage-api-codegen     — REST/GraphQL/RPC API generation
--   triage-ui-codegen      — frontend UI/UX generation
-- Read the relevant skill before generating any of these from this module.

module Domain
  ( -- ── ID wrappers ───────────────────────────────────────────────────────
    DoctorId (..)
  , PatientId (..)
  , HealthcareServiceId (..)
  , IntakeRequestId (..)
  , SlotId (..)

  -- ── Duration ─────────────────────────────────────────────────────────────
  , Duration (..)
  , durationToNominalDiffTime

  -- ── Doctor / Patient ─────────────────────────────────────────────────────
  , Doctor (..)
  , Patient (..)

  -- ── Healthcare Service ───────────────────────────────────────────────────
  , HealthcareService (..)

  -- ── Doctor Requirement ───────────────────────────────────────────────────
  , DoctorRequirement (..)

  -- ── Priority / Due constraints ───────────────────────────────────────────
  , EmergencyDue (..)
  , UrgentDue (..)
  , RoutineDue (RoutineAnytime, RoutineNotBefore, RoutineNotAfter)
  , mkRoutineWithin
  , routineWithinBounds
  , IntakeRequestPriority (..)

  -- ── Intake Request ───────────────────────────────────────────────────────
  , SubmittedIntakeRequest (..)  -- constructor open — no invariant to protect
  , TriagedIntakeRequest (..)    -- constructor open — no invariant to protect
  , AppointedIntakeRequest (..)  -- constructor open — no invariant to protect
  , WithdrawnIntakeRequest (..)  -- constructor open — no invariant to protect
  , AppointmentParty (..)
  , CloseReason (..)
  , IntakeRequest (..)           -- constructor open — no invariant to protect
  , acceptIntakeRequest

  -- ── Slot ─────────────────────────────────────────────────────────────────
  , AvailableSlot (..)
  , slotEnd

  -- ── Protocol ─────────────────────────────────────────────────────────────
  , matches
  , matchIntakeRequestToSlot
  , checkIntakeWaitlist
  ) where

import Data.List  (sortOn)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text  (Text)
import Data.Time  (NominalDiffTime, UTCTime, addUTCTime)
import Data.UUID  (UUID)

-- ═══════════════════════════════════════════════════════════════════════════
-- ID WRAPPERS
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorId            = DoctorId            UUID deriving (Show, Eq, Ord)
newtype PatientId           = PatientId           UUID deriving (Show, Eq, Ord)
newtype HealthcareServiceId = HealthcareServiceId UUID deriving (Show, Eq, Ord)
newtype IntakeRequestId     = IntakeRequestId      UUID deriving (Show, Eq, Ord)
newtype SlotId              = SlotId              UUID deriving (Show, Eq, Ord)

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION
-- ═══════════════════════════════════════════════════════════════════════════

data Duration
  = QuarterOfAnHour
  | HalfAnHour
  | OneHour
  deriving (Show, Eq)

durationToNominalDiffTime :: Duration -> NominalDiffTime
durationToNominalDiffTime QuarterOfAnHour = 900
durationToNominalDiffTime HalfAnHour      = 1800
durationToNominalDiffTime OneHour         = 3600

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT
-- Deliberately minimal — expected to move to a separate system later.
-- ═══════════════════════════════════════════════════════════════════════════

data Doctor = Doctor
  { id   :: DoctorId
  , name :: Text
  }
  deriving (Show, Eq)

data Patient = Patient
  { id   :: PatientId
  , name :: Text
  }
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICE
-- Defines the canonical duration copied into each Slot at allocation time.
-- Deliberately unrelated to IntakeRequest's naming — this is the service
-- catalog, a broader concept than any one request's front-door path.
-- ═══════════════════════════════════════════════════════════════════════════

data HealthcareService = HealthcareService
  { id       :: HealthcareServiceId
  , name     :: Text
  , duration :: Duration
  }
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR REQUIREMENT
-- Structural absence on Emergency/Urgent: those tiers have no time slack to
-- spend waiting on a specific doctor. Only RoutineRequest carries this.
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorRequirement
  = AnyDoctor
  | SpecificDoctor DoctorId
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- PRIORITY / DUE CONSTRAINTS
--
-- Priority is assigned by a triager (doctor or qualified assistant), never
-- self-declared by the patient. Each tier carries a deadline: Emergency and
-- Urgent express "must be seen by X"; Routine expresses the appointment
-- window (or Anytime).
--
-- RoutineWithin excluded from exports — use mkRoutineWithin (enforces
-- from <= to, the only structural invariant in this module).
-- ═══════════════════════════════════════════════════════════════════════════

newtype EmergencyDue = EmergencyDue UTCTime
  deriving (Show, Eq, Ord)

newtype UrgentDue = UrgentDue UTCTime
  deriving (Show, Eq, Ord)

data RoutineDue
  = RoutineAnytime
  | RoutineNotBefore UTCTime
  | RoutineNotAfter  UTCTime
  | RoutineWithin    UTCTime UTCTime
  deriving (Show, Eq)

mkRoutineWithin :: UTCTime -> UTCTime -> Maybe RoutineDue
mkRoutineWithin from to
  | from <= to = Just (RoutineWithin from to)
  | otherwise  = Nothing

-- Read-only extraction over an already-valid value — cannot construct or
-- fabricate a RoutineWithin, so this does not reopen mkRoutineWithin's
-- from <= to invariant. Exists so downstream layers (e.g. Persistence) can
-- encode an in-memory RoutineDue without needing RoutineWithin's
-- constructor exported.
routineWithinBounds :: RoutineDue -> Maybe (UTCTime, UTCTime)
routineWithinBounds (RoutineWithin from to) = Just (from, to)
routineWithinBounds _                       = Nothing

-- Tighter/earlier constraints rank before looser ones.
-- RoutineWithin < RoutineNotAfter < RoutineNotBefore < RoutineAnytime
instance Ord RoutineDue where
  compare (RoutineWithin _ lhi) (RoutineWithin _ rhi) = compare lhi rhi
  compare (RoutineWithin _ _)   _                     = LT
  compare _                     (RoutineWithin _ _)   = GT
  compare (RoutineNotAfter l)   (RoutineNotAfter r)   = compare l r
  compare (RoutineNotAfter _)   _                     = LT
  compare _                     (RoutineNotAfter _)   = GT
  compare (RoutineNotBefore l)  (RoutineNotBefore r)  = compare l r
  compare (RoutineNotBefore _)  _                     = LT
  compare _                     (RoutineNotBefore _)  = GT
  compare RoutineAnytime        RoutineAnytime         = EQ

data IntakeRequestPriority
  = Emergency EmergencyDue
  | Urgent    UrgentDue
  | Routine   RoutineDue
  deriving (Show, Eq)

-- Emergency < Urgent < Routine; within tier, tighter deadline ranks first.
instance Ord IntakeRequestPriority where
  compare (Emergency l) (Emergency r) = compare l r
  compare (Emergency _) _             = LT
  compare _             (Emergency _) = GT
  compare (Urgent l)    (Urgent r)    = compare l r
  compare (Urgent _)    _             = LT
  compare _             (Urgent _)    = GT
  compare (Routine l)   (Routine r)   = compare l r

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST
--
-- IntakeRequest is the narrow front-door path from a patient's raw ask to a
-- single appointment — not a general "appointment" aggregate. Because the
-- request/appointment relationship is confirmed 1:1 permanently, there is no
-- separate Appointment type: the whole lifecycle (submitted through
-- closed/withdrawn/rejected) is one sum type under one identity,
-- IntakeRequestId, carried on SubmittedIntakeRequest and never reassigned.
--
-- Each stage embeds the prior stage whole and adds only the fields that
-- stage itself contributes — no type duplicates a fact another type already
-- owns. SubmittedIntakeRequest IS the base record; there is no separate
-- "Details" type underneath it. A prior draft split this into an
-- IntakeRequestDetails record plus a zero-field newtype wrapper around it —
-- that split was pure indirection with no invariant and no fan-out (no
-- sibling type needed the same fields with different extras) and has been
-- removed. Do not reintroduce it.
-- ═══════════════════════════════════════════════════════════════════════════

data SubmittedIntakeRequest = SubmittedIntakeRequest
  { id                :: IntakeRequestId
  , patientId         :: PatientId
  , narrative         :: Text
  , doctorRequirement :: DoctorRequirement
  , createdAt         :: UTCTime
  }
  deriving (Show, Eq)

data TriagedIntakeRequest = TriagedIntakeRequest
  { submitted           :: SubmittedIntakeRequest
  , healthcareServiceId :: HealthcareServiceId
  , priority             :: IntakeRequestPriority
  , triagedAt            :: UTCTime
  }
  deriving (Show, Eq)

data AppointedIntakeRequest = AppointedIntakeRequest
  { triaged  :: TriagedIntakeRequest
    -- ^ Also how a request is reclaimed back to Accepted — appointed.triaged
    -- is already that value; no dedicated reclaim function needed.
  , doctorId :: DoctorId
  , start    :: UTCTime
  , duration :: Duration
  }
  deriving (Show, Eq)

-- Only two cases, deliberately. Withdrawal only exists as a concept BEFORE
-- an appointment exists. There is no WithdrawnFromAppointed — ending an
-- Appointed request is always Closed (Cancelled ByPatient ...), since that
-- already asserts the identical fact (same precondition type, same
-- timestamp, "who ended it" already answered by AppointmentParty). Do not
-- add a third case here.
data WithdrawnIntakeRequest
  = WithdrawnFromSubmitted SubmittedIntakeRequest UTCTime (Maybe Text)
  | WithdrawnFromAccepted  TriagedIntakeRequest   UTCTime (Maybe Text)
  deriving (Show, Eq)

-- ByDoctor/ByPatient avoid collision with the real Doctor/Patient entity types.
data AppointmentParty
  = ByDoctor
  | ByPatient
  deriving (Show, Eq)

-- Stays nested under Closed, deliberately not flattened into top-level
-- IntakeRequest constructors — "why a closed appointment ended" is an
-- orthogonal axis to "what lifecycle stage this is," and flattening would
-- mix those two axes at one level. Do not promote Completed/Cancelled/
-- NoShow to IntakeRequest constructors.
--
-- Cancelled's UTCTime records when the cancellation occurred, distinct from
-- the appointment's own scheduled date (embedded via AppointedIntakeRequest
-- below) — not validated against it structurally; whether something is
-- Cancelled vs. NoShow is entirely the booking manager's judgment call,
-- recorded as given. The trailing Maybe Text on Cancelled is an optional
-- free-text reason, same shape as Rejected's/Withdrawn's own free-text notes.
data CloseReason
  = Completed
  | Cancelled AppointmentParty UTCTime (Maybe Text)
  | NoShow    AppointmentParty
  deriving (Show, Eq)

-- All of Rejected/Withdrawn/Closed are permanently terminal — no
-- transitions out of any of them. A displaced or redisplaced patient always
-- becomes a brand new IntakeRequest (new IntakeRequestId), never a
-- transition back out of a terminal case. Do not add one.
data IntakeRequest
  = Submitted SubmittedIntakeRequest
  | Rejected  SubmittedIntakeRequest UTCTime Text
  | Accepted  TriagedIntakeRequest
  | Appointed AppointedIntakeRequest
  | Withdrawn WithdrawnIntakeRequest
  | Closed    AppointedIntakeRequest CloseReason
  deriving (Show, Eq)

acceptIntakeRequest
  :: SubmittedIntakeRequest
  -> HealthcareServiceId
  -> IntakeRequestPriority
  -> UTCTime
  -> TriagedIntakeRequest
acceptIntakeRequest submitted healthcareServiceId priority triagedAt =
  TriagedIntakeRequest { submitted, healthcareServiceId, priority, triagedAt }

-- No rejectIntakeRequest function. Rejection is direct construction —
-- Rejected submitted rejectedAt reason — same precedent as
-- ClosedAppointment in prior revisions of this file: callers construct
-- directly, no dedicated close/reject function.

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT
-- A slot has no existence independent of matching: it is available until
-- claimed, then fully absorbed into the appointment. There is no post-booking
-- slot state, no freeing, and no sealed "proof" wrapper — matches is business
-- logic for trusted callers, not a guard against fabrication (an external
-- caller could already trivially construct a passing TriagedIntakeRequest,
-- so a sealed wrapper added no real protection).
-- ═══════════════════════════════════════════════════════════════════════════

data AvailableSlot = AvailableSlot
  { id                  :: SlotId
  , doctorId            :: DoctorId
  , healthcareServiceId :: HealthcareServiceId
  , start               :: UTCTime
  , duration            :: Duration
  }
  deriving (Show, Eq)

slotEnd :: AvailableSlot -> UTCTime
slotEnd s = addUTCTime (durationToNominalDiffTime s.duration) s.start

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTOCOL
-- ═══════════════════════════════════════════════════════════════════════════

matchesDoctorRequirement :: AvailableSlot -> DoctorRequirement -> Bool
matchesDoctorRequirement _    AnyDoctor              = True
matchesDoctorRequirement slot (SpecificDoctor reqId) = slot.doctorId == reqId

matchesTime :: IntakeRequestPriority -> UTCTime -> Bool
matchesTime (Emergency (EmergencyDue deadline))       slotStart = slotStart <= deadline
matchesTime (Urgent    (UrgentDue    deadline))       slotStart = slotStart <= deadline
matchesTime (Routine   RoutineAnytime)                _         = True
matchesTime (Routine   (RoutineNotBefore earliest))   slotStart = slotStart >= earliest
matchesTime (Routine   (RoutineNotAfter  latest))     slotStart = slotStart <= latest
matchesTime (Routine   (RoutineWithin earliest latest)) slotStart =
  slotStart >= earliest && slotStart <= latest

matches :: AvailableSlot -> TriagedIntakeRequest -> Bool
matches slot TriagedIntakeRequest { healthcareServiceId, priority, submitted } =
     slot.healthcareServiceId == healthcareServiceId
  && matchesDoctorRequirement slot submitted.doctorRequirement
  && matchesTime priority slot.start

matchIntakeRequestToSlot
  :: AvailableSlot
  -> TriagedIntakeRequest
  -> Maybe AppointedIntakeRequest
matchIntakeRequestToSlot slot triaged
  | matches slot triaged =
      Just AppointedIntakeRequest
        { triaged
        , doctorId = slot.doctorId
        , start    = slot.start
        , duration = slot.duration
        }
  | otherwise = Nothing

checkIntakeWaitlist
  :: AvailableSlot
  -> [TriagedIntakeRequest]
  -> Maybe AppointedIntakeRequest
checkIntakeWaitlist slot =
  listToMaybe . mapMaybe (matchIntakeRequestToSlot slot) . sortOn priority
