{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- For conventions on generating downstream layers from these types, see:
--   triage-db-codegen  — database schema generation
--   triage-api-codegen — REST/GraphQL/RPC API generation
--   triage-ui-codegen  — frontend UI/UX generation
-- Read the relevant skill before generating any of these from this module.

module Domain
  ( -- ── ID wrappers ───────────────────────────────────────────────────────
    DoctorId (..)
  , PatientId (..)
  , HealthcareServiceId (..)
  , HealthcareRequestId (..)
  , SlotId (..)
  , AppointmentId (..)

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
  , HealthcareRequestPriority (..)

  -- ── Healthcare Request ───────────────────────────────────────────────────
  , HealthcareRequestDetails (..)
  , TriagedHealthcareRequest (..)
  , HealthcareRequest (..)
  , triageHealthcareRequest

  -- ── Slot ─────────────────────────────────────────────────────────────────
  , AvailableSlot (..)
  , slotEnd

  -- ── Appointment ──────────────────────────────────────────────────────────
  , OpenAppointment (..)  -- constructor open — no invariant to protect
  , ClosedAppointment (..)  -- constructor open — no invariant to protect
  , Appointment (..)
  , AppointmentParty (..)
  , CloseReason (..)
  , openAppointmentRequest

  -- ── Protocol ─────────────────────────────────────────────────────────────
  , satisfyHealthcareRequest
  , reassignSlot
  , checkWaitlist
  , matches
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
newtype HealthcareRequestId = HealthcareRequestId UUID deriving (Show, Eq, Ord)
newtype SlotId              = SlotId              UUID deriving (Show, Eq, Ord)
newtype AppointmentId       = AppointmentId       UUID deriving (Show, Eq, Ord)

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
-- from <= to, the same structural invariant as the old mkWithin).
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

data HealthcareRequestPriority
  = Emergency EmergencyDue
  | Urgent    UrgentDue
  | Routine   RoutineDue
  deriving (Show, Eq)

-- Emergency < Urgent < Routine; within tier, tighter deadline ranks first.
instance Ord HealthcareRequestPriority where
  compare (Emergency l) (Emergency r) = compare l r
  compare (Emergency _) _             = LT
  compare _             (Emergency _) = GT
  compare (Urgent l)    (Urgent r)    = compare l r
  compare (Urgent _)    _             = LT
  compare _             (Urgent _)    = GT
  compare (Routine l)   (Routine r)   = compare l r

-- ═══════════════════════════════════════════════════════════════════════════
-- HEALTHCARE REQUEST
--
-- Submitted: patient describes need via narrative — no service or priority
-- yet; the patient doesn't know those. Triaged: a qualified triager has
-- assigned service and priority. Only Triaged requests can be matched to
-- slots and become appointments.
-- Triage is a trusted human judgment — deadline sanity relative to
-- triagedAt is clinical judgment, not a structural invariant to enforce here
-- (unlike mkRoutineWithin's from <= to, which is incoherent at any scale).
-- ═══════════════════════════════════════════════════════════════════════════

data HealthcareRequestDetails = HealthcareRequestDetails
  { id                :: HealthcareRequestId
  , patientId         :: PatientId
  , narrative         :: Text
  , doctorRequirement :: DoctorRequirement
  , createdAt         :: UTCTime
  }
  deriving (Show, Eq)

data TriagedHealthcareRequest = TriagedHealthcareRequest
  { details             :: HealthcareRequestDetails
  , healthcareServiceId :: HealthcareServiceId
  , priority            :: HealthcareRequestPriority
  , triagedAt           :: UTCTime
  }
  deriving (Show, Eq)

data HealthcareRequest
  = Submitted HealthcareRequestDetails
  | Triaged   TriagedHealthcareRequest
  deriving (Show, Eq)

triageHealthcareRequest
  :: HealthcareRequestDetails
  -> HealthcareServiceId
  -> HealthcareRequestPriority
  -> UTCTime
  -> TriagedHealthcareRequest
triageHealthcareRequest details healthcareServiceId priority triagedAt =
  TriagedHealthcareRequest { details, healthcareServiceId, priority, triagedAt }

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT
-- A slot has no existence independent of matching: it is available until
-- claimed, then fully absorbed into the appointment. There is no post-booking
-- slot state, no freeing, and no sealed "proof" wrapper — matches is business
-- logic for trusted callers, not a guard against fabrication (an external
-- caller could already trivially construct a passing TriagedHealthcareRequest,
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
-- APPOINTMENT
-- OpenAppointment embeds the full TriagedHealthcareRequest — the appointment
-- IS the request, now bound to a slot. No separate patientId/priority fields:
-- one fact in one place, no duplication. It hard-copies the doctor/time/
-- duration facts at the moment of matching rather than referencing a slot of
-- any kind — the original slot ceases to be referenced or exist once matched.
-- ═══════════════════════════════════════════════════════════════════════════

data OpenAppointment =
  OpenAppointment AppointmentId TriagedHealthcareRequest DoctorId UTCTime Duration
  deriving (Show, Eq)

-- ByDoctor/ByPatient avoid collision with the real Doctor/Patient entity types.
data AppointmentParty
  = ByDoctor
  | ByPatient
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- CLOSE REASON
-- Cancelled carries when the cancellation occurred, distinct from the
-- appointment's own scheduled date (embedded via OpenAppointment below).
-- There is no structural check relating this timestamp to the appointment's
-- date — whether something is Cancelled vs. NoShow is entirely the booking
-- manager's judgment call, recorded as given, not re-derived or validated.
-- ═══════════════════════════════════════════════════════════════════════════

data CloseReason
  = Completed
  | Cancelled AppointmentParty UTCTime  -- when the cancellation occurred; not validated against the appointment's date — the manager's call
  | NoShow    AppointmentParty
  deriving (Show, Eq)

-- Embeds the OpenAppointment unchanged — closing carries its full history
-- for free, with nothing left to duplicate or go stale, since
-- OpenAppointment no longer asserts any live/mutable state. Constructor
-- open — no invariant to protect. Closing an appointment is direct
-- construction of ClosedAppointment (ClosedAppointment oa reason); there is
-- no dedicated function.
data ClosedAppointment = ClosedAppointment OpenAppointment CloseReason
  deriving (Show, Eq)

data Appointment
  = Open   OpenAppointment
  | Closed ClosedAppointment
  deriving (Show, Eq)

-- The embedded request is the single source of truth for patient/priority.
openAppointmentRequest :: OpenAppointment -> TriagedHealthcareRequest
openAppointmentRequest (OpenAppointment _ req _ _ _) = req

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTOCOL
--
-- Every appointment originates from a TriagedHealthcareRequest. Requests are
-- tried in priority order (tightest deadline first); the first eligible match
-- commits atomically. No intermediate offer/accept step.
--
-- satisfyHealthcareRequest checks eligibility AND commits. It can be called
-- directly by a manager to bypass the automatic scan while still enforcing
-- structural eligibility (service match, doctor requirement, time window) —
-- those are never overridable, even by a manager. It returns the
-- OpenAppointment alone: the matched slot's doctor/time/duration facts are
-- copied once into the appointment at the moment of booking, and the
-- original slot ceases to be referenced or exist thereafter. checkWaitlist,
-- built on top of it, follows the same shape.
--
-- reassignSlot moves an already-open appointment to a different slot,
-- re-checking the same structural eligibility against the proposed slot. The
-- old slot/appointment facts are simply discarded, not freed or returned; if
-- the vacated time should become bookable again, that's a new AvailableSlot
-- created independently elsewhere, not this function's concern.
--
-- There is no post-close slot recreation logic in Domain.hs — that's always
-- a fresh AvailableSlot, decided by the caller. Closing an appointment is
-- direct construction of ClosedAppointment, no dedicated function.
-- ═══════════════════════════════════════════════════════════════════════════

matchesDoctorRequirement :: AvailableSlot -> DoctorRequirement -> Bool
matchesDoctorRequirement _    AnyDoctor              = True
matchesDoctorRequirement slot (SpecificDoctor reqId) = slot.doctorId == reqId

matchesTime :: HealthcareRequestPriority -> UTCTime -> Bool
matchesTime (Emergency (EmergencyDue deadline))       slotStart = slotStart <= deadline
matchesTime (Urgent    (UrgentDue    deadline))       slotStart = slotStart <= deadline
matchesTime (Routine   RoutineAnytime)                _         = True
matchesTime (Routine   (RoutineNotBefore earliest))   slotStart = slotStart >= earliest
matchesTime (Routine   (RoutineNotAfter  latest))     slotStart = slotStart <= latest
matchesTime (Routine   (RoutineWithin earliest latest)) slotStart =
  slotStart >= earliest && slotStart <= latest

matches :: AvailableSlot -> TriagedHealthcareRequest -> Bool
matches slot TriagedHealthcareRequest { healthcareServiceId, priority, details } =
     slot.healthcareServiceId == healthcareServiceId
  && matchesDoctorRequirement slot details.doctorRequirement
  && matchesTime priority slot.start

satisfyHealthcareRequest
  :: AvailableSlot
  -> AppointmentId
  -> TriagedHealthcareRequest
  -> Maybe OpenAppointment
satisfyHealthcareRequest slot appointmentId request
  | matches slot request =
      Just (OpenAppointment appointmentId request slot.doctorId slot.start slot.duration)
  | otherwise = Nothing

reassignSlot :: OpenAppointment -> AvailableSlot -> Maybe OpenAppointment
reassignSlot (OpenAppointment aid req _ _ _) newSlot = satisfyHealthcareRequest newSlot aid req

checkWaitlist
  :: AvailableSlot
  -> AppointmentId
  -> [TriagedHealthcareRequest]
  -> Maybe OpenAppointment
checkWaitlist slot appointmentId =
  listToMaybe
    . mapMaybe (satisfyHealthcareRequest slot appointmentId)
    . sortOn priority