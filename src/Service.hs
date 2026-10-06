{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- Derived from src/Domain.hs and src/Persistence.hs (triage-service-codegen).
module Service
  ( -- ── Facts (errors) ───────────────────────────────────────────────────
    DoctorNotFound (..)
  , PatientNotFound (..)
  , HealthcareServiceNotFound (..)
  , IntakeRequestNotFound (..)
  , IntakeRequestInWrongState (..)
  , IntakeRequestDoesNotMatchSlot (..)
  , AcceptSubmittedIntakeRequestError (..)
  , MatchAcceptedIntakeRequestToSlotError (..)
  , MarkAcceptedIntakeRequestStaleError (..)
  , CloseAppointedIntakeRequestError (..)
  , CreateAvailableSlotError (..)

    -- ── Outcomes ─────────────────────────────────────────────────────────
  , TransitionOutcome (..)
  , MatchIntakeRequestToSlotOutcome (..)
  , MatchByPriorityOutcome (..)
  , AddAvailableSlotOutcome (..)

    -- ── Creation ─────────────────────────────────────────────────────────
  , createDoctor
  , createPatient
  , createHealthcareService
  , submitIntakeRequest
  , createAvailableSlot

    -- ── Transitions ──────────────────────────────────────────────────────
  , acceptSubmittedIntakeRequest
  , rejectSubmittedIntakeRequest
  , matchAcceptedIntakeRequestToSlot
  , withdrawIntakeRequest
  , markAcceptedIntakeRequestStale
  , closeAppointedIntakeRequest

    -- ── Domain functions over stored values ──────────────────────────────
  , matchAvailableSlotByPriority

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
  , fetchDoctorCalendarOverlapping
  ) where

import Control.Exception          (Exception, throwIO)
import Data.Pool                  (withResource)
import Data.Text                  (Text)
import Data.Time                  (UTCTime, addUTCTime)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection)

import Domain
import Persistence (ConnectionPool)
import qualified Persistence

-- ═══════════════════════════════════════════════════════════════════════════
-- FACTS — errors: true of the caller's request whatever runs concurrently
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorNotFound = DoctorNotFound DoctorId
  deriving (Show, Eq)

newtype PatientNotFound = PatientNotFound PatientId
  deriving (Show, Eq)

newtype HealthcareServiceNotFound = HealthcareServiceNotFound HealthcareServiceId
  deriving (Show, Eq)

newtype IntakeRequestNotFound = IntakeRequestNotFound IntakeRequestId
  deriving (Show, Eq)

-- Raised (not returned) only when a request vanishes between a write's lost
-- race and its re-read; intake requests are never deleted.
instance Exception IntakeRequestNotFound

-- The request is in a case its use case's source case can never lead to.
newtype IntakeRequestInWrongState = IntakeRequestInWrongState IntakeRequest
  deriving (Show, Eq)

-- matchIntakeRequestToSlot declined the pair.
data IntakeRequestDoesNotMatchSlot = IntakeRequestDoesNotMatchSlot
  deriving (Show, Eq)

data AcceptSubmittedIntakeRequestError
  = AcceptSubmittedIntakeRequestIntakeRequestNotFound IntakeRequestNotFound
  | AcceptSubmittedIntakeRequestHealthcareServiceNotFound HealthcareServiceNotFound
  | AcceptSubmittedIntakeRequestDoctorNotFound DoctorNotFound
  deriving (Show, Eq)

data MatchAcceptedIntakeRequestToSlotError
  = MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound IntakeRequestNotFound
  | MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState IntakeRequestInWrongState
  | MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot IntakeRequestDoesNotMatchSlot
  deriving (Show, Eq)

data MarkAcceptedIntakeRequestStaleError
  = MarkAcceptedIntakeRequestStaleIntakeRequestNotFound IntakeRequestNotFound
  | MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState IntakeRequestInWrongState
  deriving (Show, Eq)

data CloseAppointedIntakeRequestError
  = CloseAppointedIntakeRequestIntakeRequestNotFound IntakeRequestNotFound
  | CloseAppointedIntakeRequestIntakeRequestInWrongState IntakeRequestInWrongState
  deriving (Show, Eq)

