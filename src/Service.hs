{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- Service layer for the triage domain model. Orchestrates Domain.hs's pure
-- functions with Persistence.hs's fetch/store functions: one function per
-- use case, each taking a ConnectionPool and owning its own unit of work
-- (checked out via withResource, held for the whole operation).
--
-- Naming convention (see triage-service-codegen's verifies-the-precondition
-- rule for the full statement): when a Service.hs wrapper and the
-- Domain.hs verb it calls could plausibly share a name, the test for what
-- to call the wrapper is which one actually verifies the precondition a
-- shared name would be claiming — never "avoid the Haskell namespace
-- collision" on its own, though that collision (Haskell's flat top-level
-- namespace has no OOP-style receiver to disambiguate two same-named
-- functions the way `appointment.reassignSlot(...)` would) is a real,
-- separate reason the wrapper needs *some* different name regardless.
--
-- Checked against both existing wrappers:
--   * reassignSlot / reassignAppointmentSlot: Domain.reassignSlot checks
--     only structural eligibility (matches) against values already in
--     hand — it can't and doesn't verify the appointment is genuinely
--     still Open or the new slot genuinely still available in storage.
--     reassignAppointmentSlot verifies both (fetch-and-check the
--     appointment; affected-rows-check the slot at write time). The name
--     folds in "Appointment" not to dodge the collision but because the
--     wrapper is precise about *what* is being reassigned (the
--     appointment's slot binding, never its identity) — same spirit as the
--     precondition test, applied to precision-of-meaning rather than a
--     literal fetched precondition.
--   * checkWaitlist / matchWaitlistToSlot: Domain.checkWaitlist takes a
--     bare `[TriagedHealthcareRequest]` — it has no way to check, and
--     doesn't check, that the list it's given is actually "the waitlist"
--     (no-delete-on-consumption's derived anti-join). matchWaitlistToSlot
--     is what performs that real fetch (fetchWaitlist) before scanning it,
--     so it's the one entitled to the name "waitlist" in its own name.
-- Neither needed renaming under this test; both already happened to be
-- named correctly. triageHealthcareRequest / triageSubmittedRequest is the
-- clearer worked example, since there "Submitted" is a precondition in the
-- literal sense (a stored state, fetched and checked) rather than a
-- structural-precision distinction.

module Service
  ( -- ── Errors / outcomes ────────────────────────────────────────────────
    ServiceError (..)
  , MatchOutcome (..)
  , ReassignmentOutcome (..)

    -- ── Operations ───────────────────────────────────────────────────────
  , submitHealthcareRequest
  , triageSubmittedRequest
  , matchWaitlistToSlot
  , reassignAppointmentSlot
  , closeAppointment

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
import Data.Text     (Text)
import Data.Time     (UTCTime)
import Data.UUID.V4  (nextRandom)

import Domain
  ( Appointment (..)
  , AppointmentId (..)
  , AvailableSlot (..)
  , CloseReason
  , ClosedAppointment (..)
  , DoctorId (..)
  , DoctorRequirement
  , HealthcareRequest (..)
  , HealthcareRequestDetails (..)
  , HealthcareRequestId (..)
  , HealthcareRequestPriority
  , HealthcareServiceId (..)
  , OpenAppointment
  , PatientId (..)
  , SlotId (..)
  , TriagedHealthcareRequest
  , checkWaitlist
  , reassignSlot
  , triageHealthcareRequest
  )
import Persistence
  ( ClaimOutcome (..)
  , ConnectionPool
  , DecodeError
  , MatchPersistOutcome (..)
  , fetchAppointment
  , fetchHealthcareRequest
  , fetchWaitlist
  , insertSubmittedRequest
  , persistClosedAppointmentIfOpen
  , persistMatchedAppointment
  , persistReassignedAppointment
  , persistTriagedRequest
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
  | RequestNotFound HealthcareRequestId
  | RequestAlreadyTriaged HealthcareRequestId
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

-- Creates a new Submitted request. HealthcareRequestDetails is an open
-- record with no invariant beyond its field types (id-types-plain,
-- minimal-types-minimal-tables) — nothing here can fail beyond an infra
-- error, which nothing else in this module represents either, so this
-- returns a bare IO, no Either. Also the entry point for a doctor
-- scheduling a follow-up: same flow, doctor as both author and triager —
-- see docs/decisions.md's "Doctor-originated requests reuse the existing
-- flow unchanged". That case needs no special handling here; the caller
-- just calls this and then triageSubmittedRequest back-to-back.
submitHealthcareRequest
  :: ConnectionPool
  -> PatientId
  -> Text                -- narrative
  -> DoctorRequirement
  -> UTCTime             -- createdAt
  -> IO HealthcareRequestDetails
submitHealthcareRequest pool patientId narrative doctorRequirement createdAt =
  withResource pool $ \conn -> do
    reqId <- newHealthcareRequestId
    let details = HealthcareRequestDetails { id = reqId, patientId, narrative, doctorRequirement, createdAt }
    insertSubmittedRequest conn details
    pure details

-- Mirrors Domain.triageHealthcareRequest: assigns service/priority to a
-- freshly Submitted request. Named triageSubmittedRequest, not
-- triageRequest or triageHealthcareRequest — per the naming-precondition
-- rule (see this module's header and triage-service-codegen's
-- verifies-the-precondition rule): Domain.triageHealthcareRequest takes a
-- bare HealthcareRequestDetails and has no way to check, and doesn't check,
-- that those details ever existed in a stored Submitted state — it's a
-- pure transformation, agnostic to provenance, correctly named for what it
-- verifies (nothing beyond its own field types). This wrapper, by contrast,
-- is defined entirely by that check: it fetches the stored request,
-- confirms Right (Just (Submitted details)), and rejects
-- RequestAlreadyTriaged otherwise. "Submitted" is load-bearing in this
-- name, not decorative — it names the one thing this function verifies
-- that the Domain function doesn't.
--
-- Guards against being called on a request that's already Triaged —
-- RequestAlreadyTriaged is caller error, not a legitimate outcome, since
-- this function represents first-time triage only. Re-triaging an
-- already-triaged request IS legitimate elsewhere (the
-- re-triage-after-failed-reassignment flow, not yet built), but that flow
-- calls persistTriagedRequest directly on the same HealthcareRequestId as a
-- deliberate in-place overwrite — it doesn't go through this guard, because
-- it isn't a caller of this function; it already knows it's overwriting
-- (it just closed the appointment that owned the old triage). See
-- docs/decisions.md's corrected "No lineage tracking..." entry.
triageSubmittedRequest
  :: ConnectionPool
  -> HealthcareRequestId
  -> HealthcareServiceId
  -> HealthcareRequestPriority
  -> UTCTime             -- triagedAt
  -> IO (Either ServiceError TriagedHealthcareRequest)
triageSubmittedRequest pool requestId healthcareServiceId priority triagedAt = withResource pool $ \conn -> do
  reqResult <- fetchHealthcareRequest conn requestId
  case reqResult of
    Left err                         -> pure (Left (PersistenceDecodeError err))
    Right Nothing                    -> pure (Left (RequestNotFound requestId))
    Right (Just (Triaged _))         -> pure (Left (RequestAlreadyTriaged requestId))
    Right (Just (Submitted details)) -> do
      let triaged = triageHealthcareRequest details healthcareServiceId priority triagedAt
      persistTriagedRequest conn triaged
      pure (Right triaged)

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
--
-- Named reassignAppointmentSlot, not reassignAppointment: only the slot
-- binding changes here, never the appointment's own identity (same
-- AppointmentId, same embedded request) — Domain.reassignSlot is precise
-- about this and the wrapper's name should be too. Also avoids an
-- unqualified-import collision with Domain.reassignSlot itself — see the
-- naming-convention note at the top of this module.
reassignAppointmentSlot
  :: ConnectionPool
  -> AppointmentId
  -> AvailableSlot
  -> IO (Either ServiceError ReassignmentOutcome)
reassignAppointmentSlot pool appointmentId newSlot = withResource pool $ \conn -> do
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

-- Closes an open appointment. No Domain.hs verb to collide with here —
-- ClosedAppointment's constructor is open and there is deliberately no
-- closeAppointment function in Domain.hs (see decisions.md: closing is
-- direct construction), so this name needs no receiver-noun folding the
-- way reassignAppointmentSlot/matchWaitlistToSlot do.
--
-- CloseReason is taken whole from the caller, not decomposed into separate
-- parameters — same convention as AvailableSlot being threaded wholesale
-- into matchWaitlistToSlot/reassignAppointmentSlot rather than picked apart
-- into its own start/duration args. Cancelled's UTCTime is therefore
-- already caller-supplied by construction, consistent with
-- submitHealthcareRequest/triageSubmittedRequest never minting a UTCTime internally.
--
-- Guards AppointmentAlreadyClosed twice, not once: the initial fetch
-- catches the common case (already closed by the time this is called), but
-- between that fetch and the write, a concurrent second close on the same
-- appointment could pass the same check and silently overwrite which
-- reason it closed for — an undetectable data-corruption outcome, not a
-- visible duplicate like the (currently deferred) slot-creation race. So
-- persistClosedAppointmentIfOpen's write is conditioned on state = 'open'
-- and its AlreadyClaimed is reported as the same AppointmentAlreadyClosed,
-- not a new outcome category — the caller doesn't need to distinguish
-- "already closed when I checked" from "closed by someone else a moment
-- later," both mean the same thing to them.
closeAppointment
  :: ConnectionPool
  -> AppointmentId
  -> CloseReason
  -> IO (Either ServiceError ClosedAppointment)
closeAppointment pool appointmentId reason = withResource pool $ \conn -> do
  apptResult <- fetchAppointment conn appointmentId
  case apptResult of
    Left err                     -> pure (Left (PersistenceDecodeError err))
    Right Nothing                -> pure (Left (AppointmentNotFound appointmentId))
    Right (Just (Closed _))      -> pure (Left (AppointmentAlreadyClosed appointmentId))
    Right (Just (Open openAppt)) -> do
      let closed = ClosedAppointment openAppt reason
      claim <- persistClosedAppointmentIfOpen conn closed
      pure $ case claim of
        Claimed        -> Right closed
        AlreadyClaimed -> Left (AppointmentAlreadyClosed appointmentId)

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
