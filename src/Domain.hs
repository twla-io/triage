{-# LANGUAGE DuplicateRecordFields #-}
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
  , ServiceId (..)
  , SlotId (..)
  , AppointmentId (..)
  , AppointmentRequestId (..)

  -- ── Duration ─────────────────────────────────────────────────────────────
  , Duration (..)
  , durationToNominalDiffTime

  -- ── Service ──────────────────────────────────────────────────────────────
  , Service (..)

  -- ── Doctor / Patient ─────────────────────────────────────────────────────
  , Doctor (..)
  , Patient (..)

  -- ── AppointmentPriority ──────────────────────────────────────────────────
  , AppointmentPriority (..)
  , DueAt (Anytime, NotBefore, NotAfter)   -- Within excluded — use mkWithin
  , mkWithin
  -- Queries (pure, read-only)
  , satisfiesDueAt

  -- ── Slot ─────────────────────────────────────────────────────────────────
  , SlotDetails (..)
  , PendingSlot (..)      -- constructor open: no invariant left to protect here since declinedBy is gone
  , AvailableSlot         -- constructor hidden — use releaseSlot; existence proves a PendingSlot was released
  , BookedSlot            -- constructor hidden — use bookAppointment or assignAppointment; existence proves Pending -> Available -> Booked, with a matching Appointment
  , Slot (..)
  -- Commands (state transitions)
  , freeSlot
  , releaseSlot
  -- Queries (pure, read-only)
  , slotEnd
  , getSlotDetails
  , appointmentId

  -- ── Appointment ──────────────────────────────────────────────────────────
  , AppointmentDetails (..)
  , AppointmentParty (..)
  , CloseReason (..)
  , OpenAppointment       -- constructor hidden — use bookAppointment or assignAppointment
  , ClosedAppointment     -- constructor hidden — use closeAppointment
  , Appointment (..)
  -- Commands (state transitions)
  , closeAppointment
  -- Commands (spans two aggregates — both halves must be persisted together)
  , bookAppointment
  , assignAppointment
  -- Queries (pure, read-only)
  , openAppointmentDetails

  -- ── Waitlist ─────────────────────────────────────────────────────────────
  , AppointmentRequestDetails (..)
  , AppointmentRequest (..)
  -- Queries (pure, read-only)
  , requestId
  , detailsOf
  , priorityOf
  , bestMatch

  -- ── Protocol ─────────────────────────────────────────────────────────────
  , MatchAppointmentRequestResult (..)
  -- Commands (spans two aggregates — both halves of the result must be
  -- persisted together)
  , checkWaitlist
  -- Queries (pure, read-only)
  , matches
  ) where

import Data.List    (sort)
import Data.Maybe   (listToMaybe)
import Data.Text    (Text)
import Data.Time    (NominalDiffTime, UTCTime, addUTCTime)
import Data.UUID    (UUID)

-- ═══════════════════════════════════════════════════════════════════════════
-- ID WRAPPERS
-- Newtypes prevent mixing up identities of different aggregates at compile time.
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorId        = DoctorId        UUID deriving (Show, Eq, Ord)
newtype PatientId       = PatientId       UUID deriving (Show, Eq, Ord)
newtype ServiceId       = ServiceId       UUID deriving (Show, Eq, Ord)
newtype SlotId          = SlotId          UUID deriving (Show, Eq, Ord)
newtype AppointmentId   = AppointmentId   UUID deriving (Show, Eq, Ord)
newtype AppointmentRequestId = AppointmentRequestId UUID deriving (Show, Eq, Ord)

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION
-- The only two appointment lengths the practice currently uses. Not
-- validated as needing more: if a service ever requires a different
-- length, extend this then, with whatever real constraint that case
-- actually needs — not preemptively.
-- ═══════════════════════════════════════════════════════════════════════════

data Duration
  = OneHour
  | HalfAnHour
  deriving (Show, Eq)

durationToNominalDiffTime :: Duration -> NominalDiffTime
durationToNominalDiffTime OneHour    = 3600
durationToNominalDiffTime HalfAnHour = 1800

