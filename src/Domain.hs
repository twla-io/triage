{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

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
  , WaitlistEntryId (..)

  -- ── Duration ─────────────────────────────────────────────────────────────
  , Minutes           -- type exported, constructor hidden — use mkMinutes
  , mkMinutes
  , Duration (..)
  , durationToNominalDiffTime

  -- ── Service ──────────────────────────────────────────────────────────────
  , Service (..)

  -- ── AppointmentPriority ──────────────────────────────────────────────────
  , AppointmentPriority (..)
  , DueAt (..)
  -- Queries (pure, read-only)
  , satisfiesDueAt

  -- ── Slot ─────────────────────────────────────────────────────────────────
  , SlotDetails (..)
  , PendingSlot (..)
  , AvailableSlot (..)
  , OfferedSlot (..)
  , BookedSlot (..)
  , Slot (..)
  -- Commands (state transitions)
  , mkPendingSlot
  , freeSlot
  , offerSlot
  , releaseSlot
  , bookSlot
  , declineOffer
  , expireOffer
  -- Queries (pure, read-only)
  , slotEnd
  , getSlotDetails

  -- ── Appointment ──────────────────────────────────────────────────────────
  , AppointmentDetails (..)
  , AppointmentParty (..)
  , CloseReason (..)
  , Appointment (..)

  -- ── Waitlist ─────────────────────────────────────────────────────────────
  , WaitlistEntryStatus (..)
  , WaitlistDetails (..)
  , WaitlistEntry (..)
  -- Commands (state transitions)
  , setSlotOffered
  -- Queries (pure, read-only)
  , sortWaitlist
  , entryId
  , detailsOf
  , priorityOf

  -- ── Protocol ─────────────────────────────────────────────────────────────
  , WaitlistResult (..)
  -- Commands (produces a multi-aggregate result — see GENERATION CONTRACT #5)
  , checkWaitlist
  -- Queries (pure, read-only)
  , matches
  ) where

import Data.Aeson   (FromJSON, ToJSON)
import Data.List    (sort)
import Data.Set     (Set, insert, notMember)
import Data.Text    (Text)
import Data.Time    (NominalDiffTime, UTCTime, addUTCTime)
import Data.UUID    (UUID)
import GHC.Generics (Generic)

-- ═══════════════════════════════════════════════════════════════════════════
-- ID WRAPPERS
-- Newtypes prevent mixing up identities of different aggregates at compile time.
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorId        = DoctorId        UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)
newtype PatientId       = PatientId       UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)
newtype ServiceId       = ServiceId       UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)
newtype SlotId          = SlotId          UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)
newtype AppointmentId   = AppointmentId   UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)
newtype WaitlistEntryId = WaitlistEntryId UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION
-- Constrained type: Custom Minutes enforces valid range at construction.
-- Raw Int or NominalDiffTime would admit -12 or 346 minutes.
-- ═══════════════════════════════════════════════════════════════════════════

newtype Minutes = Minutes Int
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)

mkMinutes :: Int -> Maybe Minutes
mkMinutes n
  | n > 0 && n <= 480 = Just (Minutes n)
  | otherwise         = Nothing

data Duration
  = OneHour
  | HalfAnHour
  | Custom Minutes     -- doctor-specified duration for non-standard slots
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

durationToNominalDiffTime :: Duration -> NominalDiffTime
durationToNominalDiffTime OneHour              = 3600
durationToNominalDiffTime HalfAnHour           = 1800
durationToNominalDiffTime (Custom (Minutes n)) = fromIntegral n * 60

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
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

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
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)

-- ═══════════════════════════════════════════════════════════════════════════
-- DUE AT
--
-- When a Routine entry's slot is expected to occur. Four cases rather than
-- Maybe (UTCTime, UTCTime): NotBefore and NotAfter are each genuinely
-- one-sided constraints, not a window with one end stretched to infinity.
-- A six-month follow-up with no fixed deadline is NotBefore, not a fake
-- window; a "must be seen by Friday" routine check is NotAfter.
-- ═══════════════════════════════════════════════════════════════════════════

