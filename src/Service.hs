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
  , submitIntakeRequest
  , acceptSubmittedIntakeRequest
  , rejectSubmittedIntakeRequest
  , matchWaitlistToSlot
  , matchAcceptedIntakeRequestToSlot
  , reassignAppointedIntakeRequestSlot
  , closeAppointedIntakeRequest

    -- ── ID generation (moved from Persistence.hs — an orchestration
    --    decision, when a new ID is minted, not a fetch or a store) ───────
  , newDoctorId
  , newPatientId
  , newHealthcareServiceId
  , newIntakeRequestId
  , newSlotId
  ) where

import Data.Pool                  (withResource)
import Data.Text                  (Text)
import Data.Time                  (UTCTime)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection)

import Domain
  ( AppointedIntakeRequest
  , AvailableSlot (..)
  , CloseReason
  , DoctorId (..)
  , DoctorRequirement
  , HealthcareServiceId (..)
  , IntakeRequest (..)
  , IntakeRequestId (..)
  , IntakeRequestPriority
  , PatientId (..)
  , SlotId (..)
  , SubmittedIntakeRequest (..)
  , TriagedIntakeRequest
  , acceptIntakeRequest
  , checkIntakeWaitlist
  , matchIntakeRequestToSlot
  , reassignIntakeRequestSlot
  )
import Persistence
  ( ClaimOutcome (..)
  , ConnectionPool
  , DecodeError
  , MatchPersistOutcome (..)
  , fetchIntakeRequest
  , fetchIntakeWaitlist
  , insertSubmittedIntakeRequest
  , persistClosedIntakeRequestIfAppointed
  , persistMatchedIntakeRequest
  , persistReassignedIntakeRequest
  , persistRejectedIntakeRequest
  , persistTriagedIntakeRequest
  )

-- ═══════════════════════════════════════════════════════════════════════
-- ERRORS
-- Reserved for cases indicating a bug, misuse, or genuine infrastructure
-- failure — never for a legitimate concurrent outcome (that's
-- MatchOutcome/ReassignmentOutcome below, not ServiceError).
-- ═══════════════════════════════════════════════════════════════════════

data ServiceError
  = PersistenceDecodeError DecodeError
  | RequestNotFound IntakeRequestId
  | RequestNotSubmittedAnymore IntakeRequestId
  | RequestNotAccepted IntakeRequestId
  | RequestNotYetTriaged IntakeRequestId
  | RequestNotAppointed IntakeRequestId
  | RequestAlreadyClosed IntakeRequestId
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- OUTCOMES
-- NoEligibleRequest/RequestIneligible/Ineligible/SlotAlreadyClaimed/
-- RequestAlreadyClaimed/NewSlotAlreadyClaimed are normal branches of
-- business logic the caller reacts to, each differently — not errors:
--   * NoEligibleRequest: no one on the waitlist fits this slot (automatic
--     scan, matchWaitlistToSlot); the slot stays available, nothing to
--     react to.
--   * RequestIneligible: the caller-chosen request doesn't structurally fit
--     the caller-chosen slot (manual, one specific pair,
--     matchAcceptedIntakeRequestToSlot) — a distinct constructor from
--     NoEligibleRequest because there was no scan here to come up empty;
--     the caller picked wrong, try a different slot or request.
--   * SlotAlreadyClaimed: a concurrent operation claimed this exact slot
--     first — try a different slot.
--   * RequestAlreadyClaimed: the request is no longer available to match,
--     via either of two paths that deliberately collapse to this one
--     constructor. Path one: matchAcceptedIntakeRequestToSlot's own fetch
--     already finds it Appointed (its Right (Just (Appointed _)) case).
--     Path two: the fetch found it Accepted, but a concurrent match won
--     the race and moved it from 'accepted' to 'appointed' before this
--     call's own write landed, caught by claimAcceptedIntakeRequest's
--     affected-rows check and surfaced here as
--     Persistence.MatchPersistOutcome's RequestAlreadyMatched. Unlike the
--     old two-table design, these two paths ARE now distinguishable at
--     the type level — state = 'appointed' is a directly stored,
--     observable fact on intake_requests, not a derived anti-join — so
--     collapsing them is a deliberate choice, not a limitation: the
--     caller doesn't need to know whether the request was already
--     appointed when it looked vs. a moment later, only that it's
--     already scheduled and should be dropped from further consideration.
--   * Ineligible: the proposed new slot doesn't satisfy the request's own
--     priority/deadline — the not-yet-implemented re-triage flow.
--   * NewSlotAlreadyClaimed: a concurrent operation claimed the proposed new
--     slot first — try a different slot.
-- SlotAlreadyClaimed/NewSlotAlreadyClaimed are translated from
-- Persistence.MatchPersistOutcome/ClaimOutcome; RequestAlreadyClaimed from
-- Persistence.MatchPersistOutcome's RequestAlreadyMatched, which now
-- guards claimAcceptedIntakeRequest's UPDATE ... WHERE state = 'accepted'
-- (two concurrent matches both trying to move the same intake_requests
-- row from 'accepted' to 'appointed') — via the shared persistMatch
-- helper below, used identically by both matchWaitlistToSlot and
-- matchAcceptedIntakeRequestToSlot.
--
-- Distinct constructor names throughout, not shared ones — Haskell data
-- constructors share one namespace per module (unlike record fields under
-- DuplicateRecordFields), so the same name can't be reused across sum types
-- in the same module, nor across modules once both are imported unqualified.
-- ═══════════════════════════════════════════════════════════════════════

