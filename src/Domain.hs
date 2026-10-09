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

  -- ── Name ─────────────────────────────────────────────────────────────────
  , Name                         -- sealed: not empty or only whitespace
  , mkName
  , nameText

  -- ── Doctor / Patient ─────────────────────────────────────────────────────
  , Doctor (..)
  , Patient (..)

  -- ── Healthcare Service ───────────────────────────────────────────────────
  , HealthcareService (..)

  -- ── Doctor Requirement ───────────────────────────────────────────────────
  , DoctorRequirement (..)

  -- ── Priority / Due constraints ───────────────────────────────────────────
  , MustBeSeenBy (..)
  , RoutineDue (..)
  , RoutineWindow                -- sealed: routineNotBefore <= routineNotAfter
  , mkRoutineWindow
  , routineNotBefore
  , routineNotAfter
  , IntakeRequestPriority (..)

  -- ── Intake Request ───────────────────────────────────────────────────────
  , SubmittedIntakeRequest (..)  -- constructor open — no invariant to protect
  , RejectedIntakeRequest (..)   -- constructor open — no invariant to protect
  , TriagedIntakeRequest (..)    -- constructor open — no invariant to protect
  , AppointedIntakeRequest (..)  -- constructor open — no invariant to protect
  , WithdrawnIntakeRequest (..)  -- constructor open — no invariant to protect
  , WithdrawnFrom (..)
  , StaleIntakeRequest (..)      -- constructor open — no invariant to protect
  , ClosedIntakeRequest (..)     -- constructor open — no invariant to protect
  , AppointmentParty (..)
  , Cancellation (..)
  , Absence (..)
  , CloseReason (..)
  , IntakeRequest (..)           -- constructor open — no invariant to protect
  , acceptIntakeRequest

  -- ── Slot ─────────────────────────────────────────────────────────────────
  , AvailableSlot (..)

  -- ── Doctor Calendar ──────────────────────────────────────────────────────
  , DoctorCalendarEntry (..)
  , doctorCalendarEntryStart
  , DoctorCalendar             -- sealed: a doctor's entries never overlap
  , mkDoctorCalendar
  , doctorCalendarEntries
  , addAvailableSlot

  -- ── Protocol ─────────────────────────────────────────────────────────────
  , matches
  , matchIntakeRequestToSlot
  , sortByPriority
  , matchByPriority
  ) where

import Control.Monad   (foldM)
import Data.Char       (isSpace)
import Data.List       (sortOn)
import Data.Map.Strict (Map)
import Data.Maybe      (listToMaybe, mapMaybe)
import Data.Text       (Text)
import Data.Time       (NominalDiffTime, UTCTime, addUTCTime)
import Data.UUID       (UUID)

import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

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
  deriving (Show, Eq, Enum, Bounded)

durationToNominalDiffTime :: Duration -> NominalDiffTime
durationToNominalDiffTime QuarterOfAnHour = 900
durationToNominalDiffTime HalfAnHour      = 1800
durationToNominalDiffTime OneHour         = 3600

-- ═══════════════════════════════════════════════════════════════════════════
-- NAME
-- Name's constructor excluded from exports — use mkName (refuses text that
-- is empty or only whitespace).
-- ═══════════════════════════════════════════════════════════════════════════

newtype Name = Name Text
  deriving (Show, Eq)

mkName :: Text -> Maybe Name
mkName t
  | T.all isSpace t = Nothing
  | otherwise       = Just (Name t)

nameText :: Name -> Text
nameText (Name t) = t

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT
-- Deliberately minimal — expected to move to a separate system later.
-- ═══════════════════════════════════════════════════════════════════════════

data Doctor = Doctor
  { id   :: DoctorId
  , name :: Name
  }
  deriving (Show, Eq)