data CreateAvailableSlotError
  = CreateAvailableSlotDoctorNotFound DoctorNotFound
  | CreateAvailableSlotHealthcareServiceNotFound HealthcareServiceNotFound
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- OUTCOMES — reality moved between two valid operations
-- ═══════════════════════════════════════════════════════════════════════════

-- A transition with a single guard.
data TransitionOutcome a
  = Transitioned a
  | MovedOn IntakeRequest
  deriving (Show, Eq)

-- Persistence.AppointedClaimOutcome, for the caller.
data MatchIntakeRequestToSlotOutcome
  = IntakeRequestMatchedToSlot AppointedIntakeRequest
  | AvailableSlotConsumed SlotId
  | IntakeRequestMovedOn IntakeRequest
  deriving (Show, Eq)

data MatchByPriorityOutcome
  = NoIntakeRequestMatched
  | MatchIntakeRequestToSlotOutcome MatchIntakeRequestToSlotOutcome
  deriving (Show, Eq)

-- addAvailableSlot's decline and doctor_calendar's EXCLUDE are one fact.
data AddAvailableSlotOutcome
  = AvailableSlotAdded AvailableSlot
  | AvailableSlotOverlapsDoctorCalendar
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

-- Stored data violating the spec is not the caller's fault: raise it.
decoded :: IO (Either Persistence.DecodeError a) -> IO a
decoded action = action >>= either throwIO pure

-- After a write lost its race: the request as it is now.
reread :: Connection -> IntakeRequestId -> IO IntakeRequest
reread conn requestId =
  decoded (Persistence.fetchIntakeRequest conn requestId)
    >>= maybe (throwIO (IntakeRequestNotFound requestId)) pure

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATION
-- ═══════════════════════════════════════════════════════════════════════════

createDoctor :: ConnectionPool -> Text -> IO Doctor
createDoctor pool doctorName = withResource pool $ \conn -> do
  uuid <- nextRandom
  let doctor = Doctor { id = DoctorId uuid, name = doctorName }
  Persistence.insertDoctor conn doctor
  pure doctor

createPatient :: ConnectionPool -> Text -> IO Patient
createPatient pool patientName = withResource pool $ \conn -> do
  uuid <- nextRandom
  let patient = Patient { id = PatientId uuid, name = patientName }
  Persistence.insertPatient conn patient
  pure patient

createHealthcareService :: ConnectionPool -> Text -> Duration -> IO HealthcareService
createHealthcareService pool serviceName serviceDuration = withResource pool $ \conn -> do
  uuid <- nextRandom
  let service = HealthcareService
        { id = HealthcareServiceId uuid, name = serviceName, duration = serviceDuration }
  Persistence.insertHealthcareService conn service
  pure service

-- The entry case of IntakeRequest.
submitIntakeRequest
  :: ConnectionPool -> PatientId -> Text -> UTCTime
  -> IO (Either PatientNotFound SubmittedIntakeRequest)
submitIntakeRequest pool patient requestNarrative requestCreatedAt = withResource pool $ \conn ->
  Persistence.fetchPatient conn patient >>= \case
    Nothing -> pure (Left (PatientNotFound patient))
    Just _  -> do
      uuid <- nextRandom
      let request = SubmittedIntakeRequest
            { id = IntakeRequestId uuid
            , patientId = patient
            , narrative = requestNarrative
            , createdAt = requestCreatedAt
            }
      Persistence.insertSubmittedIntakeRequest conn request
      pure (Right request)

-- Grows the sealed DoctorCalendar, read over the new slot's interval;
-- addAvailableSlot decides which of its entries matter. Gap: another slot or
-- appointment for the doctor can be stored between the calendar read and the
-- insert; the EXCLUDE on doctor_calendar catches it, as the same outcome.
createAvailableSlot
  :: ConnectionPool -> DoctorId -> HealthcareServiceId -> UTCTime
  -> IO (Either CreateAvailableSlotError AddAvailableSlotOutcome)
