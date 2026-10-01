{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}

-- Derived from src/Domain.hs and src/Persistence.hs by
-- triage-service-codegen. One public function per use case, each taking a
-- ConnectionPool and using one Connection. Ids are minted here; timestamps
-- and other caller-observed facts are parameters.
module Service
  ( ConnectionPool

    -- * Error facts
  , DoctorNotFound (..)
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

    -- * Outcomes
  , TransitionOutcome (..)
  , MatchIntakeRequestToSlotOutcome (..)
  , MatchByPriorityOutcome (..)
  , AddAvailableSlotOutcome (..)

    -- * Creation
  , createDoctor
  , createPatient
  , createHealthcareService
  , submitIntakeRequest
  , createAvailableSlot

    -- * Transitions
  , acceptSubmittedIntakeRequest
  , rejectSubmittedIntakeRequest
  , matchAcceptedIntakeRequestToSlot
  , withdrawIntakeRequest
  , markAcceptedIntakeRequestStale
  , closeAppointedIntakeRequest

    -- * Domain functions over stored values
  , matchAvailableSlotByPriority

    -- * Reads
  , fetchDoctor
  , fetchPatient
  , fetchHealthcareService
  , fetchIntakeRequest
  , fetchAvailableSlot
  , fetchDoctors
  , fetchPatients
  , fetchHealthcareServices
  , fetchSubmittedIntakeRequests
  , fetchAcceptedIntakeRequests
  , fetchAppointedIntakeRequests
  , fetchRejectedIntakeRequestsByRejectedAt
  , fetchWithdrawnIntakeRequestsByWithdrawnAt
  , fetchStaleIntakeRequestsByStaleAt
  , fetchClosedIntakeRequestsByStart
  , fetchDoctorCalendarEntriesOverlapping
  ) where

import Control.Exception (throwIO)
import Data.Pool         (withResource)
import Data.Text         (Text)
import Data.Time         (UTCTime, addUTCTime)
import Data.UUID.V4      (nextRandom)

import Database.PostgreSQL.Simple (Connection)

import Domain
import Persistence (ConnectionPool)
import qualified Persistence

-- ═══════════════════════════════════════════════════════════════════════════
-- ERROR FACTS — facts about the caller's request no concurrent operation
-- can change.
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorNotFound = DoctorNotFound DoctorId
  deriving (Show, Eq)

newtype PatientNotFound = PatientNotFound PatientId
  deriving (Show, Eq)

newtype HealthcareServiceNotFound = HealthcareServiceNotFound HealthcareServiceId
  deriving (Show, Eq)

newtype IntakeRequestNotFound = IntakeRequestNotFound IntakeRequestId
  deriving (Show, Eq)

-- The request as it is: in a case the caller could never have acted from.
newtype IntakeRequestInWrongState = IntakeRequestInWrongState IntakeRequest
  deriving (Show, Eq)

-- matchIntakeRequestToSlot declined the slot and request the caller chose.
data IntakeRequestDoesNotMatchSlot = IntakeRequestDoesNotMatchSlot
  deriving (Show, Eq)

data AcceptSubmittedIntakeRequestError
  = AcceptSubmittedIntakeRequestIntakeRequestNotFound     IntakeRequestNotFound
  | AcceptSubmittedIntakeRequestHealthcareServiceNotFound HealthcareServiceNotFound
  | AcceptSubmittedIntakeRequestDoctorNotFound            DoctorNotFound
  deriving (Show, Eq)

data MatchAcceptedIntakeRequestToSlotError
  = MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound         IntakeRequestNotFound
  | MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState     IntakeRequestInWrongState
  | MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot IntakeRequestDoesNotMatchSlot
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
-- OUTCOMES — reality moved between two valid operations.
-- ═══════════════════════════════════════════════════════════════════════════

-- A transition with a single guard.
data TransitionOutcome a
  = Transitioned a
  | MovedOn IntakeRequest
  deriving (Show, Eq)

-- Matching (Persistence.AppointedClaimOutcome, one-to-one).
data MatchIntakeRequestToSlotOutcome
  = IntakeRequestMatchedToSlot AppointedIntakeRequest
  | AvailableSlotConsumed SlotId
  | IntakeRequestMovedOn IntakeRequest
  deriving (Show, Eq)

-- matchByPriority over the stored waitlist.
data MatchByPriorityOutcome
  = NoIntakeRequestMatched
  | MatchIntakeRequestToSlotOutcome MatchIntakeRequestToSlotOutcome
  deriving (Show, Eq)

