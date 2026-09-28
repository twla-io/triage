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
--   * checkIntakeWaitlist / matchWaitlistToSlot: Domain.checkIntakeWaitlist
--     takes a bare `[TriagedIntakeRequest]` — it has no way to check, and
--     doesn't check, that the list it's given is actually "the waitlist"
--     (state = 'accepted'). matchWaitlistToSlot is what performs that real
--     fetch (Persistence.fetchIntakeWaitlist) before scanning it, so it's
--     the one entitled to the name "waitlist" in its own name.
-- Needed no renaming under this test; already named correctly.
--
-- A second worked example used to live here — reassignSlot /
-- reassignAppointmentSlot — illustrating a "precision-of-meaning" case:
-- the extra noun ("Appointment") disambiguated *what* was being acted on,
-- not a literal fetched precondition. Both functions are gone; rescheduling
-- is now a close followed by a new request (see docs/decisions.md's
-- "Reclaim removed; displacing a patient is Closed + a new IntakeRequest"
-- entry). Deliberately not replaced with a new pairing here: neither matchAcceptedIntakeRequestToSlot nor
-- closeAppointedIntakeRequest makes the same point.
-- matchAcceptedIntakeRequestToSlot's "Accepted" is a literal fetched
-- precondition (the same shape as acceptSubmittedIntakeRequest below, not
-- the precision-of-meaning shape this bullet used to show), and
-- closeAppointedIntakeRequest has no Domain.hs verb to collide with in
-- the first place. Forcing either into this bullet's old shape would
-- misstate what it actually demonstrates.
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
  , TransitionOutcome (..)

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
  , markIntakeRequestStale
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
  , fetchAvailableSlots
  , fetchAppointedIntakeRequests
  , fetchClosedIntakeRequests
  , fetchIntakeRequest
  , fetchIntakeWaitlist
  , fetchSubmittedIntakeRequests

    -- ── Calendar (composes the two reads above into one time-ordered
    --    view — see the CALENDAR section below) ─────────────────────────
  , fetchCalendarView

    -- ── ID generation (moved from Persistence.hs — an orchestration
    --    decision, when a new ID is minted, not a fetch or a store) ───────
  , newDoctorId
  , newPatientId
  , newHealthcareServiceId
  , newIntakeRequestId
  , newSlotId
  ) where

import Data.List                  (sortOn)
import Data.Pool                  (withResource)
import Data.Text                  (Text)
import Data.Time                  (UTCTime, addUTCTime)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection)

import Domain
  ( AppointedIntakeRequest (..)
  , AvailableSlot (..)
  , CalendarEntry (..)
  , CloseReason
  , Doctor (..)
  , DoctorId (..)
  , DoctorRequirement (..)
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
  , TriagedIntakeRequest (..)
  , WithdrawnIntakeRequest (..)
  , acceptIntakeRequest
  , addAvailableSlot
  , calendarEntryStart
  , checkIntakeWaitlist
  , durationToNominalDiffTime
  , matchIntakeRequestToSlot
  )