data Patient = Patient
  { id   :: PatientId
  , name :: Name
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
  , name     :: Name
  , duration :: Duration
  }
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR REQUIREMENT
-- Decided at triage (TriagedIntakeRequest.doctorRequirement), for any
-- priority; a patient's preference is part of the narrative, not a typed
-- field. An Emergency or Urgent request waits for a specific doctor only if
-- triage sets one.
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
-- A constructor with a single field names that field's value
-- (RoutineNotBefore t: t is the routine's not-before bound).
--
-- RoutineWindow's constructor excluded from exports — use mkRoutineWindow
-- (enforces routineNotBefore <= routineNotAfter).
-- ═══════════════════════════════════════════════════════════════════════════

newtype MustBeSeenBy = MustBeSeenBy UTCTime
  deriving (Show, Eq, Ord)

data RoutineDue
  = RoutineAnytime
  | RoutineNotBefore UTCTime
  | RoutineNotAfter  UTCTime
  | RoutineWithin    RoutineWindow
  deriving (Show, Eq)

-- Positional, constructor not exported: record fields would let record
-- update bypass mkRoutineWindow. The accessors below name its values.
data RoutineWindow = RoutineWindow UTCTime UTCTime
  deriving (Show, Eq)

mkRoutineWindow :: UTCTime -> UTCTime -> Maybe RoutineWindow
mkRoutineWindow notBefore notAfter
  | notBefore <= notAfter = Just (RoutineWindow notBefore notAfter)
  | otherwise             = Nothing

routineNotBefore, routineNotAfter :: RoutineWindow -> UTCTime
routineNotBefore (RoutineWindow notBefore _) = notBefore
routineNotAfter  (RoutineWindow _ notAfter)  = notAfter

-- Tighter/earlier constraints rank before looser ones.
-- RoutineWithin < RoutineNotAfter < RoutineNotBefore < RoutineAnytime
-- Between two RoutineWithin windows: earlier upper bound first; on equal
-- upper bounds, the narrower window (later lower bound) first. Compares
-- EQ exactly when the windows are equal, consistent with derived Eq.
instance Ord RoutineDue where
  compare (RoutineWithin l) (RoutineWithin r) =
    compare (routineNotAfter l) (routineNotAfter r) <> compare (routineNotBefore r) (routineNotBefore l)
  compare (RoutineWithin _)     _                     = LT
  compare _                     (RoutineWithin _)     = GT
  compare (RoutineNotAfter l)   (RoutineNotAfter r)   = compare l r
  compare (RoutineNotAfter _)   _                     = LT
  compare _                     (RoutineNotAfter _)   = GT
  compare (RoutineNotBefore l)  (RoutineNotBefore r)  = compare l r
  compare (RoutineNotBefore _)  _                     = LT
  compare _                     (RoutineNotBefore _)  = GT
  compare RoutineAnytime        RoutineAnytime         = EQ

data IntakeRequestPriority
  = Emergency MustBeSeenBy
  | Urgent    MustBeSeenBy
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
  , createdAt         :: UTCTime
  }
  deriving (Show, Eq)

data RejectedIntakeRequest = RejectedIntakeRequest
  { submitted       :: SubmittedIntakeRequest
  , rejectedAt      :: UTCTime
  , rejectionReason :: Text
  }
  deriving (Show, Eq)

data TriagedIntakeRequest = TriagedIntakeRequest
  { submitted           :: SubmittedIntakeRequest
  , healthcareServiceId :: HealthcareServiceId
  , priority             :: IntakeRequestPriority
  , doctorRequirement    :: DoctorRequirement
  , triagedAt            :: UTCTime
  }
  deriving (Show, Eq)

data AppointedIntakeRequest = AppointedIntakeRequest
  { triaged  :: TriagedIntakeRequest
  , doctorId :: DoctorId
  , start    :: UTCTime
  , duration :: Duration
  }
  deriving (Show, Eq)