createAvailableSlot pool doctor serviceId slotStart = withResource pool $ \conn -> do
  doctorFound  <- Persistence.fetchDoctor conn doctor
  serviceFound <- decoded (Persistence.fetchHealthcareService conn serviceId)
  case (doctorFound, serviceFound) of
    (Nothing, _) -> pure (Left (CreateAvailableSlotDoctorNotFound (DoctorNotFound doctor)))
    (_, Nothing) ->
      pure (Left (CreateAvailableSlotHealthcareServiceNotFound (HealthcareServiceNotFound serviceId)))
    (Just _, Just service) -> do
      let slotEnd = addUTCTime (durationToNominalDiffTime service.duration) slotStart
      calendar <- decoded (Persistence.fetchDoctorCalendarOverlapping conn slotStart slotEnd)
      uuid <- nextRandom
      case addAvailableSlot calendar (SlotId uuid) doctor service slotStart of
        Nothing -> pure (Right AvailableSlotOverlapsDoctorCalendar)
        Just (slot, _) ->
          Persistence.insertAvailableSlot conn slot >>= \case
            Persistence.AvailableSlotInserted -> pure (Right (AvailableSlotAdded slot))
            Persistence.AvailableSlotOverlapsDoctorCalendar -> pure (Right AvailableSlotOverlapsDoctorCalendar)

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSITIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Submitted → Accepted. Gap: the request can be rejected, withdrawn or
-- accepted by someone else; the write's state guard catches it.
acceptSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> HealthcareServiceId -> IntakeRequestPriority
  -> DoctorRequirement -> UTCTime
  -> IO (Either AcceptSubmittedIntakeRequestError (TransitionOutcome TriagedIntakeRequest))
acceptSubmittedIntakeRequest pool requestId serviceId tier requirement acceptedAt =
  withResource pool $ \conn -> do
    requestFound <- decoded (Persistence.fetchIntakeRequest conn requestId)
    serviceFound <- decoded (Persistence.fetchHealthcareService conn serviceId)
    doctorMissing <- case requirement of
      AnyDoctor             -> pure Nothing
      SpecificDoctor doctor -> maybe (Just doctor) (const Nothing) <$> Persistence.fetchDoctor conn doctor
    case (requestFound, serviceFound, doctorMissing) of
      (Nothing, _, _) ->
        pure (Left (AcceptSubmittedIntakeRequestIntakeRequestNotFound (IntakeRequestNotFound requestId)))
      (_, Nothing, _) ->
        pure (Left (AcceptSubmittedIntakeRequestHealthcareServiceNotFound (HealthcareServiceNotFound serviceId)))
      (_, _, Just doctor) ->
        pure (Left (AcceptSubmittedIntakeRequestDoctorNotFound (DoctorNotFound doctor)))
      (Just current, Just _, Nothing) -> Right <$> case current of
        Submitted request -> do
          let accepted = acceptIntakeRequest request serviceId tier requirement acceptedAt
          Persistence.persistTriagedIntakeRequest conn accepted >>= \case
            Persistence.Claimed        -> pure (Transitioned accepted)
            Persistence.AlreadyClaimed -> MovedOn <$> reread conn requestId
        Rejected _  -> pure (MovedOn current)
        Accepted _  -> pure (MovedOn current)
        Appointed _ -> pure (MovedOn current)
        Withdrawn _ -> pure (MovedOn current)
        Stale _     -> pure (MovedOn current)
        Closed _    -> pure (MovedOn current)

-- Submitted → Rejected. Gap: as for accepting.
rejectSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Text
  -> IO (Either IntakeRequestNotFound (TransitionOutcome RejectedIntakeRequest))