data MatchOutcome
  = Matched AppointedIntakeRequest
  | NoEligibleRequest
  | RequestIneligible
  | SlotAlreadyClaimed
  | RequestAlreadyClaimed
  deriving (Show, Eq)

data ReassignmentOutcome
  = Reassigned AppointedIntakeRequest
  | Ineligible
  | NewSlotAlreadyClaimed
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- OPERATIONS
-- ═══════════════════════════════════════════════════════════════════════

-- Creates a new Submitted request. SubmittedIntakeRequest is an open
-- record with no invariant beyond its field types (id-types-plain,
-- minimal-types-minimal-tables) — nothing here can fail beyond an infra
-- error, which nothing else in this module represents either, so this
-- returns a bare IO, no Either. Also the entry point for a doctor
-- scheduling a follow-up: same flow, doctor as both author and triager —
-- see docs/decisions.md's "Doctor-originated requests reuse the existing
-- flow unchanged". That case needs no special handling here; the caller
-- just calls this and then triageSubmittedRequest back-to-back.
submitIntakeRequest
  :: ConnectionPool
  -> PatientId
  -> Text                -- narrative
  -> DoctorRequirement
  -> UTCTime             -- createdAt
  -> IO SubmittedIntakeRequest
submitIntakeRequest pool patientId narrative doctorRequirement createdAt =
  withResource pool $ \conn -> do
    reqId <- newIntakeRequestId
    let submitted = SubmittedIntakeRequest { id = reqId, patientId, narrative, doctorRequirement, createdAt }
    insertSubmittedIntakeRequest conn submitted
    pure submitted

-- Mirrors Domain.acceptIntakeRequest. Named acceptSubmittedIntakeRequest,
-- not acceptIntakeRequest or acceptRequest — per this module's
-- verifies-the-precondition convention: Domain.acceptIntakeRequest takes
-- a bare SubmittedIntakeRequest and has no way to check it actually came
-- from a real, currently Submitted stored request. This wrapper is
-- defined by that check: fetches by IntakeRequestId, confirms
-- Right (Just (Submitted submitted)), rejects RequestNotSubmittedAnymore
-- otherwise.
acceptSubmittedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> HealthcareServiceId
  -> IntakeRequestPriority
  -> UTCTime             -- triagedAt
  -> IO (Either ServiceError TriagedIntakeRequest)
