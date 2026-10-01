{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- Derived from src/Domain.hs and src/Service.hs (triage-api-codegen).
-- One endpoint per public Service function; every 200 body is an
-- {"outcome", "detail"} envelope rendered by render<Function>Answer.
module Api
  ( -- ── API ──────────────────────────────────────────────────────────────
    DomainApi
  , Api
  , AppM
  , openApi
  , app
  , main

    -- ── Answers ──────────────────────────────────────────────────────────
  , renderCreateDoctorAnswer
  , renderCreatePatientAnswer
  , renderCreateHealthcareServiceAnswer
  , renderSubmitIntakeRequestAnswer
  , renderCreateAvailableSlotAnswer
  , renderAcceptSubmittedIntakeRequestAnswer
  , renderRejectSubmittedIntakeRequestAnswer
  , renderMatchAcceptedIntakeRequestToSlotAnswer
  , renderWithdrawIntakeRequestAnswer
  , renderMarkAcceptedIntakeRequestStaleAnswer
  , renderCloseAppointedIntakeRequestAnswer
  , renderMatchAvailableSlotByPriorityAnswer
  , renderFetchDoctorAnswer
  , renderFetchDoctorsAnswer
  , renderFetchPatientAnswer
  , renderFetchPatientsAnswer
  , renderFetchHealthcareServiceAnswer
  , renderFetchHealthcareServicesAnswer
  , renderFetchAvailableSlotAnswer
  , renderFetchIntakeRequestAnswer
  , renderFetchSubmittedIntakeRequestsAnswer
  , renderFetchAcceptedIntakeRequestsAnswer
  , renderFetchAppointedIntakeRequestsAnswer
  , renderFetchRejectedIntakeRequestsByRejectedAtAnswer
  , renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  , renderFetchStaleIntakeRequestsByStaleAtAnswer
  , renderFetchClosedIntakeRequestsByStartAnswer
  , renderFetchDoctorCalendarEntriesOverlappingAnswer
  ) where

import Control.Exception          (SomeException, displayException, try)
import Control.Lens               ((&), (.~))
import Control.Monad.IO.Class     (liftIO)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.Aeson                 (ToJSON (..), Value (..))
import Data.OpenApi               (OpenApi)
import Data.Pool                  (defaultPoolConfig, newPool)
import Data.Time                  (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (close, connectPostgreSQL)
import Network.Wai.Handler.Warp   (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..), cors, simpleCorsResourcePolicy )
import Servant
import Servant.OpenApi            (toOpenApi)
import Servant.Swagger.UI         (SwaggerSchemaUI, swaggerSchemaUIServer)
import System.Environment         (lookupEnv)
import System.Exit                (die)
import System.IO                  (hPutStrLn, stderr)
import Text.Read                  (readMaybe)

import qualified Data.OpenApi       as O
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE

import Domain
import Persistence (ConnectionPool)
import Service
  ( AcceptSubmittedIntakeRequestError (..), AddAvailableSlotOutcome (..)
  , CloseAppointedIntakeRequestError (..), CreateAvailableSlotError (..), DoctorNotFound (..)
  , HealthcareServiceNotFound (..), IntakeRequestDoesNotMatchSlot (..)
  , IntakeRequestInWrongState (..), IntakeRequestNotFound (..)
  , MarkAcceptedIntakeRequestStaleError (..), MatchAcceptedIntakeRequestToSlotError (..)
  , MatchByPriorityOutcome (..), MatchIntakeRequestToSlotOutcome (..), PatientNotFound (..)
  , TransitionOutcome (..) )
import qualified Service
import Transport

-- ═══════════════════════════════════════════════════════════════════════════
-- APP MONAD — the one place every handler passes through
-- ═══════════════════════════════════════════════════════════════════════════

type AppM = ReaderT ConnectionPool Handler

-- Runs a Service call. Anything it raises (a DecodeError, a database
-- failure, anything unexpected) is logged to stderr with its cause and
-- answered 500 with a plain-text body that exposes nothing.
service :: (ConnectionPool -> IO a) -> AppM a
service call = do
  pool <- ask
  liftIO (try (call pool)) >>= \case
    Right a -> pure a
    Left (e :: SomeException) -> do
      liftIO (hPutStrLn stderr ("500: " ++ displayException e))
      throwError err500
        { errBody = "Internal server error"
        , errHeaders = [("Content-Type", "text/plain; charset=utf-8")]
        }

type Range a =
     QueryParam' '[Required, Strict] "from" UTCTime
  :> QueryParam' '[Required, Strict] "to" UTCTime
  :> Get '[JSON] a

-- ═══════════════════════════════════════════════════════════════════════════
-- ANSWER RENDERING — each Service answer type rendered once
-- ═══════════════════════════════════════════════════════════════════════════

ok :: ToJSON a => a -> Envelope
ok = Envelope "ok" . toJSON

-- ── Facts ───────────────────────────────────────────────────────────────────

renderDoctorNotFound :: DoctorNotFound -> Envelope
renderDoctorNotFound (DoctorNotFound i) =
  Envelope "doctorNotFound" (toJSON (fromDomainDoctorId i))

renderPatientNotFound :: PatientNotFound -> Envelope
renderPatientNotFound (PatientNotFound i) =
  Envelope "patientNotFound" (toJSON (fromDomainPatientId i))

renderHealthcareServiceNotFound :: HealthcareServiceNotFound -> Envelope
renderHealthcareServiceNotFound (HealthcareServiceNotFound i) =
  Envelope "healthcareServiceNotFound" (toJSON (fromDomainHealthcareServiceId i))

renderIntakeRequestNotFound :: IntakeRequestNotFound -> Envelope
renderIntakeRequestNotFound (IntakeRequestNotFound i) =
  Envelope "intakeRequestNotFound" (toJSON (fromDomainIntakeRequestId i))

renderIntakeRequestInWrongState :: IntakeRequestInWrongState -> Envelope
renderIntakeRequestInWrongState (IntakeRequestInWrongState r) =
  Envelope "intakeRequestInWrongState" (toJSON (fromDomainIntakeRequest r))

renderIntakeRequestDoesNotMatchSlot :: IntakeRequestDoesNotMatchSlot -> Envelope
renderIntakeRequestDoesNotMatchSlot IntakeRequestDoesNotMatchSlot =
  Envelope "intakeRequestDoesNotMatchSlot" Null

-- ── Errors: delegate to their facts ─────────────────────────────────────────

renderAcceptSubmittedIntakeRequestError :: AcceptSubmittedIntakeRequestError -> Envelope
renderAcceptSubmittedIntakeRequestError = \case
  AcceptSubmittedIntakeRequestIntakeRequestNotFound f     -> renderIntakeRequestNotFound f
  AcceptSubmittedIntakeRequestHealthcareServiceNotFound f -> renderHealthcareServiceNotFound f
  AcceptSubmittedIntakeRequestDoctorNotFound f            -> renderDoctorNotFound f

renderMatchAcceptedIntakeRequestToSlotError :: MatchAcceptedIntakeRequestToSlotError -> Envelope
renderMatchAcceptedIntakeRequestToSlotError = \case
  MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound f      -> renderIntakeRequestNotFound f
  MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState f  -> renderIntakeRequestInWrongState f
  MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot f ->
    renderIntakeRequestDoesNotMatchSlot f

renderMarkAcceptedIntakeRequestStaleError :: MarkAcceptedIntakeRequestStaleError -> Envelope
renderMarkAcceptedIntakeRequestStaleError = \case
  MarkAcceptedIntakeRequestStaleIntakeRequestNotFound f     -> renderIntakeRequestNotFound f
  MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState f -> renderIntakeRequestInWrongState f

renderCloseAppointedIntakeRequestError :: CloseAppointedIntakeRequestError -> Envelope
renderCloseAppointedIntakeRequestError = \case
  CloseAppointedIntakeRequestIntakeRequestNotFound f     -> renderIntakeRequestNotFound f
  CloseAppointedIntakeRequestIntakeRequestInWrongState f -> renderIntakeRequestInWrongState f

renderCreateAvailableSlotError :: CreateAvailableSlotError -> Envelope
renderCreateAvailableSlotError = \case
  CreateAvailableSlotDoctorNotFound f            -> renderDoctorNotFound f
  CreateAvailableSlotHealthcareServiceNotFound f -> renderHealthcareServiceNotFound f

-- ── Outcomes ────────────────────────────────────────────────────────────────

renderTransitionOutcome :: (a -> Value) -> TransitionOutcome a -> Envelope
renderTransitionOutcome renderTarget = \case
  Transitioned a -> Envelope "transitioned" (renderTarget a)
  MovedOn r      -> Envelope "movedOn" (toJSON (fromDomainIntakeRequest r))

renderMatchIntakeRequestToSlotOutcome :: MatchIntakeRequestToSlotOutcome -> Envelope
renderMatchIntakeRequestToSlotOutcome = \case
  IntakeRequestMatchedToSlot a ->
    Envelope "intakeRequestMatchedToSlot" (toJSON (fromDomainAppointedIntakeRequest a))
  AvailableSlotConsumed s ->
    Envelope "availableSlotConsumed" (toJSON (fromDomainSlotId s))
  IntakeRequestMovedOn r ->
    Envelope "intakeRequestMovedOn" (toJSON (fromDomainIntakeRequest r))

renderMatchByPriorityOutcome :: MatchByPriorityOutcome -> Envelope
renderMatchByPriorityOutcome = \case
  NoIntakeRequestMatched -> Envelope "noIntakeRequestMatched" Null
  MatchIntakeRequestToSlotOutcome o ->
    Envelope "matchIntakeRequestToSlotOutcome" (toJSON (renderMatchIntakeRequestToSlotOutcome o))

renderAddAvailableSlotOutcome :: AddAvailableSlotOutcome -> Envelope
renderAddAvailableSlotOutcome = \case
  AvailableSlotAdded s -> Envelope "availableSlotAdded" (toJSON (fromDomainAvailableSlot s))
  AvailableSlotOverlapsDoctorCalendar -> Envelope "availableSlotOverlapsDoctorCalendar" Null

-- ── One per use case ────────────────────────────────────────────────────────

renderCreateDoctorAnswer :: Doctor -> CreateDoctorAnswer
renderCreateDoctorAnswer = CreateDoctorAnswer . ok . fromDomainDoctor

renderCreatePatientAnswer :: Patient -> CreatePatientAnswer
renderCreatePatientAnswer = CreatePatientAnswer . ok . fromDomainPatient

renderCreateHealthcareServiceAnswer :: HealthcareService -> CreateHealthcareServiceAnswer
renderCreateHealthcareServiceAnswer =
  CreateHealthcareServiceAnswer . ok . fromDomainHealthcareService

renderSubmitIntakeRequestAnswer
  :: Either PatientNotFound SubmittedIntakeRequest -> SubmitIntakeRequestAnswer
renderSubmitIntakeRequestAnswer = SubmitIntakeRequestAnswer
  . either renderPatientNotFound (ok . fromDomainSubmittedIntakeRequest)

renderCreateAvailableSlotAnswer
  :: Either CreateAvailableSlotError AddAvailableSlotOutcome -> CreateAvailableSlotAnswer
renderCreateAvailableSlotAnswer = CreateAvailableSlotAnswer
  . either renderCreateAvailableSlotError renderAddAvailableSlotOutcome

renderAcceptSubmittedIntakeRequestAnswer
  :: Either AcceptSubmittedIntakeRequestError (TransitionOutcome TriagedIntakeRequest)
  -> AcceptSubmittedIntakeRequestAnswer
renderAcceptSubmittedIntakeRequestAnswer = AcceptSubmittedIntakeRequestAnswer
  . either renderAcceptSubmittedIntakeRequestError
      (renderTransitionOutcome (toJSON . fromDomainTriagedIntakeRequest))

renderRejectSubmittedIntakeRequestAnswer
  :: Either IntakeRequestNotFound (TransitionOutcome RejectedIntakeRequest)
  -> RejectSubmittedIntakeRequestAnswer
renderRejectSubmittedIntakeRequestAnswer = RejectSubmittedIntakeRequestAnswer
  . either renderIntakeRequestNotFound
      (renderTransitionOutcome (toJSON . fromDomainRejectedIntakeRequest))

renderMatchAcceptedIntakeRequestToSlotAnswer
  :: Either MatchAcceptedIntakeRequestToSlotError MatchIntakeRequestToSlotOutcome
  -> MatchAcceptedIntakeRequestToSlotAnswer
renderMatchAcceptedIntakeRequestToSlotAnswer = MatchAcceptedIntakeRequestToSlotAnswer
  . either renderMatchAcceptedIntakeRequestToSlotError renderMatchIntakeRequestToSlotOutcome

renderWithdrawIntakeRequestAnswer
  :: Either IntakeRequestNotFound (TransitionOutcome WithdrawnIntakeRequest)
  -> WithdrawIntakeRequestAnswer
renderWithdrawIntakeRequestAnswer = WithdrawIntakeRequestAnswer
  . either renderIntakeRequestNotFound
      (renderTransitionOutcome (toJSON . fromDomainWithdrawnIntakeRequest))

renderMarkAcceptedIntakeRequestStaleAnswer
  :: Either MarkAcceptedIntakeRequestStaleError (TransitionOutcome StaleIntakeRequest)
  -> MarkAcceptedIntakeRequestStaleAnswer
renderMarkAcceptedIntakeRequestStaleAnswer = MarkAcceptedIntakeRequestStaleAnswer
  . either renderMarkAcceptedIntakeRequestStaleError
      (renderTransitionOutcome (toJSON . fromDomainStaleIntakeRequest))

renderCloseAppointedIntakeRequestAnswer
  :: Either CloseAppointedIntakeRequestError (TransitionOutcome ClosedIntakeRequest)
  -> CloseAppointedIntakeRequestAnswer
renderCloseAppointedIntakeRequestAnswer = CloseAppointedIntakeRequestAnswer
  . either renderCloseAppointedIntakeRequestError
      (renderTransitionOutcome (toJSON . fromDomainClosedIntakeRequest))

renderMatchAvailableSlotByPriorityAnswer
  :: MatchByPriorityOutcome -> MatchAvailableSlotByPriorityAnswer
renderMatchAvailableSlotByPriorityAnswer =
  MatchAvailableSlotByPriorityAnswer . renderMatchByPriorityOutcome

renderFetchDoctorAnswer :: Either DoctorNotFound Doctor -> FetchDoctorAnswer
renderFetchDoctorAnswer =
  FetchDoctorAnswer . either renderDoctorNotFound (ok . fromDomainDoctor)

renderFetchDoctorsAnswer :: [Doctor] -> FetchDoctorsAnswer
renderFetchDoctorsAnswer = FetchDoctorsAnswer . ok . map fromDomainDoctor

renderFetchPatientAnswer :: Either PatientNotFound Patient -> FetchPatientAnswer
renderFetchPatientAnswer =
  FetchPatientAnswer . either renderPatientNotFound (ok . fromDomainPatient)

renderFetchPatientsAnswer :: [Patient] -> FetchPatientsAnswer
renderFetchPatientsAnswer = FetchPatientsAnswer . ok . map fromDomainPatient

renderFetchHealthcareServiceAnswer
  :: Either HealthcareServiceNotFound HealthcareService -> FetchHealthcareServiceAnswer
renderFetchHealthcareServiceAnswer = FetchHealthcareServiceAnswer
  . either renderHealthcareServiceNotFound (ok . fromDomainHealthcareService)

renderFetchHealthcareServicesAnswer :: [HealthcareService] -> FetchHealthcareServicesAnswer
renderFetchHealthcareServicesAnswer =
  FetchHealthcareServicesAnswer . ok . map fromDomainHealthcareService

-- Deleted on consumption: Nothing is availableSlotConsumed.
renderFetchAvailableSlotAnswer :: SlotId -> Maybe AvailableSlot -> FetchAvailableSlotAnswer
renderFetchAvailableSlotAnswer slotId = FetchAvailableSlotAnswer . \case
  Just s  -> ok (fromDomainAvailableSlot s)
  Nothing -> Envelope "availableSlotConsumed" (toJSON (fromDomainSlotId slotId))

renderFetchIntakeRequestAnswer
  :: Either IntakeRequestNotFound IntakeRequest -> FetchIntakeRequestAnswer
renderFetchIntakeRequestAnswer = FetchIntakeRequestAnswer
  . either renderIntakeRequestNotFound (ok . fromDomainIntakeRequest)

renderFetchSubmittedIntakeRequestsAnswer
  :: [SubmittedIntakeRequest] -> FetchSubmittedIntakeRequestsAnswer
renderFetchSubmittedIntakeRequestsAnswer =
  FetchSubmittedIntakeRequestsAnswer . ok . map fromDomainSubmittedIntakeRequest

renderFetchAcceptedIntakeRequestsAnswer
  :: [TriagedIntakeRequest] -> FetchAcceptedIntakeRequestsAnswer
renderFetchAcceptedIntakeRequestsAnswer =
  FetchAcceptedIntakeRequestsAnswer . ok . map fromDomainTriagedIntakeRequest

renderFetchAppointedIntakeRequestsAnswer
  :: [AppointedIntakeRequest] -> FetchAppointedIntakeRequestsAnswer
renderFetchAppointedIntakeRequestsAnswer =
  FetchAppointedIntakeRequestsAnswer . ok . map fromDomainAppointedIntakeRequest

renderFetchRejectedIntakeRequestsByRejectedAtAnswer
  :: [RejectedIntakeRequest] -> FetchRejectedIntakeRequestsByRejectedAtAnswer
renderFetchRejectedIntakeRequestsByRejectedAtAnswer =
  FetchRejectedIntakeRequestsByRejectedAtAnswer . ok . map fromDomainRejectedIntakeRequest

renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  :: [WithdrawnIntakeRequest] -> FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer =
  FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer . ok . map fromDomainWithdrawnIntakeRequest

renderFetchStaleIntakeRequestsByStaleAtAnswer
  :: [StaleIntakeRequest] -> FetchStaleIntakeRequestsByStaleAtAnswer
renderFetchStaleIntakeRequestsByStaleAtAnswer =
  FetchStaleIntakeRequestsByStaleAtAnswer . ok . map fromDomainStaleIntakeRequest

renderFetchClosedIntakeRequestsByStartAnswer
  :: [ClosedIntakeRequest] -> FetchClosedIntakeRequestsByStartAnswer
renderFetchClosedIntakeRequestsByStartAnswer =
  FetchClosedIntakeRequestsByStartAnswer . ok . map fromDomainClosedIntakeRequest

renderFetchDoctorCalendarEntriesOverlappingAnswer
  :: [DoctorCalendarEntry] -> FetchDoctorCalendarEntriesOverlappingAnswer
renderFetchDoctorCalendarEntriesOverlappingAnswer =
  FetchDoctorCalendarEntriesOverlappingAnswer . ok . map fromDomainDoctorCalendarEntry

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTORS — /doctors
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorsApi = "doctors" :>
  (    ReqBody '[JSON] CreateDoctorRequest :> Post '[JSON] CreateDoctorAnswer
  :<|> Get '[JSON] FetchDoctorsAnswer
  :<|> Capture "doctorId" DoctorIdDTO :> Get '[JSON] FetchDoctorAnswer
  )

doctorsServer :: ServerT DoctorsApi AppM
doctorsServer = createDoctorH :<|> fetchDoctorsH :<|> fetchDoctorH
  where
    createDoctorH req = service $ \pool ->
      renderCreateDoctorAnswer <$> Service.createDoctor pool req.name
    fetchDoctorsH = service $ \pool ->
      renderFetchDoctorsAnswer <$> Service.fetchDoctors pool
    fetchDoctorH doctor = service $ \pool ->
      renderFetchDoctorAnswer <$> Service.fetchDoctor pool (toDomainDoctorId doctor)

-- ═══════════════════════════════════════════════════════════════════════════
-- PATIENTS — /patients
-- ═══════════════════════════════════════════════════════════════════════════

type PatientsApi = "patients" :>
  (    ReqBody '[JSON] CreatePatientRequest :> Post '[JSON] CreatePatientAnswer
  :<|> Get '[JSON] FetchPatientsAnswer
  :<|> Capture "patientId" PatientIdDTO :> Get '[JSON] FetchPatientAnswer
  )

patientsServer :: ServerT PatientsApi AppM
patientsServer = createPatientH :<|> fetchPatientsH :<|> fetchPatientH
  where
    createPatientH req = service $ \pool ->
      renderCreatePatientAnswer <$> Service.createPatient pool req.name
    fetchPatientsH = service $ \pool ->
      renderFetchPatientsAnswer <$> Service.fetchPatients pool
    fetchPatientH patient = service $ \pool ->
      renderFetchPatientAnswer <$> Service.fetchPatient pool (toDomainPatientId patient)

-- ═══════════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICES — /healthcare-services
-- ═══════════════════════════════════════════════════════════════════════════

type HealthcareServicesApi = "healthcare-services" :>
  (    ReqBody '[JSON] CreateHealthcareServiceRequest :> Post '[JSON] CreateHealthcareServiceAnswer
  :<|> Get '[JSON] FetchHealthcareServicesAnswer
  :<|> Capture "healthcareServiceId" HealthcareServiceIdDTO :> Get '[JSON] FetchHealthcareServiceAnswer
  )

healthcareServicesServer :: ServerT HealthcareServicesApi AppM
healthcareServicesServer =
  createHealthcareServiceH :<|> fetchHealthcareServicesH :<|> fetchHealthcareServiceH
  where
    createHealthcareServiceH req = service $ \pool ->
      renderCreateHealthcareServiceAnswer
        <$> Service.createHealthcareService pool req.name (toDomainDuration req.duration)
    fetchHealthcareServicesH = service $ \pool ->
      renderFetchHealthcareServicesAnswer <$> Service.fetchHealthcareServices pool
    fetchHealthcareServiceH serviceId = service $ \pool ->
      renderFetchHealthcareServiceAnswer
        <$> Service.fetchHealthcareService pool (toDomainHealthcareServiceId serviceId)

-- ═══════════════════════════════════════════════════════════════════════════
-- AVAILABLE SLOTS — /available-slots
-- ═══════════════════════════════════════════════════════════════════════════

type AvailableSlotsApi = "available-slots" :>
  (    ReqBody '[JSON] CreateAvailableSlotRequest :> Post '[JSON] CreateAvailableSlotAnswer
  :<|> Capture "slotId" SlotIdDTO :> Get '[JSON] FetchAvailableSlotAnswer
  :<|> Capture "slotId" SlotIdDTO :> "match-by-priority"
         :> Post '[JSON] MatchAvailableSlotByPriorityAnswer
  )

availableSlotsServer :: ServerT AvailableSlotsApi AppM
availableSlotsServer =
  createAvailableSlotH :<|> fetchAvailableSlotH :<|> matchAvailableSlotByPriorityH
  where
    createAvailableSlotH req = service $ \pool ->
      renderCreateAvailableSlotAnswer
        <$> Service.createAvailableSlot pool
              (toDomainDoctorId req.doctorId)
              (toDomainHealthcareServiceId req.healthcareServiceId)
              req.start
    fetchAvailableSlotH slotId = service $ \pool ->
      renderFetchAvailableSlotAnswer (toDomainSlotId slotId) <$> Service.fetchAvailableSlot pool (toDomainSlotId slotId)
    matchAvailableSlotByPriorityH slotId = service $ \pool ->
      renderMatchAvailableSlotByPriorityAnswer
        <$> Service.matchAvailableSlotByPriority pool (toDomainSlotId slotId)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUESTS — /intake-requests
-- ═══════════════════════════════════════════════════════════════════════════

type IntakeRequestsApi = "intake-requests" :>
  (    ReqBody '[JSON] SubmitIntakeRequestRequest :> Post '[JSON] SubmitIntakeRequestAnswer
  :<|> "submitted" :> Get '[JSON] FetchSubmittedIntakeRequestsAnswer
  :<|> "accepted" :> Get '[JSON] FetchAcceptedIntakeRequestsAnswer
  :<|> "appointed" :> Get '[JSON] FetchAppointedIntakeRequestsAnswer
  :<|> "rejected" :> Range FetchRejectedIntakeRequestsByRejectedAtAnswer
  :<|> "withdrawn" :> Range FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  :<|> "stale" :> Range FetchStaleIntakeRequestsByStaleAtAnswer
  :<|> "closed" :> Range FetchClosedIntakeRequestsByStartAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> Get '[JSON] FetchIntakeRequestAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> "accept"
         :> ReqBody '[JSON] AcceptSubmittedIntakeRequestRequest
         :> Post '[JSON] AcceptSubmittedIntakeRequestAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> "reject"
         :> ReqBody '[JSON] RejectSubmittedIntakeRequestRequest
         :> Post '[JSON] RejectSubmittedIntakeRequestAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> "match-to-slot"
         :> ReqBody '[JSON] MatchAcceptedIntakeRequestToSlotRequest
         :> Post '[JSON] MatchAcceptedIntakeRequestToSlotAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> "withdraw"
         :> ReqBody '[JSON] WithdrawIntakeRequestRequest
         :> Post '[JSON] WithdrawIntakeRequestAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> "mark-stale"
         :> Post '[JSON] MarkAcceptedIntakeRequestStaleAnswer
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :> "close"
         :> ReqBody '[JSON] CloseAppointedIntakeRequestRequest
         :> Post '[JSON] CloseAppointedIntakeRequestAnswer
  )

intakeRequestsServer :: ServerT IntakeRequestsApi AppM
intakeRequestsServer =
       submitIntakeRequestH
  :<|> fetchSubmittedH
  :<|> fetchAcceptedH
  :<|> fetchAppointedH
  :<|> fetchRejectedH
  :<|> fetchWithdrawnH
  :<|> fetchStaleH
  :<|> fetchClosedH
  :<|> fetchIntakeRequestH
  :<|> acceptH
  :<|> rejectH
  :<|> matchToSlotH
  :<|> withdrawH
  :<|> markStaleH
  :<|> closeH
  where
    submitIntakeRequestH req = service $ \pool -> do
      now <- getCurrentTime
      renderSubmitIntakeRequestAnswer
        <$> Service.submitIntakeRequest pool (toDomainPatientId req.patientId) req.narrative now
    fetchSubmittedH = service $ \pool ->
      renderFetchSubmittedIntakeRequestsAnswer <$> Service.fetchSubmittedIntakeRequests pool
    fetchAcceptedH = service $ \pool ->
      renderFetchAcceptedIntakeRequestsAnswer <$> Service.fetchAcceptedIntakeRequests pool
    fetchAppointedH = service $ \pool ->
      renderFetchAppointedIntakeRequestsAnswer <$> Service.fetchAppointedIntakeRequests pool
    fetchRejectedH from to = service $ \pool ->
      renderFetchRejectedIntakeRequestsByRejectedAtAnswer
        <$> Service.fetchRejectedIntakeRequestsByRejectedAt pool from to
    fetchWithdrawnH from to = service $ \pool ->
      renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
        <$> Service.fetchWithdrawnIntakeRequestsByWithdrawnAt pool from to
    fetchStaleH from to = service $ \pool ->
      renderFetchStaleIntakeRequestsByStaleAtAnswer
        <$> Service.fetchStaleIntakeRequestsByStaleAt pool from to
    fetchClosedH from to = service $ \pool ->
      renderFetchClosedIntakeRequestsByStartAnswer
        <$> Service.fetchClosedIntakeRequestsByStart pool from to
    fetchIntakeRequestH requestId = service $ \pool ->
      renderFetchIntakeRequestAnswer
        <$> Service.fetchIntakeRequest pool (toDomainIntakeRequestId requestId)
    acceptH requestId req = service $ \pool -> do
      now <- getCurrentTime
      renderAcceptSubmittedIntakeRequestAnswer
        <$> Service.acceptSubmittedIntakeRequest pool
              (toDomainIntakeRequestId requestId)
              (toDomainHealthcareServiceId req.healthcareServiceId)
              (toDomainIntakeRequestPriority req.priority)
              (toDomainDoctorRequirement req.doctorRequirement)
              now
    rejectH requestId req = service $ \pool -> do
      now <- getCurrentTime
      renderRejectSubmittedIntakeRequestAnswer
        <$> Service.rejectSubmittedIntakeRequest pool
              (toDomainIntakeRequestId requestId) now req.rejectionReason
    matchToSlotH requestId req = service $ \pool ->
      renderMatchAcceptedIntakeRequestToSlotAnswer
        <$> Service.matchAcceptedIntakeRequestToSlot pool
              (toDomainIntakeRequestId requestId) (toDomainSlotId req.slotId)
    withdrawH requestId req = service $ \pool -> do
      now <- getCurrentTime
      renderWithdrawIntakeRequestAnswer
        <$> Service.withdrawIntakeRequest pool
              (toDomainIntakeRequestId requestId) now req.withdrawalNote
    markStaleH requestId = service $ \pool -> do
      now <- getCurrentTime
      renderMarkAcceptedIntakeRequestStaleAnswer
        <$> Service.markAcceptedIntakeRequestStale pool (toDomainIntakeRequestId requestId) now
    closeH requestId req = service $ \pool -> do
      now <- getCurrentTime
      renderCloseAppointedIntakeRequestAnswer
        <$> Service.closeAppointedIntakeRequest pool
              (toDomainIntakeRequestId requestId)
              (toDomainCloseReasonRequest now req.closeReason)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR CALENDAR — /doctor-calendar
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorCalendarApi = "doctor-calendar" :>
  Range FetchDoctorCalendarEntriesOverlappingAnswer

doctorCalendarServer :: ServerT DoctorCalendarApi AppM
doctorCalendarServer = fetchDoctorCalendarEntriesOverlappingH
  where
    fetchDoctorCalendarEntriesOverlappingH from to = service $ \pool ->
      renderFetchDoctorCalendarEntriesOverlappingAnswer
        <$> Service.fetchDoctorCalendarEntriesOverlapping pool from to

-- ═══════════════════════════════════════════════════════════════════════════
-- API
-- ═══════════════════════════════════════════════════════════════════════════

type DomainApi =
       DoctorsApi
  :<|> PatientsApi
  :<|> HealthcareServicesApi
  :<|> AvailableSlotsApi
  :<|> IntakeRequestsApi
  :<|> DoctorCalendarApi

type Api = DomainApi :<|> SwaggerSchemaUI "swagger-ui" "openapi.json"

domainServer :: ServerT DomainApi AppM
domainServer =
       doctorsServer
  :<|> patientsServer
  :<|> healthcareServicesServer
  :<|> availableSlotsServer
  :<|> intakeRequestsServer
  :<|> doctorCalendarServer

openApi :: OpenApi
openApi = toOpenApi (Proxy @DomainApi)
  & O.info . O.title   .~ "triage"
  & O.info . O.version .~ "0.1.0.0"

app :: ConnectionPool -> Application
app pool = cors (const (Just corsPolicy)) $ serve (Proxy @Api) $
       hoistServer (Proxy @DomainApi) (`runReaderT` pool) domainServer
  :<|> swaggerSchemaUIServer openApi

-- The frontend's origin (its dev server).
corsPolicy :: CorsResourcePolicy
corsPolicy = simpleCorsResourcePolicy
  { corsOrigins        = Just (["http://localhost:5173"], False)
  , corsMethods        = ["GET", "POST"]
  , corsRequestHeaders = ["Content-Type"]
  }

-- ═══════════════════════════════════════════════════════════════════════════
-- MAIN — only serves; migrations are a separate, manual step
-- ═══════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
  dbUrl <- maybe "postgresql://localhost/triage" T.pack <$> lookupEnv "TRIAGE_DB_URL"
  port  <- lookupEnv "TRIAGE_PORT" >>= \case
    Nothing  -> pure 8080
    Just raw -> maybe (die ("TRIAGE_PORT is not a port number: " ++ raw)) pure (readMaybe raw)
  pool <- newPool (defaultPoolConfig (connectPostgreSQL (TE.encodeUtf8 dbUrl)) close 60 10)
  hPutStrLn stderr ("triage-server listening on port " ++ show (port :: Int))
  run port (app pool)
