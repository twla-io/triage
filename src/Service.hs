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
-- Checked against the one remaining existing wrapper:
--   * checkWaitlist / matchWaitlistToSlot: Domain.checkWaitlist takes a
--     bare `[TriagedHealthcareRequest]` — it has no way to check, and
--     doesn't check, that the list it's given is actually "the waitlist"
--     (no-delete-on-consumption's derived anti-join). matchWaitlistToSlot
--     is what performs that real fetch (fetchWaitlist) before scanning it,
--     so it's the one entitled to the name "waitlist" in its own name.
-- Needed no renaming under this test; already named correctly.
--
-- A second worked example used to live here — reassignSlot /
-- reassignAppointmentSlot — illustrating a "precision-of-meaning" case:
-- the extra noun ("Appointment") disambiguated *what* was being acted on,
-- not a literal fetched precondition. Both functions are gone — the
-- reassignment mechanism they implemented had a real bug and was replaced
-- entirely by a simpler design; see docs/decisions.md's "Reassignment and
-- displacement both compose from reclaimAppointedIntakeRequest, not a
-- dedicated transition" entry. Deliberately not replaced with a new
-- pairing here: neither matchAcceptedIntakeRequestToSlot nor
-- closeAppointedIntakeRequest makes the same point.
-- matchAcceptedIntakeRequestToSlot's "Accepted" is a literal fetched
-- precondition (the same shape as acceptSubmittedIntakeRequest below, not
-- the precision-of-meaning shape this bullet used to show), and
-- closeAppointedIntakeRequest has no Domain.hs verb to collide with in
-- the first place (same reason reclaimAppointedIntakeRequest doesn't fit
-- this test either — see its own comment). Forcing either into this
-- bullet's old shape would misstate what it actually demonstrates.
--
-- acceptIntakeRequest / acceptSubmittedIntakeRequest is the
-- clearer worked example, since there "Submitted" is a precondition in the
-- literal sense (a stored state, fetched and checked) rather than a
-- structural-precision distinction.

module Service
  ( -- ── Errors / outcomes ────────────────────────────────────────────────
    ServiceError (..)
  , MatchOutcome (..)
  , SlotCreationOutcome (..)

    -- ── Operations ───────────────────────────────────────────────────────
  , createDoctor
  , createPatient
  , createHealthcareService
  , createAvailableSlot
  , submitIntakeRequest
  , acceptSubmittedIntakeRequest
  , rejectSubmittedIntakeRequest
  , matchWaitlistToSlot
  , matchAcceptedIntakeRequestToSlot
  , reclaimAppointedIntakeRequest
  , closeAppointedIntakeRequest

    -- ── Reads (thin pass-throughs — no precondition check, no
    --    ServiceError/outcome translation; see the READS section below for
    --    why these are a different kind of function from Operations) ──────
  , fetchDoctor
  , fetchPatient
  , fetchHealthcareService
  , fetchDoctors
  , fetchPatients
  , fetchHealthcareServices

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
  ( AppointedIntakeRequest (..)
  , AvailableSlot (..)
  , CloseReason
  , Doctor (..)
  , DoctorId (..)
  , DoctorRequirement
  , Duration
  , HealthcareService (..)
  , HealthcareServiceId (..)
  , IntakeRequest (..)
  , IntakeRequestId (..)
  , IntakeRequestPriority
  , Patient (..)
  , PatientId (..)
  , SlotId (..)
  , SubmittedIntakeRequest (..)
  , TriagedIntakeRequest
  , acceptIntakeRequest
  , checkIntakeWaitlist
  , matchIntakeRequestToSlot
  )
-- Qualified alongside the unqualified import below because six of this
-- module's own top-level names (fetchDoctor, fetchPatient,
-- fetchHealthcareService, fetchDoctors, fetchPatients,
-- fetchHealthcareServices — see the READS section) are deliberately
-- identical to their Persistence.hs counterparts; an unqualified import of
-- those six would conflict with this module's own definitions of them.
-- Every other Persistence function keeps the existing unqualified import,
-- since none of the rest collide with a same-named Service.hs function.
import qualified Persistence
import Persistence
  ( ClaimOutcome (..)
  , ConnectionPool
  , DecodeError
  , MatchPersistOutcome (..)
  , fetchIntakeRequest
  , fetchIntakeWaitlist
  , insertAvailableSlot
  , insertDoctor
  , insertHealthcareService
  , insertPatient
  , insertSubmittedIntakeRequest
  , persistClosedIntakeRequestIfAppointed
  , persistMatchedIntakeRequest
  , persistReclaimedIntakeRequest
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
-- NoEligibleRequest/RequestIneligible/SlotAlreadyClaimed/
-- RequestAlreadyClaimed are normal branches of
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
-- SlotAlreadyClaimed is translated from Persistence.MatchPersistOutcome's
-- SlotAlreadyGone; RequestAlreadyClaimed from
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

-- SlotConflict translates Persistence.SlotOverlap — a legitimate
-- concurrent/business outcome (this doctor already has an overlapping
-- commitment for the proposed time), never a caller mistake or infra
-- failure, so per error-vs-outcome-types it belongs here, not folded
-- into ServiceError. Persistence.SlotOverlap itself is not re-exported or
-- pattern-matched by name here (matched via a wildcard below) — same
-- never-leak-a-bare-Persistence-type convention as MatchPersistOutcome/
-- ClaimOutcome elsewhere in this module.
data SlotCreationOutcome
  = SlotCreated AvailableSlot
  | SlotConflict
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- OPERATIONS
-- ═══════════════════════════════════════════════════════════════════════

-- Creates a new AvailableSlot. Nothing in Domain.hs to wrap here —
-- AvailableSlot is an open record with no smart constructor, same as
-- SubmittedIntakeRequest below — so this is a thin pass-through to
-- Persistence.insertAvailableSlot, translating its SlotOverlap result
-- into this module's own SlotCreationOutcome. Named createAvailableSlot,
-- not submitAvailableSlot — "submit" implies something flowing to an
-- authority for acceptance/rejection (correct for SubmittedIntakeRequest,
-- which awaits a triager's judgment); a slot is declared into existence
-- by the authority itself, no acceptance step, so "create" is the
-- accurate verb here.
createAvailableSlot :: ConnectionPool -> AvailableSlot -> IO SlotCreationOutcome
createAvailableSlot pool slot = withResource pool $ \conn -> do
  result <- insertAvailableSlot conn slot
  pure $ case result of
    Right () -> SlotCreated slot
    Left _   -> SlotConflict

-- Creates a new Doctor. Doctor is an open record with no invariant beyond
-- its field types (id-types-plain, minimal-types-minimal-tables) —
-- nothing here can fail beyond an infra error, which nothing else in this
-- module represents either, so this returns a bare IO, no Either. Named
-- createDoctor, not registerDoctor — "register" implies a meaningful
-- enrollment process, but per CLAUDE.md, Doctor is deliberately minimal
-- and expected to move to a separate system later; "create" doesn't
-- overclaim significance for what's just making a row exist, and leaves
-- "register" free for a future, real registration workflow if this type
-- ever grows one.
createDoctor :: ConnectionPool -> Text -> IO Doctor
createDoctor pool name = withResource pool $ \conn -> do
  doctorId <- newDoctorId
  let doctor = Doctor { id = doctorId, name }
  insertDoctor conn doctor
  pure doctor

-- Creates a new Patient. Same reasoning as createDoctor above, applied to
-- Patient — open record, no invariant, bare IO, "create" over "register"
-- for the identical CLAUDE.md reason.
createPatient :: ConnectionPool -> Text -> IO Patient
createPatient pool name = withResource pool $ \conn -> do
  patientId <- newPatientId
  let patient = Patient { id = patientId, name }
  insertPatient conn patient
  pure patient

-- Creates a new HealthcareService. Same reasoning as createDoctor/
-- createPatient above — open record, no invariant beyond field types,
-- bare IO, no Either.
createHealthcareService :: ConnectionPool -> Text -> Duration -> IO HealthcareService
createHealthcareService pool name duration = withResource pool $ \conn -> do
  serviceId <- newHealthcareServiceId
  let service = HealthcareService { id = serviceId, name, duration }
  insertHealthcareService conn service
  pure service

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

-- Reclaims an Appointed request back to Accepted. Mirrors
-- Domain's appointed.triaged field access directly — there is no
-- Domain-level "reclaim" function to wrap, same as
-- rejectSubmittedIntakeRequest/closeAppointedIntakeRequest construct
-- their result directly rather than calling a Domain verb. This
-- wrapper's whole job is the precondition check: fetch by
-- IntakeRequestId, confirm Right (Just (Appointed appointed)), reject
-- otherwise.
--
-- Reassignment and displacement are no longer separate operations —
-- both compose from this plus matchAcceptedIntakeRequestToSlot (see
-- docs/decisions.md). Whether the vacated original time becomes
-- bookable again is the caller's separate, explicit createAvailableSlot
-- call, not automatic here.
--
-- All six IntakeRequest cases handled explicitly, no wildcard, same
-- collapsing as closeAppointedIntakeRequest: Submitted/Rejected/
-- Accepted/Withdrawn all collapse to RequestNotAppointed; Closed gets
-- its own RequestAlreadyClosed.
reclaimAppointedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> IO (Either ServiceError TriagedIntakeRequest)
reclaimAppointedIntakeRequest pool requestId = withResource pool $ \conn -> do
  reqResult <- fetchIntakeRequest conn requestId
  case reqResult of
    Left err                           -> pure (Left (PersistenceDecodeError err))
    Right Nothing                      -> pure (Left (RequestNotFound requestId))
    Right (Just (Submitted _))         -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Rejected {}))         -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Accepted _))          -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Withdrawn _))         -> pure (Left (RequestNotAppointed requestId))
    Right (Just (Closed {}))           -> pure (Left (RequestAlreadyClosed requestId))
    Right (Just (Appointed appointed)) -> do
      claim <- persistReclaimedIntakeRequest conn requestId
      pure $ case claim of
        Claimed        -> Right appointed.triaged
        AlreadyClaimed -> Left (RequestAlreadyClosed requestId)
        -- AlreadyClaimed here means the request left 'appointed' between
        -- this function's own fetch and its write (e.g. concurrently
        -- closed) — same "caller doesn't need to distinguish when"
        -- reasoning as every other double-guarded write in this module.

