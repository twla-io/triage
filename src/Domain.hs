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
  , HealthcareRequestPriority (..)

  -- ── Healthcare Request ───────────────────────────────────────────────────
  , HealthcareRequestDetails (..)
  , TriagedHealthcareRequest (..)
  , HealthcareRequest (..)
  , triageHealthcareRequest

  -- ── Slot ─────────────────────────────────────────────────────────────────
  , SlotDetails (..)
  , AvailableSlot (..)
  , BookedSlot
  , Slot (..)
  , freeSlot
  , slotEnd
  , getSlotDetails
  , bookedAppointmentId

  -- ── Appointment ──────────────────────────────────────────────────────────
  , OpenAppointment (..)  -- constructor open — no invariant to protect
  , ClosedAppointment
  , Appointment (..)
  , AppointmentParty (..)
  , CloseReason (..)
  , closeAppointment
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
-- Two states: Available (open for matching) or Booked. No Pending or Offered
-- — every appointment originates from a TriagedHealthcareRequest, so a slot
-- either has a match or stays Available until one arrives.
-- ═══════════════════════════════════════════════════════════════════════════

data SlotDetails = SlotDetails
  { id                  :: SlotId
  , doctorId            :: DoctorId
  , healthcareServiceId :: HealthcareServiceId
  , start               :: UTCTime
  , duration            :: Duration
  }
  deriving (Show, Eq)

newtype AvailableSlot = AvailableSlot SlotDetails
  deriving (Show, Eq)

data BookedSlot = BookedSlot SlotDetails AppointmentId
  deriving (Show, Eq)

data Slot
  = Available AvailableSlot
  | Booked    BookedSlot
  deriving (Show, Eq)

-- Appointment cancelled: slot re-enters the matching protocol immediately.
freeSlot :: BookedSlot -> AvailableSlot
freeSlot (BookedSlot d _) = AvailableSlot d

slotEnd :: SlotDetails -> UTCTime
slotEnd d = addUTCTime (durationToNominalDiffTime d.duration) d.start

getSlotDetails :: Slot -> SlotDetails
getSlotDetails (Available (AvailableSlot d)) = d
getSlotDetails (Booked    (BookedSlot d _))  = d

-- BookedSlot is positional — no dot-access to its AppointmentId externally.
bookedAppointmentId :: BookedSlot -> AppointmentId
bookedAppointmentId (BookedSlot _ aid) = aid

-- ═══════════════════════════════════════════════════════════════════════════
-- APPOINTMENT
-- OpenAppointment embeds the full TriagedHealthcareRequest — the appointment
-- IS the request, now bound to a slot. No separate patientId/priority fields:
-- one fact in one place, no duplication.
-- ═══════════════════════════════════════════════════════════════════════════

data OpenAppointment =
  OpenAppointment AppointmentId TriagedHealthcareRequest SlotId
  deriving (Show, Eq)

-- ByDoctor/ByPatient avoid collision with the real Doctor/Patient entity types.
data AppointmentParty
  = ByDoctor
  | ByPatient
  deriving (Show, Eq)

data CloseReason
  = Completed
  | Cancelled   AppointmentParty
  | NoShow      AppointmentParty
  deriving (Show, Eq)

-- Embeds the OpenAppointment — closing carries its full history for free.
data ClosedAppointment = ClosedAppointment OpenAppointment CloseReason
  deriving (Show, Eq)

data Appointment
  = Open   OpenAppointment
  | Closed ClosedAppointment
  deriving (Show, Eq)

-- The embedded request is the single source of truth for patient/priority.
openAppointmentRequest :: OpenAppointment -> TriagedHealthcareRequest
openAppointmentRequest (OpenAppointment _ req _) = req

closeAppointment :: OpenAppointment -> CloseReason -> ClosedAppointment
closeAppointment = ClosedAppointment

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
-- those are never overridable, even by a manager.
--
-- reassignSlot moves an already-open appointment to a different slot,
-- re-checking the same structural eligibility against the proposed slot.
-- ═══════════════════════════════════════════════════════════════════════════

matchesDoctorRequirement :: SlotDetails -> DoctorRequirement -> Bool
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
matches (AvailableSlot slot) TriagedHealthcareRequest { healthcareServiceId, priority, details } =
     slot.healthcareServiceId == healthcareServiceId
  && matchesDoctorRequirement slot details.doctorRequirement
  && matchesTime priority slot.start

satisfyHealthcareRequest
  :: AvailableSlot
  -> AppointmentId
  -> TriagedHealthcareRequest
  -> Maybe (BookedSlot, OpenAppointment)
satisfyHealthcareRequest available@(AvailableSlot slot) appointmentId request
  | matches available request =
      Just
        ( BookedSlot slot appointmentId
        , OpenAppointment appointmentId request slot.id
        )
  | otherwise = Nothing

reassignSlot
  :: OpenAppointment
  -> BookedSlot      -- appointment's current slot; caller's responsibility to pass the correct one, not checked here
  -> AvailableSlot   -- proposed new slot
  -> Maybe (AvailableSlot, BookedSlot, OpenAppointment)
reassignSlot (OpenAppointment aid req _) (BookedSlot oldDetails _) newSlot
  | matches newSlot req =
      let newDetails = getSlotDetails (Available newSlot)
      in Just
           ( AvailableSlot oldDetails
           , BookedSlot newDetails aid
           , OpenAppointment aid req newDetails.id
           )
  | otherwise = Nothing

checkWaitlist
  :: AvailableSlot
  -> AppointmentId
  -> [TriagedHealthcareRequest]
  -> Maybe (BookedSlot, OpenAppointment)
checkWaitlist slot appointmentId =
  listToMaybe
    . mapMaybe (satisfyHealthcareRequest slot appointmentId)
    . sortOn priority