data WithdrawnIntakeRequest = WithdrawnIntakeRequest
  { withdrawnFrom  :: WithdrawnFrom
  , withdrawnAt    :: UTCTime
  , withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

-- Only two cases, deliberately. Withdrawal only exists as a concept BEFORE
-- an appointment exists. There is no FromAppointed — ending an Appointed
-- request is always Closed with a Cancellation cancelledBy PatientParty,
-- which already asserts the identical fact. Do not add a third case here.
data WithdrawnFrom
  = FromSubmitted SubmittedIntakeRequest
  | FromAccepted  TriagedIntakeRequest
  deriving (Show, Eq)

data StaleIntakeRequest = StaleIntakeRequest
  { triaged :: TriagedIntakeRequest
  , staleAt :: UTCTime
  }
  deriving (Show, Eq)

-- DoctorParty/PatientParty avoid collision with the Doctor/Patient entity
-- constructors.
data AppointmentParty
  = DoctorParty
  | PatientParty
  deriving (Show, Eq, Enum, Bounded)

-- cancelledAt is when the cancellation occurred, not the appointment's own
-- start — not validated against it. Cancelled vs. NoShow is the booking
-- manager's judgment call, recorded as given.
data Cancellation = Cancellation
  { cancelledBy      :: AppointmentParty
  , cancelledAt      :: UTCTime
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

-- What absentParty means is an open question for the domain expert
-- (docs/decisions.md): it is kept a separate fact from cancelledBy.
newtype Absence = Absence
  { absentParty :: AppointmentParty
  }
  deriving (Show, Eq)

-- Stays nested under Closed, deliberately not flattened into top-level
-- IntakeRequest constructors — "why a closed appointment ended" is an
-- orthogonal axis to "what lifecycle stage this is," and flattening would
-- mix those two axes at one level. Do not promote Completed/Cancelled/
-- NoShow to IntakeRequest constructors.
data CloseReason
  = Completed
  | Cancelled Cancellation
  | NoShow    Absence
  deriving (Show, Eq)

data ClosedIntakeRequest = ClosedIntakeRequest
  { appointed   :: AppointedIntakeRequest
  , closeReason :: CloseReason
  }
  deriving (Show, Eq)

-- All of Rejected/Withdrawn/Stale/Closed are permanently terminal — no
-- transitions out of any of them. Do not add one. A patient who needs to be
-- seen again after a terminal case gets a brand new IntakeRequest (new
-- IntakeRequestId). That includes a patient displaced or rescheduled from
-- an appointment: it is Closed (Cancelled ...), then a new request follows.
--
-- Stale is reachable only from Accepted: staff manually recognizing that an
-- accepted request never got matched to a slot and never got withdrawn, and
-- closing it out. It is never an automatic, timer-driven transition — no
-- code anywhere should trigger this on its own; it is always an explicit,
-- staff-initiated action, same trust-in-human-judgment pattern as
-- AppointmentParty's Cancelled-vs-NoShow distinction. Not reachable from
-- Submitted — a due date doesn't exist before triage, so "stale" is
-- structurally meaningless there. No dedicated markIntakeRequestStale
-- function exists in this module — direct construction only
-- (Stale StaleIntakeRequest { triaged, staleAt }), same precedent as
-- Rejected. Its only precondition is "this was Accepted", which belongs in
-- Service.hs's fetch-then-check wrapper, not here.
data IntakeRequest
  = Submitted SubmittedIntakeRequest
  | Rejected  RejectedIntakeRequest
  | Accepted  TriagedIntakeRequest
  | Appointed AppointedIntakeRequest
  | Withdrawn WithdrawnIntakeRequest
  | Stale     StaleIntakeRequest
  | Closed    ClosedIntakeRequest
  deriving (Show, Eq)

acceptIntakeRequest
  :: SubmittedIntakeRequest
  -> HealthcareServiceId
  -> IntakeRequestPriority
  -> DoctorRequirement
  -> UTCTime
  -> TriagedIntakeRequest
acceptIntakeRequest submitted healthcareServiceId priority doctorRequirement triagedAt =
  TriagedIntakeRequest { submitted, healthcareServiceId, priority, doctorRequirement, triagedAt }

-- No rejectIntakeRequest function. Rejection is direct construction —
-- Rejected RejectedIntakeRequest { submitted, rejectedAt, rejectionReason }
-- — as closing is: callers construct directly, no dedicated close/reject
-- function.

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT
-- A slot has no existence independent of matching: it is available until
-- claimed, then fully absorbed into the appointment. There is no post-booking
-- slot state, no freeing, and no sealed "proof" wrapper — matches is business
-- logic for trusted callers, not a guard against fabrication (an external
-- caller could already trivially construct a passing TriagedIntakeRequest,
-- so a sealed wrapper added no real protection). A new slot is created with
-- addAvailableSlot (DOCTOR CALENDAR, below), which checks it against the
-- doctor's calendar and takes its duration from its service.
-- ═══════════════════════════════════════════════════════════════════════════

data AvailableSlot = AvailableSlot
  { id                  :: SlotId
  , doctorId            :: DoctorId
  , healthcareServiceId :: HealthcareServiceId
  , start               :: UTCTime
  , duration            :: Duration
  }
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR CALENDAR
-- Everything that occupies a doctor's time: available slots and appointed
-- intake requests. No two entries of the same doctor may overlap; entries
-- occupy half-open intervals [start, end), so touching is not overlapping.
--
-- DoctorCalendar's constructor excluded from exports — build it only via
-- mkDoctorCalendar (from existing entries) and grow it only via
-- addAvailableSlot: a slot is the only thing ever added to a calendar;
-- appointments arrive by matching, which takes over its slot's exact
-- interval. Both enforce the no-overlap invariant for the value they build.
-- Read it via doctorCalendarEntries; reading can't break the invariant.
-- A value cannot prove it matches what is currently stored, so stored data
-- needs this same invariant enforced where it lives.
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorCalendarEntry
  = Slot        AvailableSlot
  | Appointment AppointedIntakeRequest
  deriving (Show, Eq)

doctorCalendarEntryDoctor :: DoctorCalendarEntry -> DoctorId
doctorCalendarEntryDoctor (Slot s)        = s.doctorId
doctorCalendarEntryDoctor (Appointment a) = a.doctorId

doctorCalendarEntryStart :: DoctorCalendarEntry -> UTCTime
doctorCalendarEntryStart (Slot s)        = s.start
doctorCalendarEntryStart (Appointment a) = a.start

doctorCalendarEntryDuration :: DoctorCalendarEntry -> Duration
doctorCalendarEntryDuration (Slot s)        = s.duration
doctorCalendarEntryDuration (Appointment a) = a.duration

doctorCalendarEntryEnd :: DoctorCalendarEntry -> UTCTime
doctorCalendarEntryEnd e =
  addUTCTime (durationToNominalDiffTime (doctorCalendarEntryDuration e)) (doctorCalendarEntryStart e)

-- Keyed by start within each doctor: non-overlapping entries of non-zero
-- duration never share a start.
newtype DoctorCalendar =
  DoctorCalendar (Map DoctorId (Map UTCTime DoctorCalendarEntry))
  deriving (Show, Eq)

mkDoctorCalendar :: [DoctorCalendarEntry] -> Maybe DoctorCalendar
mkDoctorCalendar = foldM addDoctorCalendarEntry (DoctorCalendar Map.empty)

-- In order of start; entries starting together keep doctor order.
doctorCalendarEntries :: DoctorCalendar -> [DoctorCalendarEntry]
doctorCalendarEntries (DoctorCalendar calendar) =
  sortOn doctorCalendarEntryStart (concatMap Map.elems (Map.elems calendar))

-- A new slot for this doctor at this time, lasting as long as its service.
-- Nothing if it would overlap one of the doctor's entries.
addAvailableSlot
  :: DoctorCalendar -> SlotId -> DoctorId -> HealthcareService -> UTCTime
  -> Maybe (AvailableSlot, DoctorCalendar)
addAvailableSlot calendar slotId doctorId service start =
  (\grown -> (slot, grown)) <$> addDoctorCalendarEntry calendar (Slot slot)
  where
    slot = AvailableSlot
      { id = slotId, doctorId, healthcareServiceId = service.id, start, duration = service.duration }

-- Only the nearest neighbour on each side needs checking: the existing
-- entries already don't overlap, so the one starting just before ends
-- latest among all earlier ones.
addDoctorCalendarEntry :: DoctorCalendar -> DoctorCalendarEntry -> Maybe DoctorCalendar
addDoctorCalendarEntry (DoctorCalendar calendar) entry
  | clashesWithPrevious || clashesWithNext = Nothing
  | otherwise = Just . DoctorCalendar $
      Map.insert doctor (Map.insert start entry own) calendar
  where
    doctor = doctorCalendarEntryDoctor entry
    start  = doctorCalendarEntryStart entry
    end    = doctorCalendarEntryEnd entry
    own    = Map.findWithDefault Map.empty doctor calendar
    clashesWithPrevious =
      maybe False (\(_, prev) -> doctorCalendarEntryEnd prev > start) (Map.lookupLT start own)
    clashesWithNext =
      maybe False (\(next, _) -> next < end) (Map.lookupGE start own)

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTOCOL
-- ═══════════════════════════════════════════════════════════════════════════

matchesDoctorRequirement :: AvailableSlot -> DoctorRequirement -> Bool
matchesDoctorRequirement _    AnyDoctor              = True
matchesDoctorRequirement slot (SpecificDoctor reqId) = slot.doctorId == reqId

matchesTime :: IntakeRequestPriority -> UTCTime -> Bool
matchesTime (Emergency (MustBeSeenBy deadline))       slotStart = slotStart <= deadline
matchesTime (Urgent    (MustBeSeenBy deadline))       slotStart = slotStart <= deadline
matchesTime (Routine   RoutineAnytime)                _         = True
matchesTime (Routine   (RoutineNotBefore earliest))   slotStart = slotStart >= earliest
matchesTime (Routine   (RoutineNotAfter  latest))     slotStart = slotStart <= latest
matchesTime (Routine   (RoutineWithin window))       slotStart =
  slotStart >= routineNotBefore window && slotStart <= routineNotAfter window

matches :: AvailableSlot -> TriagedIntakeRequest -> Bool
matches slot TriagedIntakeRequest { healthcareServiceId, priority, doctorRequirement } =
     slot.healthcareServiceId == healthcareServiceId
  && matchesDoctorRequirement slot doctorRequirement
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

-- Highest priority first; among equal priorities, the earlier triaged, then
-- the earlier submitted.
sortByPriority :: [TriagedIntakeRequest] -> [TriagedIntakeRequest]
sortByPriority = sortOn (\r -> (r.priority, r.triagedAt, r.submitted.createdAt))

matchByPriority
  :: AvailableSlot
  -> [TriagedIntakeRequest]
  -> Maybe AppointedIntakeRequest
matchByPriority slot =
  listToMaybe . mapMaybe (matchIntakeRequestToSlot slot) . sortByPriority