data DueAt
  = Anytime
  | NotBefore UTCTime
  | NotAfter  UTCTime
  | Within    UTCTime UTCTime
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

satisfiesDueAt :: UTCTime -> DueAt -> Bool
satisfiesDueAt _ Anytime        = True
satisfiesDueAt t (NotBefore lo) = t >= lo
satisfiesDueAt t (NotAfter  hi) = t <= hi
satisfiesDueAt t (Within lo hi) = t >= lo && t <= hi

-- NormalPriority is gone — Urgent and Routine are now top-level WaitlistEntry
-- constructors (see WAITLIST section below), each carrying exactly what it
-- needs. DueAt lives directly on Routine.

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT
--
-- Lifecycle encoded in separate types — no status field, no guards.
-- Each constructor carries exactly the payload its state requires.
-- Transition functions are total: wrong state = type error, not runtime error.
--
-- Lifecycle: PendingSlot → OfferedSlot | AvailableSlot → BookedSlot
--            BookedSlot  → PendingSlot (on cancellation)
--            OfferedSlot → PendingSlot (on decline)
--
-- No EmergencyOnly variant: emergency patients are served via priority
-- ordering in the waitlist, not by reserving dedicated slots.
-- Reserved emergency slots waste capacity on quiet days; this design does not.
-- ═══════════════════════════════════════════════════════════════════════════

