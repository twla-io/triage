{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
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
  , AppointmentRequestDetails (..)
  , AppointmentRequest (..)
  , AppointmentRequestWithOffer (..)
  , WaitlistRecord (..)
  -- Commands (state transitions)
  , giveOffer
  , backToWaiting
  -- Queries (pure, read-only)
  , requestId
  , detailsOf
  , priorityOf

  -- ── Protocol ─────────────────────────────────────────────────────────────
  , MatchAppointmentRequestResult (..)
  -- Commands (spans two aggregates — both halves of the result must be
  -- persisted together)
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
newtype AppointmentRequestId = AppointmentRequestId UUID deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON)

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
-- When a Routine entry's slot is expected to occur. NotBefore and NotAfter
-- are one-sided constraints, not a window with one end at infinity.
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
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- declinedBy tracks who has already declined this slot in the current
-- offer cycle. Lives here, not on SlotDetails, since it's specific to the
-- pending phase, not a fact true of the slot in every state.
data PendingSlot = PendingSlot
  { details    :: SlotDetails
  , declinedBy :: Set AppointmentRequestId
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

newtype AvailableSlot = AvailableSlot SlotDetails
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- An OfferedSlot IS a PendingSlot with a claim placed on it — embedding
-- carries declinedBy for free, and expireOffer becomes a pure unwrap.
data OfferedSlot = OfferedSlot
  { slot      :: PendingSlot
  , offeredTo :: AppointmentRequestId
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
offerSlot :: PendingSlot -> AppointmentRequestId -> OfferedSlot
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
-- Open | Closed encoded structurally, not as a status field. CloseReason
-- records who initiated the close, for billing and audit.
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
-- Doctor preference and DueAt are exclusive to RoutineRequest: choosing a
-- specific doctor means accepting a longer wait, safe only when there's no
-- urgent time pressure.
--
-- No status field — a bare AppointmentRequest IS waiting. A request with an
-- outstanding offer is an AppointmentRequestWithOffer instead.
-- ═══════════════════════════════════════════════════════════════════════════

data AppointmentRequestDetails = AppointmentRequestDetails
  { id        :: AppointmentRequestId
  , patientId :: PatientId
  , serviceId :: ServiceId
  , createdAt :: UTCTime
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

data AppointmentRequest
  = EmergencyRequest AppointmentRequestDetails
  | UrgentRequest    AppointmentRequestDetails
  | RoutineRequest   AppointmentRequestDetails (Maybe DoctorId) DueAt
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- An AppointmentRequest with an outstanding offer on a specific slot. Embeds
-- the request rather than duplicating its fields, mirroring OfferedSlot/PendingSlot.
data AppointmentRequestWithOffer = AppointmentRequestWithOffer
  { request     :: AppointmentRequest
  , offeredSlot :: SlotId
  , offeredAt   :: UTCTime
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- A request, in whichever state it's currently in. The waitlist is the
-- collection of these — each record is either still waiting, or holds
-- an outstanding offer.
data WaitlistRecord
  = Waiting  AppointmentRequest
  | HasOffer AppointmentRequestWithOffer
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

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

-- Match found: give the request an offer on this slot.
giveOffer :: AppointmentRequest -> SlotId -> UTCTime -> AppointmentRequestWithOffer
giveOffer e sid t = AppointmentRequestWithOffer { request = e, offeredSlot = sid, offeredAt = t }

-- Declined or expired: unwrap back to a waiting request.
backToWaiting :: AppointmentRequestWithOffer -> AppointmentRequest
backToWaiting o = o.request

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTOCOL
-- When a slot becomes pending, the waitlist is checked: the highest-priority
-- matching request (Emergency → Urgent → Routine, FIFO) is offered the slot
-- before it's released to regular booking.
-- ═══════════════════════════════════════════════════════════════════════════

data MatchAppointmentRequestResult
  = NoMatch AvailableSlot                          -- no eligible request; slot released to regular booking
  | Matched OfferedSlot AppointmentRequestWithOffer  -- offer made; both slot and request updated
  deriving (Show, Eq)

checkWaitlist :: PendingSlot -> [AppointmentRequest] -> UTCTime -> MatchAppointmentRequestResult
checkWaitlist ps reqs now =
  case sort (filter (matches ps) reqs) of
    []      -> NoMatch (releaseSlot ps)
    (req:_) -> Matched (offerSlot ps (requestId req))
                       (giveOffer req ps.details.id now)

-- Matches when: the service matches; the doctor preference is satisfied
-- (only RoutineRequest has one); the request hasn't already declined this
-- slot this cycle; and the slot's start time satisfies its DueAt, if any.
-- No "is this waiting" check — the list passed in is, by its type, the
-- waiting list; an offered request is an AppointmentRequestWithOffer, not a candidate here.
matches :: PendingSlot -> AppointmentRequest -> Bool
matches ps (EmergencyRequest d) =
  d.serviceId == ps.details.serviceId  &&
  d.id `notMember` ps.declinedBy
matches ps (UrgentRequest d) =
  d.serviceId == ps.details.serviceId  &&
  d.id `notMember` ps.declinedBy
matches ps (RoutineRequest d mDoc dueAt) =
  d.serviceId == ps.details.serviceId              &&
  maybe True (== ps.details.doctorId) mDoc         &&
  d.id `notMember` ps.declinedBy                   &&
  satisfiesDueAt ps.details.start dueAt