-- Qualified alongside the unqualified import below because thirteen of
-- this module's own top-level names (fetchDoctor, fetchPatient,
-- fetchHealthcareService, fetchDoctors, fetchPatients,
-- fetchHealthcareServices, fetchAvailableSlots,
-- fetchAppointedIntakeRequests, fetchClosedIntakeRequests,
-- fetchIntakeRequest, fetchIntakeWaitlist, fetchSubmittedIntakeRequests —
-- see the READS section — plus fetchCalendarView's internal calls to the
-- first two of those) are
-- deliberately identical to their Persistence.hs counterparts; an
-- unqualified import of those names would conflict with this module's own
-- definitions of them. fetchIntakeRequest/fetchIntakeWaitlist moved out of
-- the unqualified list below when their own Service.hs wrappers were
-- added — every internal call site that used to reach them unqualified
-- now goes through Persistence.fetchIntakeRequest/
-- Persistence.fetchIntakeWaitlist instead (see acceptSubmittedIntakeRequest,
-- rejectSubmittedIntakeRequest, matchWaitlistToSlot,
-- matchAcceptedIntakeRequestToSlot, markIntakeRequestStale,
-- closeAppointedIntakeRequest below). fetchSubmittedIntakeRequests/
-- fetchClosedIntakeRequests were never in the unqualified list to begin
-- with — each one's own Service.hs wrapper was added at the same time as
-- its Persistence.hs function itself, so there was no prior unqualified
-- call site to migrate off of. Every other Persistence function keeps
-- the existing unqualified import, since none of the rest collide with
-- a same-named Service.hs function.
import qualified Persistence
import Persistence
  ( ClaimOutcome (..)
  , ConnectionPool
  , DecodeError
  , MatchPersistOutcome (..)
  , fetchDoctorCalendar
  , fetchSlot
  , insertAvailableSlot
  , insertDoctor
  , insertHealthcareService
  , insertPatient
  , insertSubmittedIntakeRequest
  , persistClosedIntakeRequestIfAppointed
  , persistMatchedIntakeRequest
  , persistRejectedIntakeRequest
  , persistStaleIntakeRequest
  , persistTriagedIntakeRequest
  )

-- ═══════════════════════════════════════════════════════════════════════
-- ERRORS
-- Reserved for cases indicating a bug, misuse, or genuine infrastructure
-- failure — never for a legitimate concurrent outcome (that's
-- MatchOutcome/SlotCreationOutcome/TransitionOutcome below, not ServiceError).
--
-- RequestInWrongState: the request is in a state that can't come after
-- the one the operation expects (e.g. closing a request that is still
-- Accepted), so the caller could never have seen the state it acted on —
-- a caller mistake. Carries the request as it is, for diagnosis. A state
-- that *does* come after the expected one is not an error: see MovedOn /
-- RequestMovedOn below.
-- ═══════════════════════════════════════════════════════════════════════

data ServiceError
  = PersistenceDecodeError DecodeError
  | RequestNotFound IntakeRequestId
  | RequestInWrongState IntakeRequest
  | HealthcareServiceNotFound HealthcareServiceId
  | DoctorNotFound DoctorId
  | PatientNotFound PatientId
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- OUTCOMES
-- Normal branches of business logic the caller reacts to, each
-- differently — not errors:
--   * NoEligibleRequest: no one on the waitlist fits this slot (automatic
--     scan, matchWaitlistToSlot); the slot stays available, nothing to
--     react to.
--   * RequestIneligible: the caller-chosen request doesn't structurally fit
--     the caller-chosen slot (manual, one specific pair,
--     matchAcceptedIntakeRequestToSlot) — a distinct constructor from
--     NoEligibleRequest because there was no scan here to come up empty;
--     the caller picked wrong, try a different slot or request.
--   * SlotAlreadyClaimed: a concurrent operation claimed this exact slot
--     first — try a different slot. Also what
--     matchAcceptedIntakeRequestToSlot reports when its slot fetch finds no
--     row: under deleted-on-match, "claimed a moment ago" and "never
--     existed" look identical.
--   * RequestMovedOn / MovedOn (TransitionOutcome, below): the request is in a
--     state that comes after the one the operation expects — someone else
--     acted first. Carries the request as it is now. The same answer
--     whether the fetch noticed or the write did (its state guard matched
--     no row, state-guard-is-freshness); after a lost write the request is
--     read once more, which always finds a later state, since states only
--     move forward. Nothing retries: the caller looks at what it is now.
-- SlotAlreadyClaimed is translated from Persistence.MatchPersistOutcome's
-- SlotAlreadyGone, or produced directly by matchAcceptedIntakeRequestToSlot
-- when fetchSlot returns Nothing; a lost request claim
-- (RequestAlreadyMatched) becomes RequestMovedOn — via the shared
-- persistMatch helper below, used identically by both matchWaitlistToSlot
-- and matchAcceptedIntakeRequestToSlot. claimAcceptedIntakeRequest also
-- folds a doctor_calendar overlap (23P01) into that result; since matching
-- copies the stored slot's own interval, freed in the same transaction,
-- that case should be unreachable.
--
-- Which states come after which is read off Domain.hs's transitions:
-- every state comes after Submitted; Appointed, Stale,
-- WithdrawnFromAccepted and Closed come after Accepted; only Closed comes
-- after Appointed. Each operation below spells its split out
-- exhaustively, no wildcard over IntakeRequest's cases where the answer
-- differs between them.
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
  | RequestMovedOn IntakeRequest
  deriving (Show, Eq)