-- Growing DoctorCalendar. addAvailableSlot's decline and the EXCLUDE
-- violation are the same fact.
data AddAvailableSlotOutcome
  = AvailableSlotAdded AvailableSlot
  | AvailableSlotOverlapsDoctorCalendar
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

-- A decode failure is stored data violating the spec: raised, not returned.
decoded :: IO (Either Persistence.DecodeError a) -> IO a
decoded action = action >>= either throwIO pure

-- Re-reads a request after its guarded write lost a race. Requests are
-- never deleted, so it is always found.
reread :: Connection -> IntakeRequestId -> IO IntakeRequest
reread conn requestId = do
  found <- decoded (Persistence.fetchIntakeRequest conn requestId)
  maybe (ioError (userError ("intake request vanished: " <> show requestId))) pure found

-- A guarded single-row transition: Transitioned on success, MovedOn with
-- the request as it is now if the guard lost.
transition
  :: Connection -> IntakeRequestId -> a -> IO Persistence.ClaimOutcome
  -> IO (TransitionOutcome a)
transition conn requestId next write = do
  outcome <- write
  case outcome of
    Persistence.Claimed        -> pure (Transitioned next)
    Persistence.AlreadyClaimed -> MovedOn <$> reread conn requestId

lookupIntakeRequest :: Connection -> IntakeRequestId -> IO (Maybe IntakeRequest)
lookupIntakeRequest conn requestId = decoded (Persistence.fetchIntakeRequest conn requestId)

-- Checks a DoctorRequirement's doctor id exists.
doctorRequirementExists :: Connection -> DoctorRequirement -> IO (Maybe DoctorNotFound)
doctorRequirementExists _    AnyDoctor               = pure Nothing
doctorRequirementExists conn (SpecificDoctor doctorId) =
  maybe (Just (DoctorNotFound doctorId)) (const Nothing)
    <$> Persistence.fetchDoctor conn doctorId

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATION
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
  -> IO (Either PatientNotFound SubmittedIntakeRequest)
submitIntakeRequest pool patientId narrative createdAt = withResource pool $ \conn -> do
  patient <- Persistence.fetchPatient conn patientId
  case patient of
    Nothing -> pure (Left (PatientNotFound patientId))
    Just _  -> do
      requestId <- IntakeRequestId <$> nextRandom
      let submitted = SubmittedIntakeRequest { id = requestId, patientId, narrative, createdAt }
      Persistence.insertSubmittedIntakeRequest conn submitted
      pure (Right submitted)

-- Grows DoctorCalendar. In the gap between the overlap read and the insert,
-- another slot or a match can occupy the time; the EXCLUDE constraint
-- catches it and the answer is the same AvailableSlotOverlapsDoctorCalendar.
createAvailableSlot
  :: ConnectionPool -> DoctorId -> HealthcareServiceId -> UTCTime
  -> IO (Either CreateAvailableSlotError AddAvailableSlotOutcome)
createAvailableSlot pool doctorId serviceId start = withResource pool $ \conn -> do
  doctor  <- Persistence.fetchDoctor conn doctorId
  service <- decoded (Persistence.fetchHealthcareService conn serviceId)
  case (doctor, service) of
    (Nothing, _) -> pure (Left (CreateAvailableSlotDoctorNotFound (DoctorNotFound doctorId)))
    (_, Nothing) ->
      pure (Left (CreateAvailableSlotHealthcareServiceNotFound (HealthcareServiceNotFound serviceId)))
    (Just _, Just healthcareService) -> do
      let end = addUTCTime (durationToNominalDiffTime healthcareService.duration) start
      calendar <- decoded (Persistence.fetchDoctorCalendarOverlapping conn doctorId start end)
      slotId   <- SlotId <$> nextRandom
      case addAvailableSlot calendar slotId doctorId healthcareService start of
        Nothing        -> pure (Right AvailableSlotOverlapsDoctorCalendar)
        Just (slot, _) -> do
          inserted <- Persistence.insertAvailableSlot conn slot
          pure . Right $ case inserted of
            Persistence.AvailableSlotInserted -> AvailableSlotAdded slot
            Persistence.AvailableSlotOverlapsDoctorCalendar -> AvailableSlotOverlapsDoctorCalendar

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSITIONS
-- Lifecycle graph (Domain.hs):
--   Submitted -> Rejected | Accepted | Withdrawn (FromSubmitted)
--   Accepted  -> Appointed | Withdrawn (FromAccepted) | Stale
--   Appointed -> Closed
-- A case found other than the expected one: reachable from it -> MovedOn
-- (outcome); not reachable -> IntakeRequestInWrongState (error).
-- ═══════════════════════════════════════════════════════════════════════════