rejectSubmittedIntakeRequest pool requestId at reason = withResource pool $ \conn ->
  decoded (Persistence.fetchIntakeRequest conn requestId) >>= \case
    Nothing -> pure (Left (IntakeRequestNotFound requestId))
    Just current -> Right <$> case current of
      Submitted request -> do
        let rejected = RejectedIntakeRequest
              { submitted = request, rejectedAt = at, rejectionReason = reason }
        Persistence.persistRejectedIntakeRequest conn rejected >>= \case
          Persistence.Claimed        -> pure (Transitioned rejected)
          Persistence.AlreadyClaimed -> MovedOn <$> reread conn requestId
      Rejected _  -> pure (MovedOn current)
      Accepted _  -> pure (MovedOn current)
      Appointed _ -> pure (MovedOn current)
      Withdrawn _ -> pure (MovedOn current)
      Stale _     -> pure (MovedOn current)
      Closed _    -> pure (MovedOn current)

-- Accepted → Appointed, consuming the slot. Gap: the slot can be matched to
-- another request, and the request can be matched, withdrawn or marked stale;
-- the delete's affected rows and the update's state guard catch each, in one
-- transaction.
matchAcceptedIntakeRequestToSlot
  :: ConnectionPool -> IntakeRequestId -> SlotId
  -> IO (Either MatchAcceptedIntakeRequestToSlotError MatchIntakeRequestToSlotOutcome)
matchAcceptedIntakeRequestToSlot pool requestId slotId = withResource pool $ \conn ->
  decoded (Persistence.fetchIntakeRequest conn requestId) >>= \case
    Nothing ->
      pure (Left (MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound (IntakeRequestNotFound requestId)))
    Just current -> do
     let wrongState = pure (Left (MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState
           (IntakeRequestInWrongState current)))
         movedOn = pure (Right (IntakeRequestMovedOn current))
     case current of
      Accepted request ->
        decoded (Persistence.fetchAvailableSlot conn slotId) >>= \case
          Nothing -> pure (Right (AvailableSlotConsumed slotId))
          Just slot -> case matchIntakeRequestToSlot slot request of
            Nothing ->
              pure (Left (MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot
                IntakeRequestDoesNotMatchSlot))
            Just matched -> Right <$> persistMatch conn slot matched
      Submitted _ -> wrongState
      Rejected _  -> wrongState
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- The matching write, shared by both matching use cases.
persistMatch
  :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO MatchIntakeRequestToSlotOutcome
persistMatch conn slot matched =
  Persistence.persistAppointedIntakeRequest conn slot matched >>= \case
    Persistence.AppointedClaimed -> pure (IntakeRequestMatchedToSlot matched)
    Persistence.AvailableSlotAlreadyClaimed   -> pure (AvailableSlotConsumed slot.id)
    Persistence.IntakeRequestAlreadyClaimed   ->
      IntakeRequestMovedOn <$> reread conn matched.triaged.submitted.id

-- Submitted → Withdrawn or Accepted → Withdrawn. Gap: the request can move on
-- (including Submitted → Accepted, from which withdrawing continues).
withdrawIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Maybe Text
  -> IO (Either IntakeRequestNotFound (TransitionOutcome WithdrawnIntakeRequest))
withdrawIntakeRequest pool requestId at note = withResource pool $ \conn ->
  decoded (Persistence.fetchIntakeRequest conn requestId) >>= \case
    Nothing      -> pure (Left (IntakeRequestNotFound requestId))
    Just current -> Right <$> withdrawFrom conn current
  where
    withdrawFrom conn current = case current of
      Submitted request -> withdraw conn (FromSubmitted request)
      Accepted request  -> withdraw conn (FromAccepted request)
      Rejected _        -> pure (MovedOn current)
      Appointed _       -> pure (MovedOn current)
      Withdrawn _       -> pure (MovedOn current)
      Stale _           -> pure (MovedOn current)
      Closed _          -> pure (MovedOn current)
    withdraw conn from = do
      let withdrawn = WithdrawnIntakeRequest
            { withdrawnFrom = from, withdrawnAt = at, withdrawalNote = note }
      Persistence.persistWithdrawnIntakeRequest conn withdrawn >>= \case
        Persistence.Claimed        -> pure (Transitioned withdrawn)
        Persistence.AlreadyClaimed -> reread conn requestId >>= withdrawFrom conn

