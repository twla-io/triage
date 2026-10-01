{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- Derived from src/Domain.hs and src/Persistence.hs by the
-- triage-service-codegen skill. One function per use case; each checks out
-- one connection from the pool and uses it for every Persistence call.
module Service
  ( -- ── Error facts ──────────────────────────────────────────────────────
    DoctorNotFound (..)
  , PatientNotFound (..)
  , HealthcareServiceNotFound (..)
  , IntakeRequestNotFound (..)
  , IntakeRequestInWrongState (..)
  , SlotDoesNotMatchIntakeRequest (..)

    -- ── Per-use-case errors (several facts) ──────────────────────────────
  , AcceptSubmittedIntakeRequestError (..)
  , MatchAcceptedIntakeRequestToSlotError (..)
  , MarkAcceptedIntakeRequestStaleError (..)
  , CloseAppointedIntakeRequestError (..)
  , CreateAvailableSlotError (..)

    -- ── Outcomes ─────────────────────────────────────────────────────────
  , TransitionOutcome (..)
  , MatchOutcome (..)
  , PriorityMatchOutcome (..)
  , SlotCreationOutcome (..)

    -- ── Create ───────────────────────────────────────────────────────────
  , createDoctor
  , createPatient
  , createHealthcareService
  , submitIntakeRequest

    -- ── Transitions ──────────────────────────────────────────────────────
  , acceptSubmittedIntakeRequest
  , rejectSubmittedIntakeRequest
  , matchAcceptedIntakeRequestToSlot
  , withdrawIntakeRequest
  , markAcceptedIntakeRequestStale
  , closeAppointedIntakeRequest

    -- ── Domain function over stored values ───────────────────────────────
  , matchAvailableSlotByPriority

    -- ── Grow the sealed collection ───────────────────────────────────────
  , createAvailableSlot

    -- ── Reads ────────────────────────────────────────────────────────────
  , fetchDoctor
  , fetchDoctors
  , fetchPatient
  , fetchPatients
  , fetchHealthcareService
  , fetchHealthcareServices
  , fetchAvailableSlot
  , fetchIntakeRequest
  , fetchSubmittedIntakeRequests
  , fetchAcceptedIntakeRequests
  , fetchAppointedIntakeRequests
  , fetchRejectedIntakeRequestsByRejectedAt
  , fetchWithdrawnIntakeRequestsByWithdrawnAt
  , fetchStaleIntakeRequestsByStaleAt
  , fetchClosedIntakeRequestsByStart
  , fetchDoctorCalendarEntriesOverlapping
  ) where

import Prelude hiding (id)

import Control.Exception          (throwIO)
import Control.Monad              (void)
import Control.Monad.Trans.Class  (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Pool                  (withResource)
import Data.Text                  (Text)
import Data.Time                  (UTCTime)
import Data.UUID.V4               (nextRandom)
import Data.Void                  (absurd)
import Database.PostgreSQL.Simple (Connection)

import Domain
import Persistence (ConnectionPool)

import qualified Persistence as P

-- ═══════════════════════════════════════════════════════════════════════════
-- ERROR FACTS
-- A fact about the caller's request that no concurrent operation can change.
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorNotFound            = DoctorNotFound            DoctorId            deriving (Show, Eq)
newtype PatientNotFound           = PatientNotFound           PatientId           deriving (Show, Eq)
newtype HealthcareServiceNotFound = HealthcareServiceNotFound HealthcareServiceId deriving (Show, Eq)
newtype IntakeRequestNotFound     = IntakeRequestNotFound     IntakeRequestId     deriving (Show, Eq)

-- The request as it is, in a case the expected one can never lead to.
newtype IntakeRequestInWrongState = IntakeRequestInWrongState IntakeRequest
  deriving (Show, Eq)

-- matchIntakeRequestToSlot's refusal: the slot the caller chose doesn't
-- match the request (service, doctor requirement or time).
data SlotDoesNotMatchIntakeRequest = SlotDoesNotMatchIntakeRequest
  deriving (Show, Eq)

data AcceptSubmittedIntakeRequestError
  = AcceptSubmittedIntakeRequestIntakeRequestNotFound     IntakeRequestNotFound
  | AcceptSubmittedIntakeRequestHealthcareServiceNotFound HealthcareServiceNotFound
  | AcceptSubmittedIntakeRequestDoctorNotFound            DoctorNotFound
  deriving (Show, Eq)

data MatchAcceptedIntakeRequestToSlotError
  = MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound         IntakeRequestNotFound
  | MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState     IntakeRequestInWrongState
  | MatchAcceptedIntakeRequestToSlotSlotDoesNotMatchIntakeRequest SlotDoesNotMatchIntakeRequest
  deriving (Show, Eq)

data MarkAcceptedIntakeRequestStaleError
  = MarkAcceptedIntakeRequestStaleIntakeRequestNotFound     IntakeRequestNotFound
  | MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState IntakeRequestInWrongState
  deriving (Show, Eq)

data CloseAppointedIntakeRequestError
  = CloseAppointedIntakeRequestIntakeRequestNotFound     IntakeRequestNotFound
  | CloseAppointedIntakeRequestIntakeRequestInWrongState IntakeRequestInWrongState
  deriving (Show, Eq)

data CreateAvailableSlotError
  = CreateAvailableSlotDoctorNotFound            DoctorNotFound
  | CreateAvailableSlotHealthcareServiceNotFound HealthcareServiceNotFound
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- OUTCOMES
-- Reality moved between two valid operations.
-- ═══════════════════════════════════════════════════════════════════════════

-- A transition under a single guard: done, or someone acted first.
data TransitionOutcome a
  = Transitioned a
  | MovedOn IntakeRequest
  deriving (Show, Eq)

-- Matching, one-to-one with Persistence's MatchClaimOutcome.
data MatchOutcome
  = Matched               AppointedIntakeRequest
  | AvailableSlotConsumed                         -- the slot is gone
  | IntakeRequestMovedOn  IntakeRequest           -- the request left Accepted
  deriving (Show, Eq)

-- matchByPriority over the waitlist: no candidate fits, or the match write's
-- outcome.
data PriorityMatchOutcome
  = NoMatchingIntakeRequest
  | MatchOutcome MatchOutcome
  deriving (Show, Eq)

-- A new slot, one-to-one with Persistence's SlotInsertOutcome. addAvailableSlot
-- declining and the EXCLUDE constraint rejecting are the same fact.
data SlotCreationOutcome
  = SlotCreated AvailableSlot
  | SlotOverlapsDoctorCalendar
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

-- Stored data that violates the spec is not an answer: raised as the
-- DecodeError exception (a 500).
decoded :: IO (Either P.DecodeError a) -> IO a
decoded action = action >>= either throwIO pure

-- A Nothing is the given fact.
require :: e -> IO (Maybe a) -> ExceptT e IO a
require fact action = lift action >>= maybe (throwE fact) pure

fetchIntakeRequestOr
  :: (IntakeRequestNotFound -> e) -> Connection -> IntakeRequestId -> ExceptT e IO IntakeRequest
fetchIntakeRequestOr wrap conn requestId =
  require (wrap (IntakeRequestNotFound requestId)) (decoded (P.fetchIntakeRequest conn requestId))

-- After a lost guard: the request as it is now. Cases only move forward,
-- so this always finds a later case; nothing retries.
movedOnAfterLostRace
  :: (IntakeRequestNotFound -> e) -> Connection -> IntakeRequestId
  -> ExceptT e IO (TransitionOutcome a)
movedOnAfterLostRace wrap conn requestId = MovedOn <$> fetchIntakeRequestOr wrap conn requestId

-- A transition write under its single source guard.
claimed
  :: (IntakeRequestNotFound -> e) -> Connection -> IntakeRequestId -> a -> IO P.ClaimOutcome
  -> ExceptT e IO (TransitionOutcome a)
claimed wrap conn requestId next write = do
  outcome <- lift write
  case outcome of
    P.Claimed        -> pure (Transitioned next)
    P.AlreadyClaimed -> movedOnAfterLostRace wrap conn requestId

-- The match write: deletes the slot and moves the request to Appointed in
-- one transaction. A lost request race reads the request once more; the
-- given action answers if it has vanished (requests are never deleted).
persistMatch
  :: Connection -> AvailableSlot -> AppointedIntakeRequest -> ExceptT e IO IntakeRequest
  -> ExceptT e IO MatchOutcome
persistMatch conn slot appointed reread = do
  outcome <- lift (P.persistAppointedIntakeRequest conn slot appointed)
  case outcome of
    P.MatchClaimed                -> pure (Matched appointed)
    P.SlotAlreadyClaimed          -> pure AvailableSlotConsumed
    P.IntakeRequestAlreadyClaimed -> IntakeRequestMovedOn <$> reread

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATE
-- ═══════════════════════════════════════════════════════════════════════════

createDoctor :: ConnectionPool -> Text -> IO Doctor
createDoctor pool name =
  withResource pool $ \conn -> do
    doctorId <- DoctorId <$> nextRandom
    let doctor = Doctor { id = doctorId, name }
    P.insertDoctor conn doctor
    pure doctor

createPatient :: ConnectionPool -> Text -> IO Patient
createPatient pool name =
  withResource pool $ \conn -> do
    patientId <- PatientId <$> nextRandom
    let patient = Patient { id = patientId, name }
    P.insertPatient conn patient
    pure patient

createHealthcareService :: ConnectionPool -> Text -> Duration -> IO HealthcareService
createHealthcareService pool name duration =
  withResource pool $ \conn -> do
    serviceId <- HealthcareServiceId <$> nextRandom
    let service = HealthcareService { id = serviceId, name, duration }
    P.insertHealthcareService conn service
    pure service

-- The entry case of IntakeRequest. Patients are never deleted, so the
-- check can't race the insert.
submitIntakeRequest
  :: ConnectionPool -> PatientId -> Text -> UTCTime
  -> IO (Either PatientNotFound SubmittedIntakeRequest)
submitIntakeRequest pool patientId narrative createdAt =
  withResource pool $ \conn -> runExceptT $ do
    _ <- require (PatientNotFound patientId) (P.fetchPatient conn patientId)
    requestId <- lift (IntakeRequestId <$> nextRandom)
    let submitted = SubmittedIntakeRequest { id = requestId, patientId, narrative, createdAt }
    lift (P.insertSubmittedIntakeRequest conn submitted)
    pure submitted

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSITIONS
-- Each case split is over Domain.hs's transition graph: a case reachable
-- from the expected one is MovedOn, any other is InWrongState.
-- ═══════════════════════════════════════════════════════════════════════════

-- Submitted → Accepted. In the gap, the request can be accepted, rejected
-- or withdrawn by someone else (the guard catches it). Services and doctors
-- are never deleted.
acceptSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> HealthcareServiceId -> IntakeRequestPriority
  -> DoctorRequirement -> UTCTime
  -> IO (Either AcceptSubmittedIntakeRequestError (TransitionOutcome TriagedIntakeRequest))
acceptSubmittedIntakeRequest pool requestId serviceId priority doctorRequirement triagedAt =
  withResource pool $ \conn -> runExceptT $ do
    let notFound = AcceptSubmittedIntakeRequestIntakeRequestNotFound
    current <- fetchIntakeRequestOr notFound conn requestId
    _ <- require
      (AcceptSubmittedIntakeRequestHealthcareServiceNotFound (HealthcareServiceNotFound serviceId))
      (decoded (P.fetchHealthcareService conn serviceId))
    case doctorRequirement of
      AnyDoctor               -> pure ()
      SpecificDoctor doctorId ->
        void $ require
          (AcceptSubmittedIntakeRequestDoctorNotFound (DoctorNotFound doctorId))
          (P.fetchDoctor conn doctorId)
    let movedOn = pure (MovedOn current)
    case current of
      Submitted submitted -> do
        let triaged = acceptIntakeRequest submitted serviceId priority doctorRequirement triagedAt
        claimed notFound conn requestId triaged (P.persistTriagedIntakeRequest conn triaged)
      Rejected _  -> movedOn
      Accepted _  -> movedOn
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> movedOn
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- Submitted → Rejected. In the gap, the request can be accepted, rejected
-- or withdrawn by someone else (the guard catches it).
rejectSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Text
  -> IO (Either IntakeRequestNotFound (TransitionOutcome RejectedIntakeRequest))
rejectSubmittedIntakeRequest pool requestId rejectedAt rejectionReason =
  withResource pool $ \conn -> runExceptT $ do
    let notFound fact = fact
    current <- fetchIntakeRequestOr notFound conn requestId
    let movedOn = pure (MovedOn current)
    case current of
      Submitted submitted -> do
        let rejected = RejectedIntakeRequest { submitted, rejectedAt, rejectionReason }
        claimed notFound conn requestId rejected (P.persistRejectedIntakeRequest conn rejected)
      Rejected _  -> movedOn
      Accepted _  -> movedOn
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> movedOn
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- Accepted → Appointed (matchIntakeRequestToSlot). In the gap, the slot can
-- be matched to another request (deleted), and the request can be matched,
-- withdrawn or marked stale; the match write reports either.
matchAcceptedIntakeRequestToSlot
  :: ConnectionPool -> IntakeRequestId -> SlotId
  -> IO (Either MatchAcceptedIntakeRequestToSlotError MatchOutcome)
matchAcceptedIntakeRequestToSlot pool requestId slotId =
  withResource pool $ \conn -> runExceptT $ do
    let notFound = MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound
    current <- fetchIntakeRequestOr notFound conn requestId
    let movedOn    = pure (IntakeRequestMovedOn current)
        wrongState = throwE (MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState
                               (IntakeRequestInWrongState current))
    case current of
      Submitted _ -> wrongState
      Rejected _  -> wrongState
      Accepted triaged -> do
        found <- lift (decoded (P.fetchAvailableSlot conn slotId))
        case found of
          Nothing   -> pure AvailableSlotConsumed
          Just slot -> case matchIntakeRequestToSlot slot triaged of
            Nothing        ->
              throwE (MatchAcceptedIntakeRequestToSlotSlotDoesNotMatchIntakeRequest
                        SlotDoesNotMatchIntakeRequest)
            Just appointed ->
              persistMatch conn slot appointed (fetchIntakeRequestOr notFound conn requestId)
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- Submitted → Withdrawn or Accepted → Withdrawn, recorded in withdrawnFrom.
-- In the gap, the request can move on from the case it was found in; if it
-- was Submitted and is now Accepted, the withdrawal continues once from
-- there, under Accepted's guard.
withdrawIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Maybe Text
  -> IO (Either IntakeRequestNotFound (TransitionOutcome WithdrawnIntakeRequest))
withdrawIntakeRequest pool requestId withdrawnAt withdrawalNote =
  withResource pool $ \conn -> runExceptT $ do
    let notFound fact = fact
        withdrawnFrom from = WithdrawnIntakeRequest { withdrawnFrom = from, withdrawnAt, withdrawalNote }
        persist withdrawn  = P.persistWithdrawnIntakeRequest conn withdrawn
        continueFromAccepted current = do
          let movedOn = pure (MovedOn current)
          case current of
            Submitted _ -> movedOn
            Rejected _  -> movedOn
            Accepted triaged -> do
              let withdrawn = withdrawnFrom (FromAccepted triaged)
              claimed notFound conn requestId withdrawn (persist withdrawn)
            Appointed _ -> movedOn
            Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
              FromSubmitted _ -> movedOn
              FromAccepted _  -> movedOn
            Stale _     -> movedOn
            Closed _    -> movedOn
    current <- fetchIntakeRequestOr notFound conn requestId
    let movedOn = pure (MovedOn current)
    case current of
      Submitted submitted -> do
        let withdrawn = withdrawnFrom (FromSubmitted submitted)
        outcome <- lift (persist withdrawn)
        case outcome of
          P.Claimed        -> pure (Transitioned withdrawn)
          P.AlreadyClaimed -> fetchIntakeRequestOr notFound conn requestId >>= continueFromAccepted
      Rejected _  -> movedOn
      Accepted triaged -> do
        let withdrawn = withdrawnFrom (FromAccepted triaged)
        claimed notFound conn requestId withdrawn (persist withdrawn)
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> movedOn
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- Accepted → Stale, a staff decision. In the gap, the request can be
-- matched, withdrawn or marked stale by someone else (the guard catches it).
markAcceptedIntakeRequestStale
  :: ConnectionPool -> IntakeRequestId -> UTCTime
  -> IO (Either MarkAcceptedIntakeRequestStaleError (TransitionOutcome StaleIntakeRequest))
markAcceptedIntakeRequestStale pool requestId staleAt =
  withResource pool $ \conn -> runExceptT $ do
    let notFound = MarkAcceptedIntakeRequestStaleIntakeRequestNotFound
    current <- fetchIntakeRequestOr notFound conn requestId
    let movedOn    = pure (MovedOn current)
        wrongState = throwE (MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState
                               (IntakeRequestInWrongState current))
    case current of
      Submitted _ -> wrongState
      Rejected _  -> wrongState
      Accepted triaged -> do
        let stale = StaleIntakeRequest { triaged, staleAt }
        claimed notFound conn requestId stale (P.persistStaleIntakeRequest conn stale)
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- Appointed → Closed. In the gap, the request can be closed by someone else
-- (the guard catches it).
closeAppointedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> CloseReason
  -> IO (Either CloseAppointedIntakeRequestError (TransitionOutcome ClosedIntakeRequest))
closeAppointedIntakeRequest pool requestId closeReason =
  withResource pool $ \conn -> runExceptT $ do
    let notFound = CloseAppointedIntakeRequestIntakeRequestNotFound
    current <- fetchIntakeRequestOr notFound conn requestId
    let wrongState = throwE (CloseAppointedIntakeRequestIntakeRequestInWrongState
                               (IntakeRequestInWrongState current))
    case current of
      Submitted _ -> wrongState
      Rejected _  -> wrongState
      Accepted _  -> wrongState
      Appointed appointed -> do
        let closed = ClosedIntakeRequest { appointed, closeReason }
        claimed notFound conn requestId closed (P.persistClosedIntakeRequest conn closed)
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState
        FromAccepted _  -> wrongState
      Stale _     -> wrongState
      Closed _    -> pure (MovedOn current)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOMAIN FUNCTION OVER STORED VALUES
-- ═══════════════════════════════════════════════════════════════════════════

-- matchByPriority over the Accepted requests. In the gap, the slot can be
-- matched elsewhere and the chosen request can move on (the match write
-- reports either); a request accepted after the read is served by the next
-- decision.
matchAvailableSlotByPriority :: ConnectionPool -> SlotId -> IO PriorityMatchOutcome
matchAvailableSlotByPriority pool slotId =
  withResource pool $ \conn -> do
    found <- decoded (P.fetchAvailableSlot conn slotId)
    case found of
      Nothing   -> pure (MatchOutcome AvailableSlotConsumed)
      Just slot -> do
        candidates <- decoded (P.fetchAcceptedIntakeRequests conn)
        case matchByPriority slot candidates of
          Nothing        -> pure NoMatchingIntakeRequest
          Just appointed -> do
            let requestId = appointed.triaged.submitted.id
                -- Requests are never deleted: one that vanished is stored
                -- data violating the spec.
                vanished  = userError ("intake request vanished: " <> show requestId)
                reread    = lift $
                  decoded (P.fetchIntakeRequest conn requestId) >>= maybe (throwIO vanished) pure
            outcome <- runExceptT (persistMatch conn slot appointed reread)
            either absurd (pure . MatchOutcome) outcome

-- ═══════════════════════════════════════════════════════════════════════════
-- GROW THE SEALED COLLECTION
-- ═══════════════════════════════════════════════════════════════════════════

-- addAvailableSlot over the doctor's entries overlapping the new slot. In
-- the gap, another slot can be created over the same time; the EXCLUDE
-- constraint answers that as the same overlap.
createAvailableSlot
  :: ConnectionPool -> DoctorId -> HealthcareServiceId -> UTCTime
  -> IO (Either CreateAvailableSlotError SlotCreationOutcome)
createAvailableSlot pool doctorId serviceId start =
  withResource pool $ \conn -> runExceptT $ do
    _ <- require (CreateAvailableSlotDoctorNotFound (DoctorNotFound doctorId))
           (P.fetchDoctor conn doctorId)
    service <- require
      (CreateAvailableSlotHealthcareServiceNotFound (HealthcareServiceNotFound serviceId))
      (decoded (P.fetchHealthcareService conn serviceId))
    lift $ do
      calendar <- decoded (P.fetchDoctorCalendarOverlapping conn doctorId start service.duration)
      slotId   <- SlotId <$> nextRandom
      case addAvailableSlot calendar slotId doctorId service start of
        Nothing        -> pure SlotOverlapsDoctorCalendar
        Just (slot, _) -> do
          outcome <- P.insertAvailableSlot conn slot
          pure $ case outcome of
            P.SlotInserted               -> SlotCreated slot
            P.SlotOverlapsDoctorCalendar -> SlotOverlapsDoctorCalendar

-- ═══════════════════════════════════════════════════════════════════════════
-- READS
-- ═══════════════════════════════════════════════════════════════════════════

fetchDoctor :: ConnectionPool -> DoctorId -> IO (Either DoctorNotFound Doctor)
fetchDoctor pool doctorId =
  withResource pool $ \conn ->
    maybe (Left (DoctorNotFound doctorId)) Right <$> P.fetchDoctor conn doctorId

fetchDoctors :: ConnectionPool -> IO [Doctor]
fetchDoctors pool = withResource pool P.fetchDoctors

fetchPatient :: ConnectionPool -> PatientId -> IO (Either PatientNotFound Patient)
fetchPatient pool patientId =
  withResource pool $ \conn ->
    maybe (Left (PatientNotFound patientId)) Right <$> P.fetchPatient conn patientId

fetchPatients :: ConnectionPool -> IO [Patient]
fetchPatients pool = withResource pool P.fetchPatients

fetchHealthcareService
  :: ConnectionPool -> HealthcareServiceId -> IO (Either HealthcareServiceNotFound HealthcareService)
fetchHealthcareService pool serviceId =
  withResource pool $ \conn ->
    maybe (Left (HealthcareServiceNotFound serviceId)) Right
      <$> decoded (P.fetchHealthcareService conn serviceId)

fetchHealthcareServices :: ConnectionPool -> IO [HealthcareService]
fetchHealthcareServices pool = withResource pool (decoded . P.fetchHealthcareServices)

-- Slots are deleted on consumption: Nothing means no longer available.
fetchAvailableSlot :: ConnectionPool -> SlotId -> IO (Maybe AvailableSlot)
fetchAvailableSlot pool slotId =
  withResource pool $ \conn -> decoded (P.fetchAvailableSlot conn slotId)

fetchIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> IO (Either IntakeRequestNotFound IntakeRequest)
fetchIntakeRequest pool requestId =
  withResource pool $ \conn ->
    maybe (Left (IntakeRequestNotFound requestId)) Right
      <$> decoded (P.fetchIntakeRequest conn requestId)

fetchSubmittedIntakeRequests :: ConnectionPool -> IO [SubmittedIntakeRequest]
fetchSubmittedIntakeRequests pool = withResource pool (decoded . P.fetchSubmittedIntakeRequests)

-- In waitlist order: the order shown is the order matched.
fetchAcceptedIntakeRequests :: ConnectionPool -> IO [TriagedIntakeRequest]
fetchAcceptedIntakeRequests pool =
  withResource pool (fmap sortByPriority . decoded . P.fetchAcceptedIntakeRequests)

fetchAppointedIntakeRequests :: ConnectionPool -> IO [AppointedIntakeRequest]
fetchAppointedIntakeRequests pool = withResource pool (decoded . P.fetchAppointedIntakeRequests)

-- Terminal cases, over [from, to).

fetchRejectedIntakeRequestsByRejectedAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [RejectedIntakeRequest]
fetchRejectedIntakeRequestsByRejectedAt pool from to =
  withResource pool $ \conn -> decoded (P.fetchRejectedIntakeRequestsByRejectedAt conn from to)

fetchWithdrawnIntakeRequestsByWithdrawnAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [WithdrawnIntakeRequest]
fetchWithdrawnIntakeRequestsByWithdrawnAt pool from to =
  withResource pool $ \conn -> decoded (P.fetchWithdrawnIntakeRequestsByWithdrawnAt conn from to)

fetchStaleIntakeRequestsByStaleAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [StaleIntakeRequest]
fetchStaleIntakeRequestsByStaleAt pool from to =
  withResource pool $ \conn -> decoded (P.fetchStaleIntakeRequestsByStaleAt conn from to)

fetchClosedIntakeRequestsByStart
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [ClosedIntakeRequest]
fetchClosedIntakeRequestsByStart pool from to =
  withResource pool $ \conn -> decoded (P.fetchClosedIntakeRequestsByStart conn from to)

-- The doctor calendar's elements overlapping [from, to), sorted by start.
fetchDoctorCalendarEntriesOverlapping
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [DoctorCalendarEntry]
fetchDoctorCalendarEntriesOverlapping pool from to =
  withResource pool $ \conn -> decoded (P.fetchDoctorCalendarEntriesOverlapping conn from to)