-- Submitted -> Accepted. In the gap: another accept, a reject or a
-- withdrawal can move the request on; the write's guard answers MovedOn.
acceptSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> HealthcareServiceId -> IntakeRequestPriority
  -> DoctorRequirement -> UTCTime
  -> IO (Either AcceptSubmittedIntakeRequestError (TransitionOutcome TriagedIntakeRequest))
acceptSubmittedIntakeRequest pool requestId serviceId priority doctorRequirement triagedAt =
  withResource pool $ \conn -> do
    found   <- lookupIntakeRequest conn requestId
    service <- decoded (Persistence.fetchHealthcareService conn serviceId)
    missingDoctor <- doctorRequirementExists conn doctorRequirement
    case (found, service, missingDoctor) of
      (Nothing, _, _) ->
        pure (Left (AcceptSubmittedIntakeRequestIntakeRequestNotFound (IntakeRequestNotFound requestId)))
      (_, Nothing, _) ->
        pure (Left (AcceptSubmittedIntakeRequestHealthcareServiceNotFound (HealthcareServiceNotFound serviceId)))
      (_, _, Just notFound) ->
        pure (Left (AcceptSubmittedIntakeRequestDoctorNotFound notFound))
      (Just request, Just _, Nothing) -> Right <$> case request of
        Submitted submitted -> do
          let triaged = acceptIntakeRequest submitted serviceId priority doctorRequirement triagedAt
          transition conn requestId triaged (Persistence.persistTriagedIntakeRequest conn triaged)
        Rejected _  -> pure (MovedOn request)
        Accepted _  -> pure (MovedOn request)
        Appointed _ -> pure (MovedOn request)
        Withdrawn _ -> pure (MovedOn request)
        Stale _     -> pure (MovedOn request)
        Closed _    -> pure (MovedOn request)

-- Submitted -> Rejected. In the gap: an accept, another reject or a
-- withdrawal can move the request on; the write's guard answers MovedOn.
rejectSubmittedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Text
  -> IO (Either IntakeRequestNotFound (TransitionOutcome RejectedIntakeRequest))
rejectSubmittedIntakeRequest pool requestId rejectedAt rejectionReason =
  withResource pool $ \conn -> do
    found <- lookupIntakeRequest conn requestId
    case found of
      Nothing -> pure (Left (IntakeRequestNotFound requestId))
      Just request -> Right <$> case request of
        Submitted submitted -> do
          let rejected = RejectedIntakeRequest { submitted, rejectedAt, rejectionReason }
          transition conn requestId rejected (Persistence.persistRejectedIntakeRequest conn rejected)
        Rejected _  -> pure (MovedOn request)
        Accepted _  -> pure (MovedOn request)
        Appointed _ -> pure (MovedOn request)
        Withdrawn _ -> pure (MovedOn request)
        Stale _     -> pure (MovedOn request)
        Closed _    -> pure (MovedOn request)

-- Accepted -> Appointed, consuming the slot. In the gap: the slot can be
-- matched to another request (AvailableSlotConsumed), and the request can
-- be matched, withdrawn or marked stale (IntakeRequestMovedOn). Both rows
-- are guarded in one transaction.
matchAcceptedIntakeRequestToSlot
  :: ConnectionPool -> IntakeRequestId -> SlotId
  -> IO (Either MatchAcceptedIntakeRequestToSlotError MatchIntakeRequestToSlotOutcome)
matchAcceptedIntakeRequestToSlot pool requestId slotId = withResource pool $ \conn -> do
  found <- lookupIntakeRequest conn requestId
  case found of
    Nothing ->
      pure (Left (MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound (IntakeRequestNotFound requestId)))
    Just request -> case request of
      Accepted triaged -> do
        stored <- decoded (Persistence.fetchAvailableSlot conn slotId)
        case stored of
          Nothing   -> pure (Right (AvailableSlotConsumed slotId))
          Just slot -> case matchIntakeRequestToSlot slot triaged of
            Nothing ->
              pure (Left (MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot
                            IntakeRequestDoesNotMatchSlot))
            Just appointed -> Right <$> persistMatch conn slot appointed
      Submitted _ -> wrongState request
      Rejected _  -> wrongState request
      Appointed _ -> pure (Right (IntakeRequestMovedOn request))
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState request
        FromAccepted _  -> pure (Right (IntakeRequestMovedOn request))
      Stale _     -> pure (Right (IntakeRequestMovedOn request))
      Closed _    -> pure (Right (IntakeRequestMovedOn request))
  where
    wrongState request =
      pure (Left (MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState
                    (IntakeRequestInWrongState request)))