-- Accepted → Stale. Gap: the request can be matched, withdrawn or marked
-- stale by someone else.
markAcceptedIntakeRequestStale
  :: ConnectionPool -> IntakeRequestId -> UTCTime
  -> IO (Either MarkAcceptedIntakeRequestStaleError (TransitionOutcome StaleIntakeRequest))
markAcceptedIntakeRequestStale pool requestId at = withResource pool $ \conn ->
  decoded (Persistence.fetchIntakeRequest conn requestId) >>= \case
    Nothing ->
      pure (Left (MarkAcceptedIntakeRequestStaleIntakeRequestNotFound (IntakeRequestNotFound requestId)))
    Just current -> do
     let wrongState = pure (Left (MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState
           (IntakeRequestInWrongState current)))
         movedOn = pure (Right (MovedOn current))
     case current of
      Accepted request -> do
        let stale = StaleIntakeRequest { triaged = request, staleAt = at }
        Persistence.persistStaleIntakeRequest conn stale >>= \case
          Persistence.Claimed        -> pure (Right (Transitioned stale))
          Persistence.AlreadyClaimed -> Right . MovedOn <$> reread conn requestId
      Submitted _ -> wrongState
      Rejected _  -> wrongState
      Appointed _ -> movedOn
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState
        FromAccepted _  -> movedOn
      Stale _     -> movedOn
      Closed _    -> movedOn

-- Appointed → Closed. Gap: the appointment can be closed by someone else.
closeAppointedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> CloseReason
  -> IO (Either CloseAppointedIntakeRequestError (TransitionOutcome ClosedIntakeRequest))
closeAppointedIntakeRequest pool requestId reason = withResource pool $ \conn ->
  decoded (Persistence.fetchIntakeRequest conn requestId) >>= \case
    Nothing ->
      pure (Left (CloseAppointedIntakeRequestIntakeRequestNotFound (IntakeRequestNotFound requestId)))
    Just current -> do
     let wrongState = pure (Left (CloseAppointedIntakeRequestIntakeRequestInWrongState
           (IntakeRequestInWrongState current)))
     case current of
      Appointed request -> do
        let closed = ClosedIntakeRequest { appointed = request, closeReason = reason }
        Persistence.persistClosedIntakeRequest conn closed >>= \case
          Persistence.Claimed        -> pure (Right (Transitioned closed))
          Persistence.AlreadyClaimed -> Right . MovedOn <$> reread conn requestId
      Submitted _ -> wrongState
      Rejected _  -> wrongState
      Accepted _  -> wrongState
      Withdrawn _ -> wrongState
      Stale _     -> wrongState
      Closed _    -> pure (Right (MovedOn current))

-- ═══════════════════════════════════════════════════════════════════════════
-- DOMAIN FUNCTIONS OVER STORED VALUES
-- ═══════════════════════════════════════════════════════════════════════════

-- matchByPriority over every Accepted request. Gap: the slot can be consumed
-- and the chosen request can move on (both caught by the matching write);
-- a request accepted after the read is served by the next decision.
matchAvailableSlotByPriority :: ConnectionPool -> SlotId -> IO MatchByPriorityOutcome
matchAvailableSlotByPriority pool slotId = withResource pool $ \conn ->
  decoded (Persistence.fetchAvailableSlot conn slotId) >>= \case
    Nothing   -> pure (MatchIntakeRequestToSlotOutcome (AvailableSlotConsumed slotId))
    Just slot -> do
      candidates <- decoded (Persistence.fetchAcceptedIntakeRequests conn)
      case matchByPriority slot candidates of
        Nothing        -> pure NoIntakeRequestMatched
        Just matched   -> MatchIntakeRequestToSlotOutcome <$> persistMatch conn slot matched

-- ═══════════════════════════════════════════════════════════════════════════
-- READS
-- ═══════════════════════════════════════════════════════════════════════════

fetchDoctor :: ConnectionPool -> DoctorId -> IO (Either DoctorNotFound Doctor)
fetchDoctor pool doctor = withResource pool $ \conn ->
  maybe (Left (DoctorNotFound doctor)) Right <$> Persistence.fetchDoctor conn doctor