-- The result of a state transition: either it was applied, or the request
-- had already moved on to a later state (see RequestMovedOn above). An
-- outcome, not a ServiceError — losing a race is never the caller's
-- mistake (error-vs-outcome-types).
data TransitionOutcome a
  = Transitioned a
  | MovedOn IntakeRequest
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

-- Creates a new AvailableSlot. The slot's duration is always its
-- HealthcareService's, fetched here (stored-facts-by-reference): the
-- caller names the service, never the length. A missing service is
-- HealthcareServiceNotFound, not an outcome — services are never deleted,
-- so an unknown id is the caller's mistake, not a lost race — and since
-- services are never updated either, the fetched duration can't go stale
-- before the insert. Then fetches the doctor's stored entries that
-- intersect the new slot's interval, checks it fits via
-- Domain.addAvailableSlot, then inserts. A concurrent insert between the
-- fetch and the write is caught by doctor_calendar's EXCLUDE constraint
-- (Persistence.insertAvailableSlot's SlotOverlap) — both paths report the
-- same SlotConflict, since to the caller both mean "this time is taken".
-- Stored entries that already overlap surface as PersistenceDecodeError
-- (OverlappingCalendarEntries). Named createAvailableSlot,
-- not submitAvailableSlot — "submit" implies something flowing to an
-- authority for acceptance/rejection (correct for SubmittedIntakeRequest,
-- which awaits a triager's judgment); a slot is declared into existence
-- by the authority itself, no acceptance step, so "create" is the
-- accurate verb here.
createAvailableSlot
  :: ConnectionPool
  -> DoctorId
  -> HealthcareServiceId
  -> UTCTime             -- start
  -> IO (Either ServiceError SlotCreationOutcome)
createAvailableSlot pool doctorId healthcareServiceId start = withResource pool $ \conn -> do
  doctor        <- Persistence.fetchDoctor conn doctorId
  serviceResult <- Persistence.fetchHealthcareService conn healthcareServiceId
  case (doctor, serviceResult) of
    (Nothing, _)             -> pure (Left (DoctorNotFound doctorId))
    (_, Left err)            -> pure (Left (PersistenceDecodeError err))
    (_, Right Nothing)       -> pure (Left (HealthcareServiceNotFound healthcareServiceId))
    (_, Right (Just service)) -> do
      slotId <- newSlotId
      let end = addUTCTime (durationToNominalDiffTime service.duration) start
      calendarResult <- fetchDoctorCalendar conn doctorId start end
      case calendarResult of
        Left err -> pure (Left (PersistenceDecodeError err))
        Right calendar -> case addAvailableSlot calendar slotId doctorId service start of
          Nothing        -> pure (Right SlotConflict)
          Just (slot, _) -> do
            result <- insertAvailableSlot conn slot
            pure . Right $ case result of
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
-- minimal-types-minimal-tables); the one thing that can fail is an unknown
-- patient, reported as PatientNotFound. Also the entry point for a doctor
-- scheduling a follow-up: same flow, doctor as both author and triager —
-- see docs/decisions.md's "Doctor-originated requests reuse the existing
-- flow unchanged". That case needs no special handling here; the caller
-- just calls this and then acceptSubmittedIntakeRequest back-to-back.
submitIntakeRequest
  :: ConnectionPool
  -> PatientId
  -> Text                -- narrative
  -> UTCTime             -- createdAt
  -> IO (Either ServiceError SubmittedIntakeRequest)
submitIntakeRequest pool patientId narrative createdAt =
  withResource pool $ \conn -> do
    patient <- Persistence.fetchPatient conn patientId
    case patient of
      Nothing -> pure (Left (PatientNotFound patientId))
      Just _  -> do
        reqId <- newIntakeRequestId
        let submitted = SubmittedIntakeRequest { id = reqId, patientId, narrative, createdAt }
        insertSubmittedIntakeRequest conn submitted
        pure (Right submitted)

-- Mirrors Domain.acceptIntakeRequest. Named acceptSubmittedIntakeRequest,
-- not acceptIntakeRequest or acceptRequest — per this module's
-- verifies-the-precondition convention: Domain.acceptIntakeRequest takes
-- a bare SubmittedIntakeRequest and has no way to check it actually came
-- from a real, currently Submitted stored request. This wrapper is
-- defined by that check: fetches by IntakeRequestId and confirms
-- Right (Just (Submitted submitted)). Every other state comes after
-- Submitted, so any other state is MovedOn, never RequestInWrongState.
-- The write is guarded on state = 'submitted'; if the request moved on in
-- between, the result is MovedOn too (guard-every-fetch-then-write-gap).
acceptSubmittedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> HealthcareServiceId
  -> IntakeRequestPriority
  -> DoctorRequirement   -- decided by triage; matching uses this
  -> UTCTime             -- triagedAt
  -> IO (Either ServiceError (TransitionOutcome TriagedIntakeRequest))
acceptSubmittedIntakeRequest pool requestId healthcareServiceId priority doctorRequirement triagedAt =
  withResource pool $ \conn -> do
    reqResult <- Persistence.fetchIntakeRequest conn requestId
    case reqResult of
      Left err                           -> pure (Left (PersistenceDecodeError err))
      Right Nothing                      -> pure (Left (RequestNotFound requestId))
      Right (Just (Submitted submitted)) -> do
        references <- checkTriageReferences conn healthcareServiceId doctorRequirement
        case references of
          Left err -> pure (Left err)
          Right () -> do
            let triaged = acceptIntakeRequest submitted healthcareServiceId priority doctorRequirement triagedAt
            claim <- persistTriagedIntakeRequest conn triaged
            case claim of
              Claimed        -> pure (Right (Transitioned triaged))
              AlreadyClaimed -> fmap MovedOn <$> refetchAfterLostWrite conn requestId
      Right (Just current)               -> pure (Right (MovedOn current))

-- No Domain.hs verb to wrap — rejection is direct construction
-- (Rejected submitted rejectedAt reason), per the settled design: there
-- is deliberately no rejectIntakeRequest function in Domain.hs. This
-- wrapper's whole job is the same precondition check as
-- acceptSubmittedIntakeRequest's, applied to the reject path instead,
-- including the same state = 'submitted' guard on the write and the same
-- MovedOn for every other state.
rejectSubmittedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> UTCTime             -- rejectedAt
  -> Text                -- reason
  -> IO (Either ServiceError (TransitionOutcome IntakeRequest))
rejectSubmittedIntakeRequest pool requestId rejectedAt reason =
  withResource pool $ \conn -> do
    reqResult <- Persistence.fetchIntakeRequest conn requestId
    case reqResult of
      Left err                           -> pure (Left (PersistenceDecodeError err))
      Right Nothing                      -> pure (Left (RequestNotFound requestId))
      Right (Just (Submitted submitted)) -> do
        let rejected = Rejected submitted rejectedAt reason
        claim <- persistRejectedIntakeRequest conn submitted rejectedAt reason
        case claim of
          Claimed        -> pure (Right (Transitioned rejected))
          AlreadyClaimed -> fmap MovedOn <$> refetchAfterLostWrite conn requestId
      Right (Just current)               -> pure (Right (MovedOn current))

-- Mirrors Domain.checkIntakeWaitlist: a newly available slot scans the
-- waitlist in priority order; the first eligible request is matched and
-- committed. Unlike the old checkWaitlist, no AppointmentId needs minting
-- before the scan — IntakeRequestId already exists on the request itself
-- (carried through since submitIntakeRequest), so there's no separate
-- identity to produce.
matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)
matchWaitlistToSlot pool slot = withResource pool $ \conn -> do
  waitlistResult <- Persistence.fetchIntakeWaitlist conn
  case waitlistResult of
    Left err -> pure (Left (PersistenceDecodeError err))
    Right waitlist ->
      case checkIntakeWaitlist slot waitlist of
        Nothing        -> pure (Right NoEligibleRequest)
        Just appointed -> persistMatch conn slot appointed

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
-- IntakeRequestId, confirms Right (Just (Accepted triaged)), and answers
-- otherwise. Deliberately not "force"/"override" in the name — matches is
-- never overridable, even by a manager, so a name suggesting force would
-- overclaim what this bypasses (the scan, not the rules).
--
-- Every IntakeRequest case handled explicitly, no wildcard — so GHC's
-- exhaustiveness check keeps this honest if a future case is ever added.
-- Appointed/Stale/WithdrawnFromAccepted/Closed come after Accepted:
-- RequestMovedOn. Submitted/Rejected/WithdrawnFromSubmitted can't:
-- RequestInWrongState.
--
-- RequestIneligible (matchIntakeRequestToSlot returns Nothing) is a
-- distinct MatchOutcome constructor from NoEligibleRequest: there was no
-- scan here to come up empty, the caller picked one specific pair and it
-- doesn't structurally fit; try a different slot or request.
--
-- The write path — persistMatch — is shared verbatim with
-- matchWaitlistToSlot, not rebuilt: both entry points write through the
-- identical intake_requests/slots tables and need the identical dual-race
-- guard (persistMatchedIntakeRequest's slot-side and request-side checks).
-- They differ only in how the TriagedIntakeRequest is obtained (scan vs.
-- fetched-and-validated by ID); everything downstream of that is one
-- function.
--
-- Takes a SlotId, not an AvailableSlot, and matches against the stored
-- slot: the caller is not authoritative about a slot's doctor/start/
-- duration, and those are what the appointment copies. A missing slot is
-- SlotAlreadyClaimed — under deleted-on-match, "claimed a moment ago" and
-- "never existed" look identical, and the former is the realistic case.
-- Slots are never updated, only deleted, so the fetch-then-write gap is
-- covered by persistMatchedIntakeRequest's existing slot-side guard.
matchAcceptedIntakeRequestToSlot
  :: ConnectionPool
  -> IntakeRequestId
  -> SlotId
  -> IO (Either ServiceError MatchOutcome)
matchAcceptedIntakeRequestToSlot pool requestId slotId = withResource pool $ \conn -> do
  reqResult <- Persistence.fetchIntakeRequest conn requestId
  case reqResult of
    Left err                        -> pure (Left (PersistenceDecodeError err))
    Right Nothing                   -> pure (Left (RequestNotFound requestId))
    Right (Just (Accepted triaged)) -> do
      slotResult <- fetchSlot conn slotId
      case slotResult of
        Left err          -> pure (Left (PersistenceDecodeError err))
        Right Nothing     -> pure (Right SlotAlreadyClaimed)
        Right (Just slot) ->
          case matchIntakeRequestToSlot slot triaged of
            Nothing        -> pure (Right RequestIneligible)
            Just appointed -> persistMatch conn slot appointed
    Right (Just current) -> pure $ case current of
      Appointed _                            -> Right (RequestMovedOn current)
      Stale {}                               -> Right (RequestMovedOn current)
      Withdrawn (WithdrawnFromAccepted {})   -> Right (RequestMovedOn current)
      Closed {}                              -> Right (RequestMovedOn current)
      Submitted _                            -> Left (RequestInWrongState current)
      Rejected {}                            -> Left (RequestInWrongState current)
      Withdrawn (WithdrawnFromSubmitted {})  -> Left (RequestInWrongState current)

-- Shared tail of matchWaitlistToSlot/matchAcceptedIntakeRequestToSlot:
-- persists an already-produced AppointedIntakeRequest and translates
-- Persistence's MatchPersistOutcome into this module's MatchOutcome. Not
-- exported — an internal helper, not its own use case (function-per-use-case
-- is about public operations, not every internal step).
persistMatch :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO (Either ServiceError MatchOutcome)
persistMatch conn slot appointed = do
  claim <- persistMatchedIntakeRequest conn slot.id appointed
  case claim of
    MatchPersisted        -> pure (Right (Matched appointed))
    SlotAlreadyGone       -> pure (Right SlotAlreadyClaimed)
    RequestAlreadyMatched ->
      fmap RequestMovedOn <$> refetchAfterLostWrite conn appointed.triaged.submitted.id

-- Closes out an Accepted request that never got matched to a slot or
-- withdrawn — staff-initiated only (see Domain.hs's own comment on
-- Stale). Mirrors closeAppointedIntakeRequest's shape, one precondition
-- swapped: requires Accepted instead of Appointed. No
-- Domain-level "mark stale" function to wrap — Stale is direct
-- construction in Domain.hs (Stale triaged staleAt), same as
-- Rejected/Withdrawn/Closed's own direct-construction cases — so this
-- wrapper's whole job is the precondition check: fetch by
-- IntakeRequestId, confirm Right (Just (Accepted triaged)), answer
-- otherwise.
--
-- staleAt is caller-supplied, not generated internally via
-- getCurrentTime — same convention as every other Service.hs mutation's
-- timestamp parameter (createdAt/triagedAt/rejectedAt/etc.); Api.hs's
-- handler owns calling getCurrentTime and passing the result in.
--
-- Same split as matchAcceptedIntakeRequestToSlot, every case explicit:
-- Appointed/Stale/WithdrawnFromAccepted/Closed come after Accepted
-- (MovedOn); Submitted/Rejected/WithdrawnFromSubmitted can't
-- (RequestInWrongState). A request that moves on between the fetch and
-- the write is MovedOn too.
markIntakeRequestStale
  :: ConnectionPool
  -> IntakeRequestId
  -> UTCTime             -- staleAt
  -> IO (Either ServiceError (TransitionOutcome TriagedIntakeRequest))
markIntakeRequestStale pool requestId staleAt = withResource pool $ \conn -> do
  reqResult <- Persistence.fetchIntakeRequest conn requestId
  case reqResult of
    Left err                        -> pure (Left (PersistenceDecodeError err))
    Right Nothing                   -> pure (Left (RequestNotFound requestId))
    Right (Just (Accepted triaged)) -> do
      claim <- persistStaleIntakeRequest conn requestId staleAt
      case claim of
        Claimed        -> pure (Right (Transitioned triaged))
        AlreadyClaimed -> fmap MovedOn <$> refetchAfterLostWrite conn requestId
    Right (Just current) -> pure $ case current of
      Appointed _                            -> Right (MovedOn current)
      Stale {}                               -> Right (MovedOn current)
      Withdrawn (WithdrawnFromAccepted {})   -> Right (MovedOn current)
      Closed {}                              -> Right (MovedOn current)
      Submitted _                            -> Left (RequestInWrongState current)
      Rejected {}                            -> Left (RequestInWrongState current)
      Withdrawn (WithdrawnFromSubmitted {})  -> Left (RequestInWrongState current)

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
-- Guarded twice: the initial fetch catches the common case (already
-- closed by the time this is called), and the write is conditioned on
-- state = 'appointed'. Without that, a concurrent close could silently
-- overwrite which reason it closed for; the result is MovedOn instead,
-- carrying the reason the other close recorded.
--
-- Every IntakeRequest case handled explicitly, no wildcard: only Closed
-- comes after Appointed (MovedOn); Submitted/Rejected/Accepted/Withdrawn/
-- Stale can't (RequestInWrongState).
closeAppointedIntakeRequest
  :: ConnectionPool
  -> IntakeRequestId
  -> CloseReason
  -> IO (Either ServiceError (TransitionOutcome IntakeRequest))
closeAppointedIntakeRequest pool requestId reason = withResource pool $ \conn -> do
  reqResult <- Persistence.fetchIntakeRequest conn requestId
  case reqResult of
    Left err                           -> pure (Left (PersistenceDecodeError err))
    Right Nothing                      -> pure (Left (RequestNotFound requestId))
    Right (Just (Appointed appointed)) -> do
      let closed = Closed appointed reason
      claim <- persistClosedIntakeRequestIfAppointed conn appointed reason
      case claim of
        Claimed        -> pure (Right (Transitioned closed))
        AlreadyClaimed -> fmap MovedOn <$> refetchAfterLostWrite conn requestId
    Right (Just current) -> pure $ case current of
      Closed {}     -> Right (MovedOn current)
      Submitted _   -> Left (RequestInWrongState current)
      Rejected {}   -> Left (RequestInWrongState current)
      Accepted _    -> Left (RequestInWrongState current)
      Withdrawn _   -> Left (RequestInWrongState current)
      Stale {}      -> Left (RequestInWrongState current)

-- After a transition write matched no row: read the request again to
-- report where it went. Its state guard failed, and states only move
-- forward, so what this finds is a later state — MovedOn/RequestMovedOn,
-- never RequestInWrongState. Requests are never deleted, so Nothing here
-- would mean a broken database; reported as RequestNotFound.
refetchAfterLostWrite :: Connection -> IntakeRequestId -> IO (Either ServiceError IntakeRequest)
refetchAfterLostWrite conn requestId = do
  reqResult <- Persistence.fetchIntakeRequest conn requestId
  pure $ case reqResult of
    Left err             -> Left (PersistenceDecodeError err)
    Right Nothing        -> Left (RequestNotFound requestId)
    Right (Just current) -> Right current

-- Unknown references are reported as ServiceErrors (the caller named an id
-- that doesn't exist), not left to the foreign keys, which would surface as
-- an unhandled SqlError. Doctors, patients and services are never deleted,
-- so an id that exists when checked still exists at the write that follows
-- — no guard is needed for that gap.
checkTriageReferences :: Connection -> HealthcareServiceId -> DoctorRequirement -> IO (Either ServiceError ())
checkTriageReferences conn healthcareServiceId requirement = do
  serviceResult <- Persistence.fetchHealthcareService conn healthcareServiceId
  case serviceResult of
    Left err       -> pure (Left (PersistenceDecodeError err))
    Right Nothing  -> pure (Left (HealthcareServiceNotFound healthcareServiceId))
    Right (Just _) -> case requirement of
      AnyDoctor          -> pure (Right ())
      SpecificDoctor did -> maybe (Left (DoctorNotFound did)) (const (Right ())) <$> Persistence.fetchDoctor conn did

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

fetchAvailableSlots
  :: ConnectionPool -> UTCTime -> UTCTime -> Maybe DoctorId
  -> Maybe HealthcareServiceId -> IO (Either DecodeError [AvailableSlot])
fetchAvailableSlots pool rangeStart rangeEnd mDoctorId mServiceId =
  withResource pool $ \conn ->
    Persistence.fetchAvailableSlots conn rangeStart rangeEnd mDoctorId mServiceId

fetchAppointedIntakeRequests
  :: ConnectionPool -> Maybe UTCTime -> Maybe UTCTime -> Maybe DoctorId
  -> IO (Either DecodeError [AppointedIntakeRequest])
fetchAppointedIntakeRequests pool mRangeStart mRangeEnd mDoctorId =
  withResource pool $ \conn ->
    Persistence.fetchAppointedIntakeRequests conn mRangeStart mRangeEnd mDoctorId

-- Mirrors fetchAppointedIntakeRequests's pre-loosening shape exactly —
-- required range, optional doctorId — the deliberately opposite default:
-- state = 'closed' requests only ever accumulate (docs/decisions.md's
-- no-delete-on-consumption reasoning), so an unbounded query here really
-- would grow without limit, unlike the live appointed set above.
fetchClosedIntakeRequests
  :: ConnectionPool -> UTCTime -> UTCTime -> Maybe DoctorId
  -> IO (Either DecodeError [IntakeRequest])
fetchClosedIntakeRequests pool rangeStart rangeEnd mDoctorId =
  withResource pool $ \conn ->
    Persistence.fetchClosedIntakeRequests conn rangeStart rangeEnd mDoctorId

-- These two specifically were already in use internally — by
-- acceptSubmittedIntakeRequest, rejectSubmittedIntakeRequest,
-- matchAcceptedIntakeRequestToSlot, markIntakeRequestStale, and
-- closeAppointedIntakeRequest (fetchIntakeRequest), and by
-- matchWaitlistToSlot (fetchIntakeWaitlist) — as an internal
-- fetch-then-check step inside those mutation wrappers' own
-- guard-every-fetch-then-write-gap logic, long before either was exposed
-- as its own top-level read here. This closes the one gap flagged when
-- triage-api-codegen's commands-vs-queries-naming was last updated: every
-- Persistence.hs read now has a Service.hs wrapper, no exceptions
-- remaining.
fetchIntakeRequest :: ConnectionPool -> IntakeRequestId -> IO (Either DecodeError (Maybe IntakeRequest))
fetchIntakeRequest pool requestId = withResource pool $ \conn ->
  Persistence.fetchIntakeRequest conn requestId

fetchIntakeWaitlist :: ConnectionPool -> IO (Either DecodeError [TriagedIntakeRequest])
fetchIntakeWaitlist pool = withResource pool $ \conn ->
  Persistence.fetchIntakeWaitlist conn

-- Mirrors fetchIntakeWaitlist exactly, one state over — a specific,
-- purpose-named business list (state = 'submitted'), not a generic
-- state-filter parameter, same reasoning as fetchIntakeWaitlist's own
-- naming.
fetchSubmittedIntakeRequests :: ConnectionPool -> IO (Either DecodeError [SubmittedIntakeRequest])
fetchSubmittedIntakeRequests pool = withResource pool $ \conn ->
  Persistence.fetchSubmittedIntakeRequests conn

-- ═══════════════════════════════════════════════════════════════════════
-- CALENDAR
-- CalendarEntry itself lives in Domain.hs, as the unit DoctorCalendar's
-- no-overlap invariant is stated over (see docs/decisions.md). This
-- section only composes the stored entries into a time-ordered view.
-- ═══════════════════════════════════════════════════════════════════════

-- Composes fetchAvailableSlots and fetchAppointedIntakeRequests rather
-- than reading doctor_calendar directly — that table's schema is
-- deliberately minimized for its one job (overlap enforcement via its
-- EXCLUDE constraint) and was never meant to serve as a display/read
-- model; reading it directly here would couple an enforcement mechanism
-- to an unrelated display concern.
--
-- healthcare_service_id filtering is intentionally NOT exposed here —
-- fetchAvailableSlots's own optional service filter is fixed to Nothing.
-- A calendar view is scoped by time and doctor, not by service; a
-- service-filtered variant is a new, separate parameter to add
-- deliberately if ever needed, not assumed now.
--
-- fetchAppointedIntakeRequests's own range is optional (see its own
-- comment), but fetchCalendarView's own range stays required regardless
-- — a calendar view scoped to "forever" is exactly the unbounded query
-- fetchAppointedIntakeRequests's own looser default was never meant to
-- invite — so this wraps rangeStart/rangeEnd in Just at the call site
-- rather than loosening fetchCalendarView's own signature to match.
fetchCalendarView
  :: ConnectionPool -> UTCTime -> UTCTime -> Maybe DoctorId
  -> IO (Either DecodeError [CalendarEntry])
fetchCalendarView pool rangeStart rangeEnd mDoctorId = do
  slotsResult     <- fetchAvailableSlots pool rangeStart rangeEnd mDoctorId Nothing
  appointedResult <- fetchAppointedIntakeRequests pool (Just rangeStart) (Just rangeEnd) mDoctorId
  pure $ do
    slots     <- slotsResult
    appointed <- appointedResult
    pure . sortOn calendarEntryStart $ map Slot slots ++ map Appointment appointed

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
