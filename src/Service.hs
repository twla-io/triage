{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- Derived from src/Domain.hs and src/Persistence.hs by the
-- triage-service-codegen skill. One public function per use case; each
-- takes the pool and uses one connection for every Persistence call.
module Service
  ( -- ── Answers ──────────────────────────────────────────────────────────
    ServiceError (..)
  , TransitionOutcome (..)
  , MatchOutcome (..)
  , PriorityMatchOutcome (..)
  , SlotCreationOutcome (..)

    -- ── Create an entity ────────────────────────────────────────────────
  , createDoctor
  , createPatient
  , createHealthcareService
  , submitIntakeRequest

    -- ── Transitions ─────────────────────────────────────────────────────
  , acceptSubmittedIntakeRequest
  , rejectSubmittedIntakeRequest
  , matchAcceptedIntakeRequestToSlot
  , withdrawIntakeRequest
  , markAcceptedIntakeRequestStale
  , closeAppointedIntakeRequest

    -- ── Domain function over stored values ──────────────────────────────
  , matchAvailableSlotByPriority

    -- ── Grow the sealed collection ──────────────────────────────────────
  , createAvailableSlot

    -- ── Reads ───────────────────────────────────────────────────────────
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

import Control.Monad.Trans.Class  (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE, withExceptT)
import Data.Pool                  (withResource)
import Data.Text                  (Text)
import Data.Time                  (UTCTime)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection)

import Domain
import Persistence (ConnectionPool)

import qualified Persistence

-- ═══════════════════════════════════════════════════════════════════════════
-- ANSWERS
-- ═══════════════════════════════════════════════════════════════════════════

-- The caller's mistake or a real failure: facts no concurrent operation
-- can change.
data ServiceError
  = DecodeFailed                  Persistence.DecodeError
  | DoctorNotFound                DoctorId
  | PatientNotFound               PatientId
  | HealthcareServiceNotFound     HealthcareServiceId
  | IntakeRequestNotFound         IntakeRequestId
  | IntakeRequestInWrongState     IntakeRequest
    -- matchIntakeRequestToSlot declined the slot and request the caller chose.
  | SlotDoesNotMatchIntakeRequest
  deriving (Show, Eq)

-- A transition with a single guard.
data TransitionOutcome a
  = Transitioned a
  | MovedOn      IntakeRequest
  deriving (Show, Eq)

-- Matching's write (Persistence.MatchClaimOutcome), one-to-one.
data MatchOutcome
  = Matched               AppointedIntakeRequest  -- MatchClaimed
  | AvailableSlotConsumed                         -- SlotAlreadyClaimed
  | IntakeRequestMovedOn  IntakeRequest           -- IntakeRequestAlreadyClaimed
  deriving (Show, Eq)

-- matchByPriority's decline, or the outcome of the match it persists.
data PriorityMatchOutcome
  = NoMatchingIntakeRequest
  | MatchAttempted MatchOutcome
  deriving (Show, Eq)

-- A new slot (Persistence.SlotInsertOutcome, one-to-one); addAvailableSlot's
-- decline is the same fact as the constraint's.
data SlotCreationOutcome
  = SlotCreated                AvailableSlot
  | SlotOverlapsDoctorCalendar
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

type Step a = ExceptT ServiceError IO a

run :: ConnectionPool -> (Connection -> Step a) -> IO (Either ServiceError a)
run pool body = withResource pool (runExceptT . body)

decoded :: IO (Either Persistence.DecodeError a) -> Step a
decoded = withExceptT DecodeFailed . ExceptT

found :: ServiceError -> Maybe a -> Step a
found missing = maybe (throwE missing) pure

requireDoctor :: Connection -> DoctorId -> Step Doctor
requireDoctor conn doctorId =
  lift (Persistence.fetchDoctor conn doctorId) >>= found (DoctorNotFound doctorId)

requirePatient :: Connection -> PatientId -> Step Patient
requirePatient conn patientId =
  lift (Persistence.fetchPatient conn patientId) >>= found (PatientNotFound patientId)

requireHealthcareService :: Connection -> HealthcareServiceId -> Step HealthcareService
requireHealthcareService conn serviceId =
  decoded (Persistence.fetchHealthcareService conn serviceId)
    >>= found (HealthcareServiceNotFound serviceId)

requireDoctorRequirement :: Connection -> DoctorRequirement -> Step ()
requireDoctorRequirement _    AnyDoctor               = pure ()
requireDoctorRequirement conn (SpecificDoctor doctorId) = () <$ requireDoctor conn doctorId

requireIntakeRequest :: Connection -> IntakeRequestId -> Step IntakeRequest
requireIntakeRequest conn requestId =
  decoded (Persistence.fetchIntakeRequest conn requestId)
    >>= found (IntakeRequestNotFound requestId)

-- A single-guard write: on a lost race, read once more and report the case
-- the request is in now. Never retried.
guarded :: Connection -> IntakeRequestId -> a -> Persistence.ClaimOutcome -> Step (TransitionOutcome a)
guarded _    _         next Persistence.Claimed        = pure (Transitioned next)
guarded conn requestId _    Persistence.AlreadyClaimed = MovedOn <$> requireIntakeRequest conn requestId

-- Persisting a match, shared by both matching use cases.
persistMatch :: Connection -> AvailableSlot -> AppointedIntakeRequest -> Step MatchOutcome
persistMatch conn slot appointed = do
  outcome <- lift (Persistence.persistAppointedIntakeRequest conn slot appointed)
  case outcome of
    Persistence.MatchClaimed                -> pure (Matched appointed)
    Persistence.SlotAlreadyClaimed          -> pure AvailableSlotConsumed
    Persistence.IntakeRequestAlreadyClaimed ->
      IntakeRequestMovedOn <$> requireIntakeRequest conn appointed.triaged.submitted.id

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATE AN ENTITY
-- ═══════════════════════════════════════════════════════════════════════════

createDoctor :: ConnectionPool -> Text -> IO Doctor
createDoctor pool name = withResource pool $ \conn -> do
  doctorId <- DoctorId <$> nextRandom
  let doctor = Doctor { id = doctorId, name }
  Persistence.insertDoctor conn doctor
  pure doctor

createPatient :: ConnectionPool -> Text -> IO Patient
createPatient pool name = withResource pool $ \conn -> do
  patientId <- PatientId <$> nextRandom
  let patient = Patient { id = patientId, name }
  Persistence.insertPatient conn patient
  pure patient

createHealthcareService :: ConnectionPool -> Text -> Duration -> IO HealthcareService
createHealthcareService pool name duration = withResource pool $ \conn -> do
  serviceId <- HealthcareServiceId <$> nextRandom
  let service = HealthcareService { id = serviceId, name, duration }
  Persistence.insertHealthcareService conn service
  pure service

-- The entry case of IntakeRequest.
submitIntakeRequest
  :: ConnectionPool -> PatientId -> Text -> UTCTime
  -> IO (Either ServiceError SubmittedIntakeRequest)
submitIntakeRequest pool patientId narrative createdAt = run pool $ \conn -> do
  _ <- requirePatient conn patientId
  requestId <- lift (IntakeRequestId <$> nextRandom)
  let submitted = SubmittedIntakeRequest { id = requestId, patientId, narrative, createdAt }
  lift (Persistence.insertSubmittedIntakeRequest conn submitted)
  pure submitted

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSITIONS
-- Each split is over the transition graph: a case reachable from the
-- expected one is MovedOn, any other is IntakeRequestInWrongState.
-- ═══════════════════════════════════════════════════════════════════════════

-- Submitted → Accepted (acceptIntakeRequest). Gap: the request can leave
-- Submitted (accepted, rejected, withdrawn) — the write's guard catches it.
acceptSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> HealthcareServiceId -> IntakeRequestPriority
  -> DoctorRequirement -> UTCTime
  -> IO (Either ServiceError (TransitionOutcome TriagedIntakeRequest))
acceptSubmittedIntakeRequest pool requestId serviceId priority requirement triagedAt =
  run pool $ \conn -> do
    _ <- requireHealthcareService conn serviceId
    requireDoctorRequirement conn requirement
    current <- requireIntakeRequest conn requestId
    case current of
      Submitted submitted -> do
        let triaged = acceptIntakeRequest submitted serviceId priority requirement triagedAt
        lift (Persistence.persistTriagedIntakeRequest conn triaged)
          >>= guarded conn requestId triaged
      Rejected  _ -> pure (MovedOn current)
      Accepted  _ -> pure (MovedOn current)
      Appointed _ -> pure (MovedOn current)
      Withdrawn _ -> pure (MovedOn current)
      Stale     _ -> pure (MovedOn current)
      Closed    _ -> pure (MovedOn current)

-- Submitted → Rejected (direct construction). Same gap as accepting.
rejectSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Text
  -> IO (Either ServiceError (TransitionOutcome RejectedIntakeRequest))
rejectSubmittedIntakeRequest pool requestId rejectedAt rejectionReason =
  run pool $ \conn -> do
    current <- requireIntakeRequest conn requestId
    case current of
      Submitted submitted -> do
        let rejected = RejectedIntakeRequest { submitted, rejectedAt, rejectionReason }
        lift (Persistence.persistRejectedIntakeRequest conn rejected)
          >>= guarded conn requestId rejected
      Rejected  _ -> pure (MovedOn current)
      Accepted  _ -> pure (MovedOn current)
      Appointed _ -> pure (MovedOn current)
      Withdrawn _ -> pure (MovedOn current)
      Stale     _ -> pure (MovedOn current)
      Closed    _ -> pure (MovedOn current)

-- Accepted → Appointed (matchIntakeRequestToSlot). Gap: the request can
-- leave Accepted and the slot can be consumed; the write's guards catch both.
matchAcceptedIntakeRequestToSlot
  :: ConnectionPool -> IntakeRequestId -> SlotId -> IO (Either ServiceError MatchOutcome)
matchAcceptedIntakeRequestToSlot pool requestId slotId = run pool $ \conn -> do
  current <- requireIntakeRequest conn requestId
  case current of
    Accepted triaged -> do
      stored <- decoded (Persistence.fetchAvailableSlot conn slotId)
      case stored of
        Nothing   -> pure AvailableSlotConsumed
        Just slot -> case matchIntakeRequestToSlot slot triaged of
          Nothing        -> throwE SlotDoesNotMatchIntakeRequest
          Just appointed -> persistMatch conn slot appointed
    Submitted _ -> throwE (IntakeRequestInWrongState current)
    Rejected  _ -> throwE (IntakeRequestInWrongState current)
    Appointed _ -> pure (IntakeRequestMovedOn current)
    Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
      FromSubmitted _ -> throwE (IntakeRequestInWrongState current)
      FromAccepted  _ -> pure (IntakeRequestMovedOn current)
    Stale     _ -> pure (IntakeRequestMovedOn current)
    Closed    _ -> pure (IntakeRequestMovedOn current)

-- Submitted → Withdrawn or Accepted → Withdrawn: the target records its
-- source. Gap: the request can move on; a Submitted one lost to acceptance
-- is withdrawn from Accepted instead, under that case's guard.
withdrawIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Maybe Text
  -> IO (Either ServiceError (TransitionOutcome WithdrawnIntakeRequest))
withdrawIntakeRequest pool requestId withdrawnAt withdrawalNote = run pool $ \conn -> do
  current <- requireIntakeRequest conn requestId
  case current of
    Submitted submitted -> withdrawFrom conn (FromSubmitted submitted)
    Accepted  triaged   -> withdrawFrom conn (FromAccepted triaged)
    Rejected  _ -> pure (MovedOn current)
    Appointed _ -> pure (MovedOn current)
    Withdrawn _ -> pure (MovedOn current)
    Stale     _ -> pure (MovedOn current)
    Closed    _ -> pure (MovedOn current)
  where
    withdrawFrom conn from = do
      let withdrawn = WithdrawnIntakeRequest { withdrawnFrom = from, withdrawnAt, withdrawalNote }
      outcome <- lift (Persistence.persistWithdrawnIntakeRequest conn withdrawn)
      case outcome of
        Persistence.Claimed        -> pure (Transitioned withdrawn)
        Persistence.AlreadyClaimed -> do
          now <- requireIntakeRequest conn requestId
          case from of
            FromAccepted  _ -> pure (MovedOn now)
            FromSubmitted _ -> case now of
              Accepted  triaged -> withdrawFrom conn (FromAccepted triaged)
              Submitted _ -> pure (MovedOn now)
              Rejected  _ -> pure (MovedOn now)
              Appointed _ -> pure (MovedOn now)
              Withdrawn _ -> pure (MovedOn now)
              Stale     _ -> pure (MovedOn now)
              Closed    _ -> pure (MovedOn now)

-- Accepted → Stale (direct construction). Gap: the request can leave
-- Accepted (matched, withdrawn, marked stale) — the write's guard catches it.
markAcceptedIntakeRequestStale
  :: ConnectionPool -> IntakeRequestId -> UTCTime
  -> IO (Either ServiceError (TransitionOutcome StaleIntakeRequest))
markAcceptedIntakeRequestStale pool requestId staleAt = run pool $ \conn -> do
  current <- requireIntakeRequest conn requestId
  case current of
    Accepted triaged -> do
      let stale = StaleIntakeRequest { triaged, staleAt }
      lift (Persistence.persistStaleIntakeRequest conn stale)
        >>= guarded conn requestId stale
    Submitted _ -> throwE (IntakeRequestInWrongState current)
    Rejected  _ -> throwE (IntakeRequestInWrongState current)
    Appointed _ -> pure (MovedOn current)
    Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
      FromSubmitted _ -> throwE (IntakeRequestInWrongState current)
      FromAccepted  _ -> pure (MovedOn current)
    Stale     _ -> pure (MovedOn current)
    Closed    _ -> pure (MovedOn current)

-- Appointed → Closed (direct construction). Gap: the request can be closed
-- by someone else — the write's guard catches it.
closeAppointedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> CloseReason
  -> IO (Either ServiceError (TransitionOutcome ClosedIntakeRequest))
closeAppointedIntakeRequest pool requestId closeReason = run pool $ \conn -> do
  current <- requireIntakeRequest conn requestId
  case current of
    Appointed appointed -> do
      let closed = ClosedIntakeRequest { appointed, closeReason }
      lift (Persistence.persistClosedIntakeRequest conn closed)
        >>= guarded conn requestId closed
    Submitted _ -> throwE (IntakeRequestInWrongState current)
    Rejected  _ -> throwE (IntakeRequestInWrongState current)
    Accepted  _ -> throwE (IntakeRequestInWrongState current)
    Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
      FromSubmitted _ -> throwE (IntakeRequestInWrongState current)
      FromAccepted  _ -> throwE (IntakeRequestInWrongState current)
    Stale     _ -> throwE (IntakeRequestInWrongState current)
    Closed    _ -> pure (MovedOn current)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOMAIN FUNCTION OVER STORED VALUES
-- ═══════════════════════════════════════════════════════════════════════════

-- matchByPriority over the stored Accepted requests. Gap: the slot can be
-- consumed and the chosen request can leave Accepted (the write's guards
-- catch both); a request accepted after the read is served by the next
-- decision.
matchAvailableSlotByPriority
  :: ConnectionPool -> SlotId -> IO (Either ServiceError PriorityMatchOutcome)
matchAvailableSlotByPriority pool slotId = run pool $ \conn -> do
  stored <- decoded (Persistence.fetchAvailableSlot conn slotId)
  case stored of
    Nothing   -> pure (MatchAttempted AvailableSlotConsumed)
    Just slot -> do
      waitlist <- decoded (Persistence.fetchAcceptedIntakeRequests conn)
      case matchByPriority slot waitlist of
        Nothing        -> pure NoMatchingIntakeRequest
        Just appointed -> MatchAttempted <$> persistMatch conn slot appointed

-- ═══════════════════════════════════════════════════════════════════════════
-- GROW THE SEALED COLLECTION
-- ═══════════════════════════════════════════════════════════════════════════

-- addAvailableSlot against the doctor's stored calendar. Gap: another
-- entry can take the interval; the EXCLUDE constraint catches it.
createAvailableSlot
  :: ConnectionPool -> DoctorId -> HealthcareServiceId -> UTCTime
  -> IO (Either ServiceError SlotCreationOutcome)
createAvailableSlot pool doctorId serviceId start = run pool $ \conn -> do
  _        <- requireDoctor conn doctorId
  service  <- requireHealthcareService conn serviceId
  calendar <- decoded
    (Persistence.fetchDoctorCalendarOverlapping conn doctorId start service.duration)
  slotId   <- lift (SlotId <$> nextRandom)
  case addAvailableSlot calendar slotId doctorId service start of
    Nothing        -> pure SlotOverlapsDoctorCalendar
    Just (slot, _) -> do
      outcome <- lift (Persistence.insertAvailableSlot conn slot)
      pure $ case outcome of
        Persistence.SlotInserted               -> SlotCreated slot
        Persistence.SlotOverlapsDoctorCalendar -> SlotOverlapsDoctorCalendar

-- ═══════════════════════════════════════════════════════════════════════════
-- READS
-- ═══════════════════════════════════════════════════════════════════════════

fetchDoctor :: ConnectionPool -> DoctorId -> IO (Either ServiceError Doctor)
fetchDoctor pool doctorId = run pool $ \conn -> requireDoctor conn doctorId

fetchDoctors :: ConnectionPool -> IO [Doctor]
fetchDoctors pool = withResource pool Persistence.fetchDoctors

fetchPatient :: ConnectionPool -> PatientId -> IO (Either ServiceError Patient)
fetchPatient pool patientId = run pool $ \conn -> requirePatient conn patientId

fetchPatients :: ConnectionPool -> IO [Patient]
fetchPatients pool = withResource pool Persistence.fetchPatients

fetchHealthcareService
  :: ConnectionPool -> HealthcareServiceId -> IO (Either ServiceError HealthcareService)
fetchHealthcareService pool serviceId =
  run pool $ \conn -> requireHealthcareService conn serviceId

fetchHealthcareServices :: ConnectionPool -> IO (Either ServiceError [HealthcareService])
fetchHealthcareServices pool = run pool $ decoded . Persistence.fetchHealthcareServices

-- Deleted on consumption: Nothing is "no longer available".
fetchAvailableSlot :: ConnectionPool -> SlotId -> IO (Either ServiceError (Maybe AvailableSlot))
fetchAvailableSlot pool slotId =
  run pool $ \conn -> decoded (Persistence.fetchAvailableSlot conn slotId)

fetchIntakeRequest :: ConnectionPool -> IntakeRequestId -> IO (Either ServiceError IntakeRequest)
fetchIntakeRequest pool requestId = run pool $ \conn -> requireIntakeRequest conn requestId

fetchSubmittedIntakeRequests
  :: ConnectionPool -> IO (Either ServiceError [SubmittedIntakeRequest])
fetchSubmittedIntakeRequests pool = run pool $ decoded . Persistence.fetchSubmittedIntakeRequests

fetchAcceptedIntakeRequests :: ConnectionPool -> IO (Either ServiceError [TriagedIntakeRequest])
fetchAcceptedIntakeRequests pool =
  run pool $ fmap sortByPriority . decoded . Persistence.fetchAcceptedIntakeRequests

fetchAppointedIntakeRequests
  :: ConnectionPool -> IO (Either ServiceError [AppointedIntakeRequest])
fetchAppointedIntakeRequests pool = run pool $ decoded . Persistence.fetchAppointedIntakeRequests

fetchRejectedIntakeRequestsByRejectedAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO (Either ServiceError [RejectedIntakeRequest])
fetchRejectedIntakeRequestsByRejectedAt pool from to = run pool $ \conn ->
  decoded (Persistence.fetchRejectedIntakeRequestsByRejectedAt conn from to)

fetchWithdrawnIntakeRequestsByWithdrawnAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO (Either ServiceError [WithdrawnIntakeRequest])
fetchWithdrawnIntakeRequestsByWithdrawnAt pool from to = run pool $ \conn ->
  decoded (Persistence.fetchWithdrawnIntakeRequestsByWithdrawnAt conn from to)

fetchStaleIntakeRequestsByStaleAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO (Either ServiceError [StaleIntakeRequest])
fetchStaleIntakeRequestsByStaleAt pool from to = run pool $ \conn ->
  decoded (Persistence.fetchStaleIntakeRequestsByStaleAt conn from to)

fetchClosedIntakeRequestsByStart
  :: ConnectionPool -> UTCTime -> UTCTime -> IO (Either ServiceError [ClosedIntakeRequest])
fetchClosedIntakeRequestsByStart pool from to = run pool $ \conn ->
  decoded (Persistence.fetchClosedIntakeRequestsByStart conn from to)

fetchDoctorCalendarEntriesOverlapping
  :: ConnectionPool -> UTCTime -> UTCTime -> IO (Either ServiceError [DoctorCalendarEntry])
fetchDoctorCalendarEntriesOverlapping pool from to = run pool $ \conn ->
  decoded (Persistence.fetchDoctorCalendarEntriesOverlapping conn from to)