fetchDoctors :: ConnectionPool -> IO [Doctor]
fetchDoctors pool = withResource pool Persistence.fetchDoctors

fetchPatient :: ConnectionPool -> PatientId -> IO (Either PatientNotFound Patient)
fetchPatient pool patient = withResource pool $ \conn ->
  maybe (Left (PatientNotFound patient)) Right <$> Persistence.fetchPatient conn patient

fetchPatients :: ConnectionPool -> IO [Patient]
fetchPatients pool = withResource pool Persistence.fetchPatients

fetchHealthcareService
  :: ConnectionPool -> HealthcareServiceId -> IO (Either HealthcareServiceNotFound HealthcareService)
fetchHealthcareService pool serviceId = withResource pool $ \conn ->
  maybe (Left (HealthcareServiceNotFound serviceId)) Right
    <$> decoded (Persistence.fetchHealthcareService conn serviceId)

fetchHealthcareServices :: ConnectionPool -> IO [HealthcareService]
fetchHealthcareServices pool = withResource pool (decoded . Persistence.fetchHealthcareServices)

-- Deleted on consumption: Nothing means no longer available.
fetchAvailableSlot :: ConnectionPool -> SlotId -> IO (Maybe AvailableSlot)
fetchAvailableSlot pool slotId = withResource pool $ \conn ->
  decoded (Persistence.fetchAvailableSlot conn slotId)

fetchIntakeRequest :: ConnectionPool -> IntakeRequestId -> IO (Either IntakeRequestNotFound IntakeRequest)
fetchIntakeRequest pool requestId = withResource pool $ \conn ->
  maybe (Left (IntakeRequestNotFound requestId)) Right
    <$> decoded (Persistence.fetchIntakeRequest conn requestId)

fetchSubmittedIntakeRequests :: ConnectionPool -> IO [SubmittedIntakeRequest]
fetchSubmittedIntakeRequests pool = withResource pool (decoded . Persistence.fetchSubmittedIntakeRequests)

-- In Domain's priority order (sortByPriority).
fetchAcceptedIntakeRequests :: ConnectionPool -> IO [TriagedIntakeRequest]
fetchAcceptedIntakeRequests pool =
  sortByPriority <$> withResource pool (decoded . Persistence.fetchAcceptedIntakeRequests)

fetchAppointedIntakeRequests :: ConnectionPool -> IO [AppointedIntakeRequest]
fetchAppointedIntakeRequests pool = withResource pool (decoded . Persistence.fetchAppointedIntakeRequests)

fetchRejectedIntakeRequestsByRejectedAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [RejectedIntakeRequest]
fetchRejectedIntakeRequestsByRejectedAt pool from to = withResource pool $ \conn ->
  decoded (Persistence.fetchRejectedIntakeRequestsByRejectedAt conn from to)

fetchWithdrawnIntakeRequestsByWithdrawnAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [WithdrawnIntakeRequest]
fetchWithdrawnIntakeRequestsByWithdrawnAt pool from to = withResource pool $ \conn ->
  decoded (Persistence.fetchWithdrawnIntakeRequestsByWithdrawnAt conn from to)

fetchStaleIntakeRequestsByStaleAt
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [StaleIntakeRequest]
fetchStaleIntakeRequestsByStaleAt pool from to = withResource pool $ \conn ->
  decoded (Persistence.fetchStaleIntakeRequestsByStaleAt conn from to)

fetchClosedIntakeRequestsByStart
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [ClosedIntakeRequest]
fetchClosedIntakeRequestsByStart pool from to = withResource pool $ \conn ->
  decoded (Persistence.fetchClosedIntakeRequestsByStart conn from to)

fetchDoctorCalendarOverlapping
  :: ConnectionPool -> UTCTime -> UTCTime -> IO DoctorCalendar
fetchDoctorCalendarOverlapping pool from to = withResource pool $ \conn ->
  decoded (Persistence.fetchDoctorCalendarOverlapping conn from to)