acceptSubmittedIntakeRequest pool requestId healthcareServiceId priority triagedAt =
  withResource pool $ \conn -> do
    reqResult <- fetchIntakeRequest conn requestId
    case reqResult of
      Left err                           -> pure (Left (PersistenceDecodeError err))
      Right Nothing                      -> pure (Left (RequestNotFound requestId))
      Right (Just (Submitted submitted)) -> do
        let triaged = acceptIntakeRequest submitted healthcareServiceId priority triagedAt
        persistTriagedIntakeRequest conn triaged
        pure (Right triaged)
      Right (Just _)                     -> pure (Left (RequestNotSubmittedAnymore requestId))

-- No Domain.hs verb to wrap — rejection is direct construction
-- (Rejected submitted rejectedAt reason), per the settled design: there
-- is deliberately no rejectIntakeRequest function in Domain.hs. This
-- wrapper's whole job is the same precondition check as
-- acceptSubmittedIntakeRequest's, applied to the reject path instead.
rejectSubmittedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> UTCTime             -- rejectedAt
  -> Text                -- reason
  -> IO (Either ServiceError IntakeRequest)
rejectSubmittedIntakeRequest pool requestId rejectedAt reason =
  withResource pool $ \conn -> do
    reqResult <- fetchIntakeRequest conn requestId
    case reqResult of
      Left err                           -> pure (Left (PersistenceDecodeError err))
      Right Nothing                      -> pure (Left (RequestNotFound requestId))
      Right (Just (Submitted submitted)) -> do
        let rejected = Rejected submitted rejectedAt reason
        persistRejectedIntakeRequest conn submitted rejectedAt reason
        pure (Right rejected)
      Right (Just _)                     -> pure (Left (RequestNotSubmittedAnymore requestId))

-- Mirrors Domain.checkIntakeWaitlist: a newly available slot scans the
-- waitlist in priority order; the first eligible request is matched and
-- committed. Unlike the old checkWaitlist, no AppointmentId needs minting
-- before the scan — IntakeRequestId already exists on the request itself
-- (carried through since submitIntakeRequest), so there's no separate
-- identity to produce.
matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)
matchWaitlistToSlot pool slot = withResource pool $ \conn -> do
  waitlistResult <- fetchIntakeWaitlist conn
  case waitlistResult of
    Left err -> pure (Left (PersistenceDecodeError err))
    Right waitlist ->
      case checkIntakeWaitlist slot waitlist of
        Nothing        -> pure (Right NoEligibleRequest)
        Just appointed -> Right <$> persistMatch conn slot appointed

