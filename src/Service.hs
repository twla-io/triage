{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- Service layer for the triage domain model. Orchestrates Domain.hs's pure
-- functions with Persistence.hs's fetch/store functions: one function per
-- use case, each taking a ConnectionPool and owning its own unit of work
-- (checked out via withResource, held for the whole operation).

module Service
  ( -- ── Errors / outcomes ────────────────────────────────────────────────
    ServiceError (..)
  , MatchOutcome (..)
  , ReassignmentOutcome (..)

    -- ── Operations ───────────────────────────────────────────────────────
  , matchWaitlistToSlot
  , reassignAppointment

    -- ── ID generation (moved from Persistence.hs — an orchestration
    --    decision, when a new ID is minted, not a fetch or a store) ───────
  , newDoctorId
  , newPatientId
  , newHealthcareServiceId
  , newHealthcareRequestId
  , newSlotId
  , newAppointmentId
  ) where

import Data.Pool     (withResource)
import Data.UUID.V4  (nextRandom)

import Domain
  ( Appointment (..)
  , AppointmentId (..)
  , AvailableSlot (..)
  , DoctorId (..)
  , HealthcareRequestId (..)
  , HealthcareServiceId (..)
  , OpenAppointment
  , PatientId (..)
  , SlotId (..)
  , checkWaitlist
  , reassignSlot
  )
import Persistence
  ( ClaimOutcome (..)
  , ConnectionPool
  , DecodeError
  , MatchPersistOutcome (..)
  , fetchAppointment
  , fetchWaitlist
  , persistMatchedAppointment
  , persistReassignedAppointment
  )

-- ═══════════════════════════════════════════════════════════════════════
-- ERRORS
-- Reserved for cases indicating a bug, misuse, or genuine infrastructure
-- failure — never for a legitimate concurrent outcome (that's
-- MatchOutcome/ReassignmentOutcome below, not ServiceError).
-- ═══════════════════════════════════════════════════════════════════════

data ServiceError
  = PersistenceDecodeError DecodeError
  | AppointmentNotFound AppointmentId
  | AppointmentAlreadyClosed AppointmentId
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- OUTCOMES
-- NoEligibleRequest/Ineligible/SlotAlreadyClaimed/RequestAlreadyClaimed/
-- NewSlotAlreadyClaimed are normal branches of business logic the caller
-- reacts to, each differently — not errors:
--   * NoEligibleRequest: no one on the waitlist fits this slot; the slot
--     stays available, nothing to react to.
--   * SlotAlreadyClaimed: a concurrent operation claimed this exact slot
--     first — try a different slot.
--   * RequestAlreadyClaimed: a concurrent operation already matched this
--     request to a different slot first — drop this request from further
--     consideration, the patient's already scheduled.
--   * Ineligible: the proposed new slot doesn't satisfy the request's own
--     priority/deadline — the not-yet-implemented re-triage flow.
--   * NewSlotAlreadyClaimed: a concurrent operation claimed the proposed new
--     slot first — try a different slot.
-- SlotAlreadyClaimed/NewSlotAlreadyClaimed are translated from
-- Persistence.MatchPersistOutcome/ClaimOutcome; RequestAlreadyClaimed from
-- Persistence.MatchPersistOutcome's RequestAlreadyMatched (guarding
-- appointments.healthcare_request_id's UNIQUE constraint).
--
-- Distinct constructor names throughout, not shared ones — Haskell data
-- constructors share one namespace per module (unlike record fields under
-- DuplicateRecordFields), so the same name can't be reused across sum types
-- in the same module, nor across modules once both are imported unqualified.
-- ═══════════════════════════════════════════════════════════════════════

data MatchOutcome
  = Matched OpenAppointment
  | NoEligibleRequest
  | SlotAlreadyClaimed
  | RequestAlreadyClaimed
  deriving (Show, Eq)

data ReassignmentOutcome
  = Reassigned OpenAppointment
  | Ineligible
  | NewSlotAlreadyClaimed
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- OPERATIONS
-- ═══════════════════════════════════════════════════════════════════════

-- Mirrors Domain.checkWaitlist: a newly available slot scans the waitlist
-- in priority order; the first eligible request is matched and committed.
-- The AppointmentId must be minted before the scan, not after — checkWaitlist
-- takes it as an input baked into every candidate check (via
-- satisfyHealthcareRequest), not something it produces once a match is
-- found. So a no-match scan costs one unused UUID; not worth restructuring
-- Domain.hs to avoid.
matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)
matchWaitlistToSlot pool slot = withResource pool $ \conn -> do
  waitlistResult <- fetchWaitlist conn
  case waitlistResult of
    Left err -> pure (Left (PersistenceDecodeError err))
    Right waitlist -> do
      appointmentId <- newAppointmentId
      case checkWaitlist slot appointmentId waitlist of
        Nothing -> pure (Right NoEligibleRequest)
        Just openAppt -> do
          claim <- persistMatchedAppointment conn slot.id openAppt
          pure . Right $ case claim of
            MatchPersisted        -> Matched openAppt
            SlotAlreadyGone       -> SlotAlreadyClaimed
            RequestAlreadyMatched -> RequestAlreadyClaimed

-- Mirrors Domain.reassignSlot: move an existing open appointment to a
-- different slot, re-checking structural eligibility against it. A closed
-- appointment can't be reassigned — Domain.reassignSlot only accepts an
-- OpenAppointment, so a Closed row found here is the caller's own
-- assumption being wrong, hence ServiceError rather than an outcome.
reassignAppointment
  :: ConnectionPool
  -> AppointmentId
  -> AvailableSlot
  -> IO (Either ServiceError ReassignmentOutcome)
reassignAppointment pool appointmentId newSlot = withResource pool $ \conn -> do
  apptResult <- fetchAppointment conn appointmentId
  case apptResult of
    Left err                   -> pure (Left (PersistenceDecodeError err))
    Right Nothing              -> pure (Left (AppointmentNotFound appointmentId))
    Right (Just (Closed _))    -> pure (Left (AppointmentAlreadyClosed appointmentId))
    Right (Just (Open openAppt)) ->
      case reassignSlot openAppt newSlot of
        Nothing        -> pure (Right Ineligible)
        Just reassigned -> do
          claim <- persistReassignedAppointment conn newSlot.id reassigned
          pure . Right $ case claim of
            Claimed        -> Reassigned reassigned
            AlreadyClaimed -> NewSlotAlreadyClaimed

-- ═══════════════════════════════════════════════════════════════════════
-- ID GENERATION
-- Moved from Persistence.hs on this module's creation, per SKILL.md's own
-- note: minting a new ID is an orchestration decision, not a fetch or a
-- store.
-- ═══════════════════════════════════════════════════════════════════════

newDoctorId :: IO DoctorId
newDoctorId = DoctorId <$> nextRandom

newPatientId :: IO PatientId
newPatientId = PatientId <$> nextRandom

newHealthcareServiceId :: IO HealthcareServiceId
newHealthcareServiceId = HealthcareServiceId <$> nextRandom

newHealthcareRequestId :: IO HealthcareRequestId
newHealthcareRequestId = HealthcareRequestId <$> nextRandom

newSlotId :: IO SlotId
newSlotId = SlotId <$> nextRandom

newAppointmentId :: IO AppointmentId
newAppointmentId = AppointmentId <$> nextRandom