-- ═══════════════════════════════════════════════════════════════════════════
-- SERVICE
-- A medical service offered by the practice. Defines the canonical duration
-- that is copied (frozen) into each Slot at allocation time.
-- ═══════════════════════════════════════════════════════════════════════════

data Service = Service
  { id       :: ServiceId
  , name     :: Text
  , duration :: Duration
  }
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT
-- Deliberately minimal — both are expected to move to a separate system
-- (staff directory, patient registry) later, with this module referencing
-- them by ID only. Until that exists, a bare name is the only field
-- validated as needed; add more only when a real requirement calls for it.
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
-- APPOINTMENT PRIORITY
-- Flat sum type; Ord gives Emergency < Urgent < Routine by constructor order.
-- Drives both appointment operations (rescheduling eligibility) and
-- waitlist ordering (who receives the next freed slot first).
-- ═══════════════════════════════════════════════════════════════════════════

data AppointmentPriority
  = Emergency
  | Urgent
  | Routine
  deriving (Show, Eq, Ord)

-- ═══════════════════════════════════════════════════════════════════════════
-- DUE AT
-- When a Routine entry's slot is expected to occur. NotBefore and NotAfter
-- are one-sided constraints, not a window with one end at infinity.
--
-- Within is the one case that can be malformed (lo > hi describes an
-- impossible window — no slot start time could ever satisfy it, and the
-- request would silently never match anything, with no error anywhere).
-- The other three constructors have no such invariant, so only Within is
-- excluded from the export list; Anytime/NotBefore/NotAfter stay directly
-- constructible.
-- ═══════════════════════════════════════════════════════════════════════════

data DueAt
  = Anytime
  | NotBefore UTCTime
  | NotAfter  UTCTime
  | Within    UTCTime UTCTime
  deriving (Show, Eq)

mkWithin :: UTCTime -> UTCTime -> Maybe DueAt
mkWithin lo hi
  | lo <= hi  = Just (Within lo hi)
  | otherwise = Nothing

satisfiesDueAt :: UTCTime -> DueAt -> Bool
satisfiesDueAt _ Anytime        = True
satisfiesDueAt t (NotBefore lo) = t >= lo
satisfiesDueAt t (NotAfter  hi) = t <= hi
satisfiesDueAt t (Within lo hi) = t >= lo && t <= hi

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT
-- Lifecycle encoded as separate types, not a status field — each state
-- carries only the payload it needs, and transitions are total functions.
-- There is no EmergencyOnly slot: emergency patients are served via
-- waitlist priority, not reserved capacity (see WAITLIST).
-- ═══════════════════════════════════════════════════════════════════════════

data SlotDetails = SlotDetails
  { id        :: SlotId
  , doctorId  :: DoctorId
  , serviceId :: ServiceId
  , start     :: UTCTime
  , duration  :: Duration   -- frozen from Service at creation time
  }
  deriving (Show, Eq)

-- No fields beyond SlotDetails — there's no decline history to track here.
-- Rejecting a booked appointment is a separate event, on Appointment
-- (closeAppointment/CloseReason), not something this type represents.
newtype PendingSlot = PendingSlot SlotDetails
  deriving (Show, Eq)

newtype AvailableSlot = AvailableSlot SlotDetails
  deriving (Show, Eq)

data BookedSlot = BookedSlot SlotDetails AppointmentId
  deriving (Show, Eq)

data Slot
  = Pending   PendingSlot
  | Available AvailableSlot
  | Booked    BookedSlot
  deriving (Show, Eq)

-- ── Transitions ──────────────────────────────────────────────────────────

-- Appointment cancelled: slot re-enters the matching protocol.
freeSlot :: BookedSlot -> PendingSlot
freeSlot (BookedSlot d _) = PendingSlot d

-- No waitlist match: slot opens for regular booking
releaseSlot :: PendingSlot -> AvailableSlot
releaseSlot (PendingSlot d) = AvailableSlot d

-- ── Helpers ──────────────────────────────────────────────────────────────

slotEnd :: SlotDetails -> UTCTime
slotEnd d = addUTCTime (durationToNominalDiffTime d.duration) d.start

getSlotDetails :: Slot -> SlotDetails
getSlotDetails (Pending   (PendingSlot d))   = d
getSlotDetails (Available (AvailableSlot d)) = d
getSlotDetails (Booked    (BookedSlot d _))  = d