-- Persists a match; Persistence's outcome translated one-to-one.
persistMatch :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO MatchIntakeRequestToSlotOutcome
persistMatch conn slot appointed = do
  outcome <- Persistence.persistAppointedIntakeRequest conn slot appointed
  case outcome of
    Persistence.AppointedClaimed            -> pure (IntakeRequestMatchedToSlot appointed)
    Persistence.AvailableSlotAlreadyClaimed -> pure (AvailableSlotConsumed slot.id)
    Persistence.IntakeRequestAlreadyClaimed ->
      IntakeRequestMovedOn <$> reread conn appointed.triaged.submitted.id

-- Submitted | Accepted -> Withdrawn. In the gap: the request can be
-- accepted (the withdrawal continues once from Accepted), or rejected,
-- matched, marked stale or withdrawn (MovedOn).
withdrawIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> UTCTime -> Maybe Text
  -> IO (Either IntakeRequestNotFound (TransitionOutcome WithdrawnIntakeRequest))
withdrawIntakeRequest pool requestId withdrawnAt withdrawalNote = withResource pool $ \conn -> do
  found <- lookupIntakeRequest conn requestId
  case found of
    Nothing      -> pure (Left (IntakeRequestNotFound requestId))
    Just request -> Right <$> go conn request
  where
    go conn request = case request of
      Submitted submitted -> attempt conn (FromSubmitted submitted)
      Accepted triaged    -> attempt conn (FromAccepted triaged)
      Rejected _          -> pure (MovedOn request)
      Appointed _         -> pure (MovedOn request)
      Withdrawn _         -> pure (MovedOn request)
      Stale _             -> pure (MovedOn request)
      Closed _            -> pure (MovedOn request)

    attempt conn withdrawnFrom = do
      let withdrawn = WithdrawnIntakeRequest { withdrawnFrom, withdrawnAt, withdrawalNote }
      outcome <- Persistence.persistWithdrawnIntakeRequest conn withdrawn
      case outcome of
        Persistence.Claimed        -> pure (Transitioned withdrawn)
        -- Cases only move forward, so this continues at most once.
        Persistence.AlreadyClaimed -> reread conn requestId >>= go conn

-- Accepted -> Stale. In the gap: the request can be matched, withdrawn or
-- marked stale; the write's guard answers MovedOn.
markAcceptedIntakeRequestStale
  :: ConnectionPool -> IntakeRequestId -> UTCTime
  -> IO (Either MarkAcceptedIntakeRequestStaleError (TransitionOutcome StaleIntakeRequest))
markAcceptedIntakeRequestStale pool requestId staleAt = withResource pool $ \conn -> do
  found <- lookupIntakeRequest conn requestId
  case found of
    Nothing ->
      pure (Left (MarkAcceptedIntakeRequestStaleIntakeRequestNotFound (IntakeRequestNotFound requestId)))
    Just request -> case request of
      Accepted triaged -> do
        let stale = StaleIntakeRequest { triaged, staleAt }
        Right <$> transition conn requestId stale (Persistence.persistStaleIntakeRequest conn stale)
      Submitted _ -> wrongState request
      Rejected _  -> wrongState request
      Appointed _ -> pure (Right (MovedOn request))
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState request
        FromAccepted _  -> pure (Right (MovedOn request))
      Stale _     -> pure (Right (MovedOn request))
      Closed _    -> pure (Right (MovedOn request))
  where
    wrongState request =
      pure (Left (MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState
                    (IntakeRequestInWrongState request)))

-- Appointed -> Closed. In the gap: the request can be closed by someone
-- else; the write's guard answers MovedOn.
closeAppointedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> CloseReason
  -> IO (Either CloseAppointedIntakeRequestError (TransitionOutcome ClosedIntakeRequest))
closeAppointedIntakeRequest pool requestId closeReason = withResource pool $ \conn -> do
  found <- lookupIntakeRequest conn requestId
  case found of
    Nothing ->
      pure (Left (CloseAppointedIntakeRequestIntakeRequestNotFound (IntakeRequestNotFound requestId)))
    Just request -> case request of
      Appointed appointed -> do
        let closed = ClosedIntakeRequest { appointed, closeReason }
        Right <$> transition conn requestId closed (Persistence.persistClosedIntakeRequest conn closed)
      Submitted _ -> wrongState request
      Rejected _  -> wrongState request
      Accepted _  -> wrongState request
      Withdrawn withdrawn -> case withdrawn.withdrawnFrom of
        FromSubmitted _ -> wrongState request
        FromAccepted _  -> wrongState request
      Stale _     -> wrongState request
      Closed _    -> pure (Right (MovedOn request))
  where
    wrongState request =
      pure (Left (CloseAppointedIntakeRequestIntakeRequestInWrongState
                    (IntakeRequestInWrongState request)))