-- Mirrors Domain.matchIntakeRequestToSlot called directly, bypassing
-- checkIntakeWaitlist's scan — Domain.hs's own comment calls this out as a
-- valid, separate entry point for a manager to force-match one specific
-- request to one specific slot, still subject to the same structural
-- eligibility (matches) as the automatic scan, never overridable.
--
-- Named matchAcceptedIntakeRequestToSlot, not matchIntakeRequestToSlot or
-- matchRequestToSlot — per verifies-the-precondition:
-- Domain.matchIntakeRequestToSlot takes a bare TriagedIntakeRequest and has
-- no way to check, and doesn't check, that it actually came from a real,
-- currently Accepted stored request. This wrapper is defined by that check,
-- mirroring matchWaitlistToSlot's own claim on "waitlist": it fetches by
-- IntakeRequestId, confirms Right (Just (Accepted triaged)), and rejects
-- otherwise. Deliberately not "force"/"override" in the name — matches is
-- never overridable, even by a manager, so a name suggesting force would
-- overclaim what this bypasses (the scan, not the rules).
--
-- All six IntakeRequest cases handled explicitly, no wildcard — so GHC's
-- exhaustiveness check keeps this honest if a future case is ever added.
-- Appointed collapses to RequestAlreadyClaimed (already matched, whether
-- before this call or a moment after its own fetch — see the OUTCOMES
-- comment above); Rejected/Withdrawn/Closed all collapse to the single
-- RequestNotAccepted ServiceError, a deliberate simplification (the caller
-- can re-fetch if it needs to know which).
--
-- RequestIneligible (matchIntakeRequestToSlot returns Nothing) is a
-- distinct MatchOutcome constructor from NoEligibleRequest: there was no
-- scan here to come up empty, the caller picked one specific pair and it
-- doesn't structurally fit — same category as reassignAppointmentSlot's
-- Ineligible, just named differently since Ineligible is already a
-- ReassignmentOutcome constructor in this module.
--
-- The write path — persistMatch — is shared verbatim with
-- matchWaitlistToSlot, not rebuilt: both entry points write through the
-- identical intake_requests/slots tables and need the identical dual-race
-- guard (persistMatchedIntakeRequest's slot-side and request-side checks).
-- They differ only in how the TriagedIntakeRequest is obtained (scan vs.
-- fetched-and-validated by ID); everything downstream of that is one
-- function. This is also why "already matched" is RequestAlreadyClaimed
-- here, not a new ServiceError: the shared write path can't tell "already
-- matched before this call" from "matched a moment after this call's own
-- fetch" — see the OUTCOMES comment above.
matchAcceptedIntakeRequestToSlot
  :: ConnectionPool
  -> IntakeRequestId
  -> AvailableSlot
  -> IO (Either ServiceError MatchOutcome)
matchAcceptedIntakeRequestToSlot pool requestId slot = withResource pool $ \conn -> do
  reqResult <- fetchIntakeRequest conn requestId
  case reqResult of
    Left err                        -> pure (Left (PersistenceDecodeError err))
    Right Nothing                   -> pure (Left (RequestNotFound requestId))
    Right (Just (Submitted _))      -> pure (Left (RequestNotYetTriaged requestId))
    Right (Just (Accepted triaged)) ->
      case matchIntakeRequestToSlot slot triaged of
        Nothing        -> pure (Right RequestIneligible)
        Just appointed -> Right <$> persistMatch conn slot appointed
    Right (Just (Appointed _))      -> pure (Right RequestAlreadyClaimed)
    Right (Just (Rejected {}))      -> pure (Left (RequestNotAccepted requestId))
    Right (Just (Withdrawn _))      -> pure (Left (RequestNotAccepted requestId))
    Right (Just (Closed {}))        -> pure (Left (RequestNotAccepted requestId))

-- Shared tail of matchWaitlistToSlot/matchAcceptedIntakeRequestToSlot:
-- persists an already-produced AppointedIntakeRequest and translates
-- Persistence's MatchPersistOutcome into this module's MatchOutcome. Not
-- exported — an internal helper, not its own use case (function-per-use-case
-- is about public operations, not every internal step).
persistMatch :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO MatchOutcome
persistMatch conn slot appointed = do
  claim <- persistMatchedIntakeRequest conn slot.id appointed
  pure $ case claim of
    MatchPersisted        -> Matched appointed
    SlotAlreadyGone       -> SlotAlreadyClaimed
    RequestAlreadyMatched -> RequestAlreadyClaimed

-- Mirrors Domain.reassignIntakeRequestSlot: move an already-appointed
-- request to a different slot, re-checking structural eligibility against
-- it. A request not currently Appointed can't be reassigned —
-- Domain.reassignIntakeRequestSlot only accepts an AppointedIntakeRequest,
-- so any other fetched state is the caller's own assumption being wrong,
-- hence ServiceError rather than an outcome.
--
-- Named reassignAppointedIntakeRequestSlot, not reassignIntakeRequestSlot
-- or reassignRequestSlot — per verifies-the-precondition, same reasoning
-- as matchAcceptedIntakeRequestToSlot's rename: Domain's function is now
-- one word away from this wrapper's old name, and this wrapper is defined
-- by the check Domain.reassignIntakeRequestSlot doesn't and can't perform
-- — fetches by IntakeRequestId, confirms
-- Right (Just (Appointed appointed)), rejects otherwise. Only the slot
-- binding changes here, never the request's own identity (same
-- IntakeRequestId, same embedded triaged request).
--
-- All six IntakeRequest cases handled explicitly, no wildcard — so GHC's
-- exhaustiveness check keeps this honest if a future case is ever added.
-- Submitted/Rejected/Accepted/Withdrawn all collapse to the single
-- RequestNotAppointed ServiceError; Closed gets its own
-- RequestAlreadyClosed, same distinct-signal reasoning as
-- closeAppointedIntakeRequest below.
reassignAppointedIntakeRequestSlot
  :: ConnectionPool
  -> IntakeRequestId
  -> AvailableSlot
  -> IO (Either ServiceError ReassignmentOutcome)