-- BookedSlot is positional with no named fields, so there's no dot-access
-- to its AppointmentId from outside Domain.hs. A pure extraction from an
-- already-valid value — no new fabrication capability, unlike a function
-- that took raw internal state and skipped the sealed constructor's only
-- producer (see Rule 8 in triage-db-codegen).
appointmentId :: BookedSlot -> AppointmentId
appointmentId (BookedSlot _ aid) = aid

-- ═══════════════════════════════════════════════════════════════════════════
-- APPOINTMENT
-- Open | Closed encoded structurally, not as a status field. CloseReason
-- records who initiated the close, for billing and audit.
-- ═══════════════════════════════════════════════════════════════════════════

data AppointmentDetails = AppointmentDetails
  { id        :: AppointmentId
  , patientId :: PatientId
  , slotId    :: SlotId
  , priority  :: AppointmentPriority
  }
  deriving (Show, Eq)

-- ByDoctor/ByPatient, not Doctor/Patient: those names belong to the real
-- entity types (see DOCTOR / PATIENT above) — reusing them here would
-- collide with them.
data AppointmentParty
  = ByDoctor
  | ByPatient
  deriving (Show, Eq)

data CloseReason
  = Completed
  | Cancelled   AppointmentParty
  | Rescheduled AppointmentParty
  | NoShow      AppointmentParty
  deriving (Show, Eq)

newtype OpenAppointment = OpenAppointment AppointmentDetails
  deriving (Show, Eq)

data ClosedAppointment = ClosedAppointment AppointmentDetails CloseReason
  deriving (Show, Eq)

data Appointment
  = Open   OpenAppointment
  | Closed ClosedAppointment
  deriving (Show, Eq)

-- The only place ClosedAppointment's constructor is applied. Mirrors every
-- other transition in this file: the entity being transitioned comes
-- first, the reason/auxiliary data second.
-- OpenAppointment is positional with no named fields, so there's no
-- dot-access to its AppointmentDetails from outside Domain.hs. A pure
-- extraction from an already-valid value — no new fabrication capability,
-- same reasoning as appointmentId.
openAppointmentDetails :: OpenAppointment -> AppointmentDetails
openAppointmentDetails (OpenAppointment d) = d

closeAppointment :: OpenAppointment -> CloseReason -> ClosedAppointment
closeAppointment (OpenAppointment d) = ClosedAppointment d

-- Commits a direct, self-service booking: a patient claims a publicly
-- available slot with no triage step involved — no AppointmentRequest, no
-- classification, just "this open time matches what I want." Priority is
-- always Routine here, not a parameter: claiming Urgent or Emergency
-- requires going through the waitlist's triage (see AppointmentRequest),
-- which this path skips entirely. Letting a caller assert any priority
-- here would let a self-service booking claim urgency with nothing backing
-- the claim. The slot and the appointment transition together, sharing the
-- same AppointmentId — BookedSlot's constructor is applied only here and
-- in assignAppointment (the waitlist-match path below), so a BookedSlot can
-- never exist without a matching Appointment, regardless of which path
-- created it.
bookAppointment :: AvailableSlot -> AppointmentId -> PatientId -> (BookedSlot, Appointment)
bookAppointment (AvailableSlot d) aid pid =
  ( BookedSlot d aid
  , Open (OpenAppointment AppointmentDetails { id = aid, patientId = pid, slotId = d.id, priority = Routine })
  )

-- Commits a waitlist match directly: the matched request's real priority
-- (Emergency/Urgent/Routine, from actual triage) carries through to the
-- Appointment — unlike bookAppointment, which has no triage evidence and
-- must hardcode Routine. The slot and the appointment transition together,
-- sharing the same AppointmentId — BookedSlot's constructor is applied
-- only here and in bookAppointment, so a BookedSlot can never exist
-- without a matching Appointment, regardless of which path created it.
-- Exposed standalone (not only called from checkWaitlist) so a doctor can
-- assign a specific request directly, bypassing bestMatch's priority scan
-- entirely, while still committing through the one safe path.
assignAppointment :: PendingSlot -> AppointmentRequest -> AppointmentId -> (BookedSlot, Appointment)
assignAppointment (PendingSlot d) req aid =
  ( BookedSlot d aid
  , Open (OpenAppointment AppointmentDetails
      { id        = aid
      , patientId = (detailsOf req).patientId
      , slotId    = d.id
      , priority  = priorityOf req
      })
  )