-- Closes an appointed request. No Domain.hs verb to collide with here —
-- IntakeRequest's Closed constructor is open and there is deliberately no
-- closeIntakeRequest function in Domain.hs (closing is direct
-- construction, per decisions.md), so this name needs no receiver-noun
-- folding the way matchWaitlistToSlot does. Note this used to construct
-- a standalone ClosedAppointment; now it
-- constructs IntakeRequest's own Closed case directly and returns that —
-- ClosedAppointment no longer exists as a type.
--
-- CloseReason is taken whole from the caller, not decomposed into separate
-- parameters — same convention as AvailableSlot being threaded wholesale
-- into matchWaitlistToSlot rather than picked apart into its own
-- start/duration args. Cancelled's UTCTime is
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
-- same double-guard discipline applies to reclaimAppointedIntakeRequest
-- too — persistReclaimedIntakeRequest guards on the identical
-- state = 'appointed' condition.
--
-- All six IntakeRequest cases handled explicitly, no wildcard, same
-- reasoning as reclaimAppointedIntakeRequest above.
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
-- READS
-- Unlike every function in OPERATIONS above, these have no
-- verifies-the-precondition naming question and no ServiceError/outcome
-- translation to do. Operations are all "fetch a row, check something
-- about its state, then write" — the check is what a shared name with a
-- Domain.hs verb would be claiming, and a failed check is what
-- ServiceError/an outcome constructor reports back. A read has neither:
-- there's no Domain.hs verb to collide with (nothing here transforms a
-- domain value), and no fetch-then-act gap for a concurrent write to fall
-- into (guard-every-fetch-then-write-gap doesn't apply — there's no
-- write). The read itself is the entire operation, so each wrapper's only
-- job is pool-in-connection-scoped's Connection checkout; the return type
-- is whatever Persistence.hs's own function already produces, passed
-- through verbatim rather than reinterpreted.
--
-- Same name as their Persistence.hs counterparts on purpose (mirroring
-- insertDoctor/insertPatient/insertHealthcareService's own naming, which
-- face no such collision only because Service.hs doesn't also define its
-- own insertDoctor) — see the qualified `Persistence` import above for
-- why that's possible without a clash.
-- ═══════════════════════════════════════════════════════════════════════

fetchDoctor :: ConnectionPool -> DoctorId -> IO (Maybe Doctor)
fetchDoctor pool doctorId = withResource pool $ \conn -> Persistence.fetchDoctor conn doctorId

fetchPatient :: ConnectionPool -> PatientId -> IO (Maybe Patient)
fetchPatient pool patientId = withResource pool $ \conn -> Persistence.fetchPatient conn patientId

fetchHealthcareService :: ConnectionPool -> HealthcareServiceId -> IO (Either DecodeError (Maybe HealthcareService))
fetchHealthcareService pool serviceId = withResource pool $ \conn -> Persistence.fetchHealthcareService conn serviceId

fetchDoctors :: ConnectionPool -> IO [Doctor]
fetchDoctors pool = withResource pool $ \conn -> Persistence.fetchDoctors conn

fetchPatients :: ConnectionPool -> IO [Patient]
fetchPatients pool = withResource pool $ \conn -> Persistence.fetchPatients conn

fetchHealthcareServices :: ConnectionPool -> IO (Either DecodeError [HealthcareService])
fetchHealthcareServices pool = withResource pool $ \conn -> Persistence.fetchHealthcareServices conn

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