-- ═══════════════════════════════════════════════════════════════════════════
-- DOMAIN FUNCTIONS OVER STORED VALUES
-- ═══════════════════════════════════════════════════════════════════════════

-- matchByPriority over the Accepted requests. In the gap: the slot can be
-- matched elsewhere (AvailableSlotConsumed) and the chosen request can move
-- on (IntakeRequestMovedOn). The candidates are a snapshot: a request
-- accepted after the read is served by the next decision.
matchAvailableSlotByPriority :: ConnectionPool -> SlotId -> IO MatchByPriorityOutcome
matchAvailableSlotByPriority pool slotId = withResource pool $ \conn -> do
  stored <- decoded (Persistence.fetchAvailableSlot conn slotId)
  case stored of
    Nothing   -> pure (MatchIntakeRequestToSlotOutcome (AvailableSlotConsumed slotId))
    Just slot -> do
      waiting <- decoded (Persistence.fetchAcceptedIntakeRequests conn)
      case matchByPriority slot waiting of
        Nothing        -> pure NoIntakeRequestMatched
        Just appointed -> MatchIntakeRequestToSlotOutcome <$> persistMatch conn slot appointed

-- ═══════════════════════════════════════════════════════════════════════════
-- READS — pass-throughs of Persistence's reads, under the same names.
-- ═══════════════════════════════════════════════════════════════════════════

fetchDoctor :: ConnectionPool -> DoctorId -> IO (Either DoctorNotFound Doctor)
fetchDoctor pool doctorId = withResource pool $ \conn ->
  maybe (Left (DoctorNotFound doctorId)) Right <$> Persistence.fetchDoctor conn doctorId

fetchPatient :: ConnectionPool -> PatientId -> IO (Either PatientNotFound Patient)
fetchPatient pool patientId = withResource pool $ \conn ->
  maybe (Left (PatientNotFound patientId)) Right <$> Persistence.fetchPatient conn patientId

fetchHealthcareService
  :: ConnectionPool -> HealthcareServiceId -> IO (Either HealthcareServiceNotFound HealthcareService)
fetchHealthcareService pool serviceId = withResource pool $ \conn ->
  maybe (Left (HealthcareServiceNotFound serviceId)) Right
    <$> decoded (Persistence.fetchHealthcareService conn serviceId)

fetchIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> IO (Either IntakeRequestNotFound IntakeRequest)
fetchIntakeRequest pool requestId = withResource pool $ \conn ->
  maybe (Left (IntakeRequestNotFound requestId)) Right <$> lookupIntakeRequest conn requestId

-- Slots are deleted on consumption: Nothing means no longer available.
fetchAvailableSlot :: ConnectionPool -> SlotId -> IO (Maybe AvailableSlot)
fetchAvailableSlot pool slotId = withResource pool $ \conn ->
  decoded (Persistence.fetchAvailableSlot conn slotId)

fetchDoctors :: ConnectionPool -> IO [Doctor]
fetchDoctors pool = withResource pool Persistence.fetchDoctors

fetchPatients :: ConnectionPool -> IO [Patient]
fetchPatients pool = withResource pool Persistence.fetchPatients

fetchHealthcareServices :: ConnectionPool -> IO [HealthcareService]
fetchHealthcareServices pool = withResource pool $ \conn ->
  decoded (Persistence.fetchHealthcareServices conn)

fetchSubmittedIntakeRequests :: ConnectionPool -> IO [SubmittedIntakeRequest]
fetchSubmittedIntakeRequests pool = withResource pool $ \conn ->
  decoded (Persistence.fetchSubmittedIntakeRequests conn)

-- In waitlist order: Domain's sortByPriority.
fetchAcceptedIntakeRequests :: ConnectionPool -> IO [TriagedIntakeRequest]
fetchAcceptedIntakeRequests pool = withResource pool $ \conn ->
  sortByPriority <$> decoded (Persistence.fetchAcceptedIntakeRequests conn)

fetchAppointedIntakeRequests :: ConnectionPool -> IO [AppointedIntakeRequest]
fetchAppointedIntakeRequests pool = withResource pool $ \conn ->
  decoded (Persistence.fetchAppointedIntakeRequests conn)

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

fetchDoctorCalendarEntriesOverlapping
  :: ConnectionPool -> UTCTime -> UTCTime -> IO [DoctorCalendarEntry]
fetchDoctorCalendarEntriesOverlapping pool from to = withResource pool $ \conn ->
  decoded (Persistence.fetchDoctorCalendarEntriesOverlapping conn from to)