reassignAppointedIntakeRequestSlot pool requestId newSlot = withResource pool $ \conn -> do
  reqResult <- fetchIntakeRequest conn requestId
  case reqResult of
    Left err                          -> pure (Left (PersistenceDecodeError err))
    Right Nothing                     -> pure (Left (RequestNotFound requestId))
    Right (Just (Submitted _))        -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Rejected {}))        -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Accepted _))         -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Withdrawn _))        -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Closed {}))          -> pure (Left (RequestAlreadyClosed requestId))
    Right (Just (Appointed appointed)) ->
      case reassignIntakeRequestSlot appointed newSlot of
        Nothing         -> pure (Right Ineligible)
        Just reassigned -> do
          claim <- persistReassignedIntakeRequest conn reassigned
          pure . Right $ case claim of
            Claimed        -> Reassigned reassigned
            AlreadyClaimed -> NewSlotAlreadyClaimed

-- Closes an appointed request. No Domain.hs verb to collide with here —
-- IntakeRequest's Closed constructor is open and there is deliberately no
-- closeIntakeRequest function in Domain.hs (closing is direct
-- construction, per decisions.md), so this name needs no receiver-noun
-- folding the way reassignAppointedIntakeRequestSlot/matchWaitlistToSlot
-- do. Note this used to construct a standalone ClosedAppointment; now it
-- constructs IntakeRequest's own Closed case directly and returns that —
-- ClosedAppointment no longer exists as a type.
--
-- CloseReason is taken whole from the caller, not decomposed into separate
-- parameters — same convention as AvailableSlot being threaded wholesale
-- into matchWaitlistToSlot/reassignAppointedIntakeRequestSlot rather than
-- picked apart into its own start/duration args. Cancelled's UTCTime is
-- therefore already caller-supplied by construction, consistent with
-- submitIntakeRequest/acceptSubmittedIntakeRequest never minting a UTCTime
-- internally.
--
-- Guards RequestAlreadyClosed twice, not once: the initial fetch catches
-- the common case (already closed by the time this is called), but
-- between that fetch and the write, a concurrent second close on the same
-- request could pass the same check and silently overwrite which reason
-- it closed for — an undetectable data-corruption outcome, not a visible
-- duplicate like the slot-creation race. So
-- persistClosedIntakeRequestIfAppointed's write is conditioned on
-- state = 'appointed' and its AlreadyClaimed is reported as the same
-- RequestAlreadyClosed, not a new outcome category — the caller doesn't
-- need to distinguish "already closed when I checked" from "closed by
-- someone else a moment later," both mean the same thing to them. The
-- same double-guard discipline now applies consistently to reassignment
-- too, per persistReassignedIntakeRequest's fix.
--
-- All six IntakeRequest cases handled explicitly, no wildcard, same
-- reasoning as reassignAppointedIntakeRequestSlot above.
closeAppointedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> CloseReason
  -> IO (Either ServiceError IntakeRequest)
closeAppointedIntakeRequest pool requestId reason = withResource pool $ \conn -> do
  reqResult <- fetchIntakeRequest conn requestId
  case reqResult of
    Left err                          -> pure (Left (PersistenceDecodeError err))
    Right Nothing                     -> pure (Left (RequestNotFound requestId))
    Right (Just (Submitted _))        -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Rejected {}))        -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Accepted _))         -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Withdrawn _))        -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Closed {}))          -> pure (Left (RequestAlreadyClosed requestId))
    Right (Just (Appointed appointed)) -> do
      let closed = Closed appointed reason
      claim <- persistClosedIntakeRequestIfAppointed conn appointed reason
      pure $ case claim of
        Claimed        -> Right closed
        AlreadyClaimed -> Left (RequestAlreadyClosed requestId)

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

newIntakeRequestId :: IO IntakeRequestId
newIntakeRequestId = IntakeRequestId <$> nextRandom

newSlotId :: IO SlotId
newSlotId = SlotId <$> nextRandom