data SlotDetails = SlotDetails
  { id        :: SlotId
  , doctorId  :: DoctorId
  , serviceId :: ServiceId
  , start     :: UTCTime
  , duration  :: Duration   -- frozen from Service at creation time
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- PendingSlot carries the offer-cycle history: which entries have already declined
-- this slot in the current cycle. Belongs here, not on SlotDetails — it is not a
-- fact about the slot, it is state specific to the pending phase.
data PendingSlot = PendingSlot
  { details    :: SlotDetails
  , declinedBy :: Set WaitlistEntryId
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

newtype AvailableSlot = AvailableSlot SlotDetails
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- OfferedSlot IS a PendingSlot with a claim placed on it.
-- Embedding PendingSlot (rather than repeating its fields) makes the relationship
-- explicit and carries declinedBy for free — expireOffer is a pure unwrap.
data OfferedSlot = OfferedSlot
  { slot      :: PendingSlot
  , offeredTo :: WaitlistEntryId
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data BookedSlot = BookedSlot SlotDetails AppointmentId
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data Slot
  = Pending   PendingSlot
  | Offered   OfferedSlot
  | Available AvailableSlot
  | Booked    BookedSlot
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- ── Transitions ──────────────────────────────────────────────────────────

-- New slot: fresh offer cycle, no prior declines
mkPendingSlot :: SlotDetails -> PendingSlot
mkPendingSlot d = PendingSlot { details = d, declinedBy = mempty }

-- Appointment cancelled: new offer cycle begins, decline history discarded
freeSlot :: BookedSlot -> PendingSlot
freeSlot (BookedSlot d _) = PendingSlot { details = d, declinedBy = mempty }

-- Waitlist match found: offer the pending slot as-is (declinedBy carried inside)
offerSlot :: PendingSlot -> WaitlistEntryId -> OfferedSlot
offerSlot ps eid = OfferedSlot { slot = ps, offeredTo = eid }

-- No waitlist match: slot opens for regular booking
releaseSlot :: PendingSlot -> AvailableSlot
releaseSlot ps = AvailableSlot ps.details

-- Regular or priority booking: slot is claimed
bookSlot :: AvailableSlot -> AppointmentId -> BookedSlot
bookSlot (AvailableSlot d) = BookedSlot d

-- Active decline: record the decliner, return to pending for next candidate
declineOffer :: OfferedSlot -> PendingSlot
declineOffer o = o.slot { declinedBy = insert o.offeredTo o.slot.declinedBy }

-- Offer expired: patient didn't respond — eligible again, return pending slot unchanged
expireOffer :: OfferedSlot -> PendingSlot
expireOffer o = o.slot

-- ── Helpers ──────────────────────────────────────────────────────────────

slotEnd :: SlotDetails -> UTCTime
slotEnd d = addUTCTime (durationToNominalDiffTime d.duration) d.start

getSlotDetails :: Slot -> SlotDetails
getSlotDetails (Pending   ps)              = ps.details
getSlotDetails (Offered   os)              = os.slot.details
getSlotDetails (Available (AvailableSlot d)) = d
getSlotDetails (Booked    (BookedSlot d _))  = d

-- ═══════════════════════════════════════════════════════════════════════════
-- APPOINTMENT
--
-- Open | Closed: lifecycle encoded structurally, not as a status field.
-- Operations on Open appointments cannot receive Closed ones — type error.
-- CloseReason carries who initiated the close, enabling billing and audit.
-- Emergency appointments are never rescheduling candidates — enforced
-- by filtering on AppointmentDetails.priority at the application layer.
-- ═══════════════════════════════════════════════════════════════════════════

data AppointmentDetails = AppointmentDetails
  { id        :: AppointmentId
  , patientId :: PatientId
  , slotId    :: SlotId
  , priority  :: AppointmentPriority
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data AppointmentParty
  = Doctor
  | Patient
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data CloseReason
  = Completed
  | Cancelled   AppointmentParty
  | Rescheduled AppointmentParty
  | NoShow      AppointmentParty
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data Appointment
  = Open   AppointmentDetails
  | Closed AppointmentDetails CloseReason
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- ═══════════════════════════════════════════════════════════════════════════
-- WAITLIST
--
-- One flat sum type, three constructors, each carrying exactly what that
-- tier needs — no nested priority type, no separate Emergency/Normal record
-- pair. The structural guarantee survives the flattening:
--
--   EmergencyEntry WaitlistDetails                       — no doctor preference possible
--   UrgentEntry    WaitlistDetails (Maybe DoctorId)       — optional doctor preference
--   RoutineEntry   WaitlistDetails (Maybe DoctorId) DueAt — preference + due date
--
-- EmergencyEntry has no DoctorId parameter at all — not Nothing, structurally
-- absent. It is impossible to construct an emergency entry with a doctor
-- preference.
--
-- Ord instance: EmergencyEntry < UrgentEntry < RoutineEntry, FIFO by createdAt
-- within tier. DueAt never affects ranking — it only affects which slots an
-- entry matches (see `matches`), never who is served first among already-
-- eligible entries.
--
-- WaitlistEntryStatus: bidirectional reference with Slot. When a slot is
-- offered, Slot carries WaitlistEntryId and WaitlistEntry carries SlotId —
-- both updated atomically.
-- ═══════════════════════════════════════════════════════════════════════════

data WaitlistEntryStatus
  = WaitingForSlot
  | SlotOffered SlotId UTCTime   -- which slot, when offered (for expiry tracking)
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data WaitlistDetails = WaitlistDetails
  { id        :: WaitlistEntryId
  , patientId :: PatientId
  , serviceId :: ServiceId
  , status    :: WaitlistEntryStatus
  , createdAt :: UTCTime
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data WaitlistEntry
  = EmergencyEntry WaitlistDetails
  | UrgentEntry    WaitlistDetails (Maybe DoctorId)
  | RoutineEntry   WaitlistDetails (Maybe DoctorId) DueAt
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- priorityOf and detailsOf are projected once and compared together, rather
-- than writing out every pairwise constructor combination by hand. Reusing
-- AppointmentPriority here (instead of an arbitrary Int) means this function
-- does double duty: it's also exactly what's needed to populate
-- AppointmentDetails.priority when a waitlist match becomes a booked
-- appointment — one fact, not two parallel encodings of the same ranking.
priorityOf :: WaitlistEntry -> AppointmentPriority
priorityOf (EmergencyEntry _)   = Emergency
priorityOf (UrgentEntry    _ _) = Urgent
priorityOf (RoutineEntry _ _ _) = Routine

detailsOf :: WaitlistEntry -> WaitlistDetails
detailsOf (EmergencyEntry d)   = d
detailsOf (UrgentEntry    d _) = d
detailsOf (RoutineEntry d _ _) = d

instance Ord WaitlistEntry where
  compare a b = compare (priorityOf a) (priorityOf b)
             <> compare (detailsOf a).createdAt (detailsOf b).createdAt

sortWaitlist :: [WaitlistEntry] -> [WaitlistEntry]
sortWaitlist = sort

entryId :: WaitlistEntry -> WaitlistEntryId
entryId e = (detailsOf e).id

setSlotOffered :: WaitlistEntry -> SlotId -> UTCTime -> WaitlistEntry
setSlotOffered (EmergencyEntry d)        sid t = EmergencyEntry (d { status = SlotOffered sid t })
setSlotOffered (UrgentEntry    d mDoc)   sid t = UrgentEntry    (d { status = SlotOffered sid t }) mDoc
setSlotOffered (RoutineEntry   d mDoc w) sid t = RoutineEntry   (d { status = SlotOffered sid t }) mDoc w

-- isOverdue and escalateToUrgent were removed: they encoded a plausible-
-- sounding rule ("a Routine patient past their DueAt becomes Urgent") that
-- was never actually validated with the doctor. DueAt's eligibility-filtering
-- role (in `matches`) came from a real conversation; the escalation behavior
-- did not. If the doctor confirms this rule is needed, reintroduce it then —
-- cheaper to add later than to carry unvalidated complexity now.

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTOCOL
--
-- checkWaitlist is the core scheduling protocol:
--   When a slot enters PendingOffer state, the waitlist is checked.
--   The highest-priority matching patient (Emergency → Urgent → Routine, FIFO)
--   receives the offer before the slot is released to regular booking.
--
-- This replaces the EmergencyOnly slot reservation mechanism:
--   No capacity is locked away for demand that may not arrive.
--   Emergency patients always get the next available slot via priority.
--   Slot utilisation approaches 100%.
-- ═══════════════════════════════════════════════════════════════════════════

data WaitlistResult
  = NoMatch AvailableSlot               -- no eligible entry; slot released to regular booking
  | Matched OfferedSlot WaitlistEntry   -- offer made; both slot and entry updated
  deriving (Show, Eq)

checkWaitlist :: PendingSlot -> [WaitlistEntry] -> UTCTime -> WaitlistResult
checkWaitlist ps entries now =
  case sortWaitlist (filter (matches ps) entries) of
    []        -> NoMatch (releaseSlot ps)
    (entry:_) -> Matched (offerSlot ps (entryId entry))
                         (setSlotOffered entry ps.details.id now)

-- An entry matches a slot when:
--   1. The entry is still waiting (not already holding another offer)
--   2. The service matches
--   3. The doctor preference is satisfied (EmergencyEntry accepts any doctor)
--   4. The entry has not already declined this slot in the current offer cycle
--   5. The slot's start time satisfies the entry's DueAt constraint, if any
--      (e.g. a routine follow-up booked in June for "no earlier than December")
matches :: PendingSlot -> WaitlistEntry -> Bool
matches ps (EmergencyEntry d) =
  d.status    == WaitingForSlot        &&
  d.serviceId == ps.details.serviceId  &&
  d.id `notMember` ps.declinedBy
matches ps (UrgentEntry d mDoc) =
  d.status    == WaitingForSlot                    &&
  d.serviceId == ps.details.serviceId              &&
  maybe True (== ps.details.doctorId) mDoc         &&
  d.id `notMember` ps.declinedBy
matches ps (RoutineEntry d mDoc dueAt) =
  d.status    == WaitingForSlot                    &&
  d.serviceId == ps.details.serviceId              &&
  maybe True (== ps.details.doctorId) mDoc         &&
  d.id `notMember` ps.declinedBy                   &&
  satisfiesDueAt ps.details.start dueAt