-- ═══════════════════════════════════════════════════════════════════════════
-- WAITLIST
-- Doctor preference and DueAt are exclusive to RoutineRequest: choosing a
-- specific doctor means accepting a longer wait, safe only when there's no
-- urgent time pressure.
-- ═══════════════════════════════════════════════════════════════════════════

data AppointmentRequestDetails = AppointmentRequestDetails
  { id        :: AppointmentRequestId
  , patientId :: PatientId
  , serviceId :: ServiceId
  , createdAt :: UTCTime
  }
  deriving (Show, Eq)

data AppointmentRequest
  = EmergencyRequest AppointmentRequestDetails
  | UrgentRequest    AppointmentRequestDetails
  | RoutineRequest   AppointmentRequestDetails (Maybe DoctorId) DueAt
  deriving (Show, Eq)

-- Reuses AppointmentPriority rather than an arbitrary ranking — this is also
-- exactly the value needed for AppointmentDetails.priority once a match
-- becomes a booked appointment.
priorityOf :: AppointmentRequest -> AppointmentPriority
priorityOf EmergencyRequest{} = Emergency
priorityOf UrgentRequest{}    = Urgent
priorityOf RoutineRequest{}   = Routine

detailsOf :: AppointmentRequest -> AppointmentRequestDetails
detailsOf (EmergencyRequest d)   = d
detailsOf (UrgentRequest    d)   = d
detailsOf (RoutineRequest d _ _) = d

instance Ord AppointmentRequest where
  compare a b = compare (priorityOf a) (priorityOf b)
             <> compare (detailsOf a).createdAt (detailsOf b).createdAt

requestId :: AppointmentRequest -> AppointmentRequestId
requestId e = (detailsOf e).id

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTOCOL
-- When a slot becomes pending, the waitlist is checked: the highest-priority
-- matching request (Emergency → Urgent → Routine, FIFO) is assigned the
-- slot directly — no intermediate offer/accept step. A request either gets
-- booked now or doesn't; there's no "held, awaiting response" state for a
-- slot to sit idle in.
-- ═══════════════════════════════════════════════════════════════════════════

data MatchAppointmentRequestResult
  = NoMatch AvailableSlot          -- no eligible request; slot released to regular booking
  | Matched BookedSlot Appointment -- match committed; both slot and appointment created
  deriving (Show, Eq)

-- The highest-priority request, among those given, that's eligible for this
-- slot — or Nothing if none are. Pure selection only: filter then sort, no
-- transition happens here. Separated from assignAppointment so the priority
-- scan and the act of committing a match can be used independently — e.g. a
-- doctor overriding the scan entirely to assign a slot to a specific
-- patient still goes through assignAppointment, just skipping this function.
bestMatch :: PendingSlot -> [AppointmentRequest] -> Maybe AppointmentRequest
bestMatch ps reqs = listToMaybe $ sort $ filter (matches ps) reqs

checkWaitlist :: PendingSlot -> [AppointmentRequest] -> AppointmentId -> MatchAppointmentRequestResult
checkWaitlist ps reqs aid =
  case bestMatch ps reqs of
    Nothing  -> NoMatch (releaseSlot ps)
    Just req -> let (bs, appt) = assignAppointment ps req aid in Matched bs appt

-- Matches when: the service matches; the doctor preference is satisfied
-- (only RoutineRequest has one); and the slot's start time satisfies its
-- DueAt, if any.
matches :: PendingSlot -> AppointmentRequest -> Bool
matches (PendingSlot d) (EmergencyRequest rd) =
  rd.serviceId == d.serviceId
matches (PendingSlot d) (UrgentRequest rd) =
  rd.serviceId == d.serviceId
matches (PendingSlot d) (RoutineRequest rd mDoc dueAt) =
  rd.serviceId == d.serviceId              &&
  maybe True (== d.doctorId) mDoc          &&
  satisfiesDueAt d.start dueAt
