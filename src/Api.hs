{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- Derived from src/Domain.hs and src/Service.hs by the triage-api-codegen
-- skill: one endpoint per public Service function, grouped per resource.
-- Handlers only parse, supply the current time, and render answers.
module Api
  ( main
  , app
  , API
  , openApi

    -- ── Rendering: one function per Service answer type ──────────────────
  , renderDoctorNotFound
  , renderPatientNotFound
  , renderHealthcareServiceNotFound
  , renderIntakeRequestNotFound
  , renderIntakeRequestInWrongState
  , renderSlotDoesNotMatchIntakeRequest
  , renderAcceptSubmittedIntakeRequestError
  , renderMatchAcceptedIntakeRequestToSlotError
  , renderMarkAcceptedIntakeRequestStaleError
  , renderCloseAppointedIntakeRequestError
  , renderCreateAvailableSlotError
  , renderTransitionOutcome
  , renderMatchOutcome
  , renderPriorityMatchOutcome
  , renderSlotCreationOutcome

    -- ── Each Service function's answer ───────────────────────────────────
  , renderCreateDoctorAnswer
  , renderCreatePatientAnswer
  , renderCreateHealthcareServiceAnswer
  , renderSubmitIntakeRequestAnswer
  , renderAcceptSubmittedIntakeRequestAnswer
  , renderRejectSubmittedIntakeRequestAnswer
  , renderMatchAcceptedIntakeRequestToSlotAnswer
  , renderWithdrawIntakeRequestAnswer
  , renderMarkAcceptedIntakeRequestStaleAnswer
  , renderCloseAppointedIntakeRequestAnswer
  , renderMatchAvailableSlotByPriorityAnswer
  , renderCreateAvailableSlotAnswer
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

import Control.Exception          (SomeAsyncException, SomeException, displayException,
                                   fromException, throwIO, try)
import Control.Lens               ((&), (.~))
import Control.Monad.IO.Class     (liftIO)
import Control.Monad.Trans.Except (ExceptT (..))
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.Aeson                 (ToJSON)
import Data.Maybe                 (fromMaybe)
import Data.OpenApi               (OpenApi, info, title, version)
import Data.Pool                  (defaultPoolConfig, newPool)
import Data.Time                  (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (close, connectPostgreSQL)
import Network.Wai.Handler.Warp   (run)
import Network.Wai.Middleware.Cors
  (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import Servant
import Servant.OpenApi            (toOpenApi)
import Servant.Swagger.UI         (SwaggerSchemaUI, swaggerSchemaUIServer)
import System.Environment         (lookupEnv)
import System.Exit                (die)
import System.IO                  (hPutStrLn, stderr)
import Text.Read                  (readMaybe)

import qualified Data.Text          as Text
import qualified Data.Text.Encoding as Text

import Domain
  ( AppointedIntakeRequest, AvailableSlot, ClosedIntakeRequest, Doctor, DoctorCalendarEntry
  , HealthcareService, IntakeRequest, Patient, RejectedIntakeRequest, StaleIntakeRequest
  , SubmittedIntakeRequest, TriagedIntakeRequest, WithdrawnIntakeRequest )
import Persistence (ConnectionPool)
import Service
  ( AcceptSubmittedIntakeRequestError (..), CloseAppointedIntakeRequestError (..)
  , CreateAvailableSlotError (..), DoctorNotFound (..), HealthcareServiceNotFound (..)
  , IntakeRequestInWrongState (..), IntakeRequestNotFound (..)
  , MarkAcceptedIntakeRequestStaleError (..), MatchAcceptedIntakeRequestToSlotError (..)
  , MatchOutcome (..), PatientNotFound (..), PriorityMatchOutcome (..)
  , SlotCreationOutcome (..), SlotDoesNotMatchIntakeRequest (..), TransitionOutcome (..) )
import Transport

import qualified Service as S

-- ═══════════════════════════════════════════════════════════════════════════
-- HANDLER MONAD
-- ═══════════════════════════════════════════════════════════════════════════

type AppM = ReaderT ConnectionPool Handler

withPool :: (ConnectionPool -> IO a) -> AppM a
withPool f = ask >>= liftIO . f

-- When the action is recorded.
now :: AppM UTCTime
now = liftIO getCurrentTime

-- The one place a 500 is answered: every synchronous exception (a
-- DecodeError raised by Service, a database failure, anything else) is
-- written to stderr with its cause and answered with a plain body.
toHandler :: ConnectionPool -> AppM a -> Handler a
toHandler pool action = Handler . ExceptT $ do
  result <- try (runHandler (runReaderT action pool))
  case result of
    Right answered -> pure answered
    Left (e :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> do
          hPutStrLn stderr ("500 Internal Server Error: " <> displayException e)
          pure . Left $ err500
            { errBody    = "Internal Server Error"
            , errHeaders = [("Content-Type", "text/plain; charset=utf-8")]
            }

-- ═══════════════════════════════════════════════════════════════════════════
-- RENDERING
-- Each Service answer type rendered once; a <Function>Error delegates to
-- its facts. A plain value is "ok".
-- ═══════════════════════════════════════════════════════════════════════════

renderDoctorNotFound :: DoctorNotFound -> Envelope
renderDoctorNotFound (DoctorNotFound doctorId) = answer doctorNotFound (fromDomainDoctorId doctorId)

renderPatientNotFound :: PatientNotFound -> Envelope
renderPatientNotFound (PatientNotFound patientId) =
  answer patientNotFound (fromDomainPatientId patientId)

renderHealthcareServiceNotFound :: HealthcareServiceNotFound -> Envelope
renderHealthcareServiceNotFound (HealthcareServiceNotFound serviceId) =
  answer healthcareServiceNotFound (fromDomainHealthcareServiceId serviceId)

renderIntakeRequestNotFound :: IntakeRequestNotFound -> Envelope
renderIntakeRequestNotFound (IntakeRequestNotFound requestId) =
  answer intakeRequestNotFound (fromDomainIntakeRequestId requestId)

renderIntakeRequestInWrongState :: IntakeRequestInWrongState -> Envelope
renderIntakeRequestInWrongState (IntakeRequestInWrongState request) =
  answer intakeRequestInWrongState (fromDomainIntakeRequest request)

renderSlotDoesNotMatchIntakeRequest :: SlotDoesNotMatchIntakeRequest -> Envelope
renderSlotDoesNotMatchIntakeRequest SlotDoesNotMatchIntakeRequest =
  answer slotDoesNotMatchIntakeRequest NoDetail

renderAcceptSubmittedIntakeRequestError :: AcceptSubmittedIntakeRequestError -> Envelope
renderAcceptSubmittedIntakeRequestError e = case e of
  AcceptSubmittedIntakeRequestIntakeRequestNotFound fact     -> renderIntakeRequestNotFound fact
  AcceptSubmittedIntakeRequestHealthcareServiceNotFound fact -> renderHealthcareServiceNotFound fact
  AcceptSubmittedIntakeRequestDoctorNotFound fact            -> renderDoctorNotFound fact

renderMatchAcceptedIntakeRequestToSlotError :: MatchAcceptedIntakeRequestToSlotError -> Envelope
renderMatchAcceptedIntakeRequestToSlotError e = case e of
  MatchAcceptedIntakeRequestToSlotIntakeRequestNotFound fact -> renderIntakeRequestNotFound fact
  MatchAcceptedIntakeRequestToSlotIntakeRequestInWrongState fact -> renderIntakeRequestInWrongState fact
  MatchAcceptedIntakeRequestToSlotSlotDoesNotMatchIntakeRequest fact ->
    renderSlotDoesNotMatchIntakeRequest fact

renderMarkAcceptedIntakeRequestStaleError :: MarkAcceptedIntakeRequestStaleError -> Envelope
renderMarkAcceptedIntakeRequestStaleError e = case e of
  MarkAcceptedIntakeRequestStaleIntakeRequestNotFound fact     -> renderIntakeRequestNotFound fact
  MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState fact -> renderIntakeRequestInWrongState fact

renderCloseAppointedIntakeRequestError :: CloseAppointedIntakeRequestError -> Envelope
renderCloseAppointedIntakeRequestError e = case e of
  CloseAppointedIntakeRequestIntakeRequestNotFound fact     -> renderIntakeRequestNotFound fact
  CloseAppointedIntakeRequestIntakeRequestInWrongState fact -> renderIntakeRequestInWrongState fact

renderCreateAvailableSlotError :: CreateAvailableSlotError -> Envelope
renderCreateAvailableSlotError e = case e of
  CreateAvailableSlotDoctorNotFound fact            -> renderDoctorNotFound fact
  CreateAvailableSlotHealthcareServiceNotFound fact -> renderHealthcareServiceNotFound fact

renderTransitionOutcome :: ToJSON d => (a -> d) -> TransitionOutcome a -> Envelope
renderTransitionOutcome toDTO outcome = case outcome of
  Transitioned next -> answer transitioned (toDTO next)
  MovedOn current   -> answer movedOn (fromDomainIntakeRequest current)

renderMatchOutcome :: MatchOutcome -> Envelope
renderMatchOutcome outcome = case outcome of
  Matched appointed            -> answer matched (fromDomainAppointedIntakeRequest appointed)
  AvailableSlotConsumed        -> answer availableSlotConsumed NoDetail
  IntakeRequestMovedOn current -> answer intakeRequestMovedOn (fromDomainIntakeRequest current)

renderPriorityMatchOutcome :: PriorityMatchOutcome -> Envelope
renderPriorityMatchOutcome outcome = case outcome of
  NoMatchingIntakeRequest -> answer noMatchingIntakeRequest NoDetail
  MatchOutcome attempt  -> answer matchOutcome (MatchOutcomeDTO (renderMatchOutcome attempt))

renderSlotCreationOutcome :: SlotCreationOutcome -> Envelope
renderSlotCreationOutcome outcome = case outcome of
  SlotCreated slot           -> answer slotCreated (fromDomainAvailableSlot slot)
  SlotOverlapsDoctorCalendar -> answer slotOverlapsDoctorCalendar NoDetail

renderOk :: ToJSON d => d -> Envelope
renderOk = answer ok

-- ── Each Service function's answer ─────────────────────────────────────────

renderCreateDoctorAnswer :: Doctor -> CreateDoctorAnswer
renderCreateDoctorAnswer = CreateDoctorAnswer . renderOk . fromDomainDoctor

renderCreatePatientAnswer :: Patient -> CreatePatientAnswer
renderCreatePatientAnswer = CreatePatientAnswer . renderOk . fromDomainPatient

renderCreateHealthcareServiceAnswer :: HealthcareService -> CreateHealthcareServiceAnswer
renderCreateHealthcareServiceAnswer =
  CreateHealthcareServiceAnswer . renderOk . fromDomainHealthcareService

renderSubmitIntakeRequestAnswer
  :: Either PatientNotFound SubmittedIntakeRequest -> SubmitIntakeRequestAnswer
renderSubmitIntakeRequestAnswer =
  SubmitIntakeRequestAnswer
    . either renderPatientNotFound (renderOk . fromDomainSubmittedIntakeRequest)

renderAcceptSubmittedIntakeRequestAnswer
  :: Either AcceptSubmittedIntakeRequestError (TransitionOutcome TriagedIntakeRequest)
  -> AcceptSubmittedIntakeRequestAnswer
renderAcceptSubmittedIntakeRequestAnswer =
  AcceptSubmittedIntakeRequestAnswer
    . either renderAcceptSubmittedIntakeRequestError
             (renderTransitionOutcome fromDomainTriagedIntakeRequest)

renderRejectSubmittedIntakeRequestAnswer
  :: Either IntakeRequestNotFound (TransitionOutcome RejectedIntakeRequest)
  -> RejectSubmittedIntakeRequestAnswer
renderRejectSubmittedIntakeRequestAnswer =
  RejectSubmittedIntakeRequestAnswer
    . either renderIntakeRequestNotFound (renderTransitionOutcome fromDomainRejectedIntakeRequest)

renderMatchAcceptedIntakeRequestToSlotAnswer
  :: Either MatchAcceptedIntakeRequestToSlotError MatchOutcome
  -> MatchAcceptedIntakeRequestToSlotAnswer
renderMatchAcceptedIntakeRequestToSlotAnswer =
  MatchAcceptedIntakeRequestToSlotAnswer
    . either renderMatchAcceptedIntakeRequestToSlotError renderMatchOutcome

renderWithdrawIntakeRequestAnswer
  :: Either IntakeRequestNotFound (TransitionOutcome WithdrawnIntakeRequest)
  -> WithdrawIntakeRequestAnswer
renderWithdrawIntakeRequestAnswer =
  WithdrawIntakeRequestAnswer
    . either renderIntakeRequestNotFound (renderTransitionOutcome fromDomainWithdrawnIntakeRequest)

renderMarkAcceptedIntakeRequestStaleAnswer
  :: Either MarkAcceptedIntakeRequestStaleError (TransitionOutcome StaleIntakeRequest)
  -> MarkAcceptedIntakeRequestStaleAnswer
renderMarkAcceptedIntakeRequestStaleAnswer =
  MarkAcceptedIntakeRequestStaleAnswer
    . either renderMarkAcceptedIntakeRequestStaleError
             (renderTransitionOutcome fromDomainStaleIntakeRequest)

renderCloseAppointedIntakeRequestAnswer
  :: Either CloseAppointedIntakeRequestError (TransitionOutcome ClosedIntakeRequest)
  -> CloseAppointedIntakeRequestAnswer
renderCloseAppointedIntakeRequestAnswer =
  CloseAppointedIntakeRequestAnswer
    . either renderCloseAppointedIntakeRequestError
             (renderTransitionOutcome fromDomainClosedIntakeRequest)

renderMatchAvailableSlotByPriorityAnswer
  :: PriorityMatchOutcome -> MatchAvailableSlotByPriorityAnswer
renderMatchAvailableSlotByPriorityAnswer =
  MatchAvailableSlotByPriorityAnswer . renderPriorityMatchOutcome

renderCreateAvailableSlotAnswer
  :: Either CreateAvailableSlotError SlotCreationOutcome -> CreateAvailableSlotAnswer
renderCreateAvailableSlotAnswer =
  CreateAvailableSlotAnswer . either renderCreateAvailableSlotError renderSlotCreationOutcome

renderFetchDoctorAnswer :: Either DoctorNotFound Doctor -> FetchDoctorAnswer
renderFetchDoctorAnswer =
  FetchDoctorAnswer . either renderDoctorNotFound (renderOk . fromDomainDoctor)

renderFetchDoctorsAnswer :: [Doctor] -> FetchDoctorsAnswer
renderFetchDoctorsAnswer = FetchDoctorsAnswer . renderOk . map fromDomainDoctor

renderFetchPatientAnswer :: Either PatientNotFound Patient -> FetchPatientAnswer
renderFetchPatientAnswer =
  FetchPatientAnswer . either renderPatientNotFound (renderOk . fromDomainPatient)

renderFetchPatientsAnswer :: [Patient] -> FetchPatientsAnswer
renderFetchPatientsAnswer = FetchPatientsAnswer . renderOk . map fromDomainPatient

renderFetchHealthcareServiceAnswer
  :: Either HealthcareServiceNotFound HealthcareService -> FetchHealthcareServiceAnswer
renderFetchHealthcareServiceAnswer =
  FetchHealthcareServiceAnswer
    . either renderHealthcareServiceNotFound (renderOk . fromDomainHealthcareService)

renderFetchHealthcareServicesAnswer :: [HealthcareService] -> FetchHealthcareServicesAnswer
renderFetchHealthcareServicesAnswer =
  FetchHealthcareServicesAnswer . renderOk . map fromDomainHealthcareService

-- A slot is deleted on consumption: Nothing is availableSlotConsumed.
renderFetchAvailableSlotAnswer :: Maybe AvailableSlot -> FetchAvailableSlotAnswer
renderFetchAvailableSlotAnswer found = FetchAvailableSlotAnswer $ case found of
  Just slot -> renderOk (fromDomainAvailableSlot slot)
  Nothing   -> answer availableSlotConsumed NoDetail

renderFetchIntakeRequestAnswer
  :: Either IntakeRequestNotFound IntakeRequest -> FetchIntakeRequestAnswer
renderFetchIntakeRequestAnswer =
  FetchIntakeRequestAnswer . either renderIntakeRequestNotFound (renderOk . fromDomainIntakeRequest)

renderFetchSubmittedIntakeRequestsAnswer
  :: [SubmittedIntakeRequest] -> FetchSubmittedIntakeRequestsAnswer
renderFetchSubmittedIntakeRequestsAnswer =
  FetchSubmittedIntakeRequestsAnswer . renderOk . map fromDomainSubmittedIntakeRequest

renderFetchAcceptedIntakeRequestsAnswer
  :: [TriagedIntakeRequest] -> FetchAcceptedIntakeRequestsAnswer
renderFetchAcceptedIntakeRequestsAnswer =
  FetchAcceptedIntakeRequestsAnswer . renderOk . map fromDomainTriagedIntakeRequest

renderFetchAppointedIntakeRequestsAnswer
  :: [AppointedIntakeRequest] -> FetchAppointedIntakeRequestsAnswer
renderFetchAppointedIntakeRequestsAnswer =
  FetchAppointedIntakeRequestsAnswer . renderOk . map fromDomainAppointedIntakeRequest

renderFetchRejectedIntakeRequestsByRejectedAtAnswer
  :: [RejectedIntakeRequest] -> FetchRejectedIntakeRequestsByRejectedAtAnswer
renderFetchRejectedIntakeRequestsByRejectedAtAnswer =
  FetchRejectedIntakeRequestsByRejectedAtAnswer . renderOk . map fromDomainRejectedIntakeRequest

renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  :: [WithdrawnIntakeRequest] -> FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer =
  FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer . renderOk . map fromDomainWithdrawnIntakeRequest

renderFetchStaleIntakeRequestsByStaleAtAnswer
  :: [StaleIntakeRequest] -> FetchStaleIntakeRequestsByStaleAtAnswer
renderFetchStaleIntakeRequestsByStaleAtAnswer =
  FetchStaleIntakeRequestsByStaleAtAnswer . renderOk . map fromDomainStaleIntakeRequest

renderFetchClosedIntakeRequestsByStartAnswer
  :: [ClosedIntakeRequest] -> FetchClosedIntakeRequestsByStartAnswer
renderFetchClosedIntakeRequestsByStartAnswer =
  FetchClosedIntakeRequestsByStartAnswer . renderOk . map fromDomainClosedIntakeRequest

renderFetchDoctorCalendarEntriesOverlappingAnswer
  :: [DoctorCalendarEntry] -> FetchDoctorCalendarEntriesOverlappingAnswer
renderFetchDoctorCalendarEntriesOverlappingAnswer =
  FetchDoctorCalendarEntriesOverlappingAnswer . renderOk . map fromDomainDoctorCalendarEntry

-- ═══════════════════════════════════════════════════════════════════════════
-- API
-- ═══════════════════════════════════════════════════════════════════════════

type API
  =    DoctorsAPI
  :<|> PatientsAPI
  :<|> HealthcareServicesAPI
  :<|> IntakeRequestsAPI
  :<|> AvailableSlotsAPI
  :<|> DoctorCalendarAPI

server :: ServerT API AppM
server =
       doctorsServer
  :<|> patientsServer
  :<|> healthcareServicesServer
  :<|> intakeRequestsServer
  :<|> availableSlotsServer
  :<|> doctorCalendarServer

-- A half-open range [from, to).
type From = QueryParam' '[Required, Strict] "from" UTCTime
type To   = QueryParam' '[Required, Strict] "to" UTCTime

-- ═══════════════════════════════════════════════════════════════════════════
-- /doctors
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorsAPI = "doctors" :>
  (    ReqBody '[JSON] CreateDoctorRequest :> Post '[JSON] CreateDoctorAnswer
  :<|> Get '[JSON] FetchDoctorsAnswer
  :<|> Capture "doctorId" DoctorIdDTO :> Get '[JSON] FetchDoctorAnswer
  )

doctorsServer :: ServerT DoctorsAPI AppM
doctorsServer = createDoctorH :<|> fetchDoctorsH :<|> fetchDoctorH
  where
    createDoctorH (CreateDoctorRequest name) =
      renderCreateDoctorAnswer <$> withPool (\pool -> S.createDoctor pool name)
    fetchDoctorsH =
      renderFetchDoctorsAnswer <$> withPool S.fetchDoctors
    fetchDoctorH doctorId =
      renderFetchDoctorAnswer <$> withPool (\pool -> S.fetchDoctor pool (toDomainDoctorId doctorId))

-- ═══════════════════════════════════════════════════════════════════════════
-- /patients
-- ═══════════════════════════════════════════════════════════════════════════

type PatientsAPI = "patients" :>
  (    ReqBody '[JSON] CreatePatientRequest :> Post '[JSON] CreatePatientAnswer
  :<|> Get '[JSON] FetchPatientsAnswer
  :<|> Capture "patientId" PatientIdDTO :> Get '[JSON] FetchPatientAnswer
  )

patientsServer :: ServerT PatientsAPI AppM
patientsServer = createPatientH :<|> fetchPatientsH :<|> fetchPatientH
  where
    createPatientH (CreatePatientRequest name) =
      renderCreatePatientAnswer <$> withPool (\pool -> S.createPatient pool name)
    fetchPatientsH =
      renderFetchPatientsAnswer <$> withPool S.fetchPatients
    fetchPatientH patientId =
      renderFetchPatientAnswer <$> withPool (\pool -> S.fetchPatient pool (toDomainPatientId patientId))

-- ═══════════════════════════════════════════════════════════════════════════
-- /healthcare-services
-- ═══════════════════════════════════════════════════════════════════════════

type HealthcareServicesAPI = "healthcare-services" :>
  (    ReqBody '[JSON] CreateHealthcareServiceRequest :> Post '[JSON] CreateHealthcareServiceAnswer
  :<|> Get '[JSON] FetchHealthcareServicesAnswer
  :<|> Capture "healthcareServiceId" HealthcareServiceIdDTO :> Get '[JSON] FetchHealthcareServiceAnswer
  )

healthcareServicesServer :: ServerT HealthcareServicesAPI AppM
healthcareServicesServer = createHealthcareServiceH :<|> fetchHealthcareServicesH :<|> fetchHealthcareServiceH
  where
    createHealthcareServiceH (CreateHealthcareServiceRequest name duration) =
      renderCreateHealthcareServiceAnswer
        <$> withPool (\pool -> S.createHealthcareService pool name (toDomainDuration duration))
    fetchHealthcareServicesH =
      renderFetchHealthcareServicesAnswer <$> withPool S.fetchHealthcareServices
    fetchHealthcareServiceH serviceId =
      renderFetchHealthcareServiceAnswer
        <$> withPool (\pool -> S.fetchHealthcareService pool (toDomainHealthcareServiceId serviceId))

-- ═══════════════════════════════════════════════════════════════════════════
-- /intake-requests
-- Reads by case come before the by-id read, so a case name is never parsed
-- as an id.
-- ═══════════════════════════════════════════════════════════════════════════

type IntakeRequestsAPI = "intake-requests" :>
  (    ReqBody '[JSON] SubmitIntakeRequestRequest :> Post '[JSON] SubmitIntakeRequestAnswer
  :<|> "submitted" :> Get '[JSON] FetchSubmittedIntakeRequestsAnswer
  :<|> "accepted"  :> Get '[JSON] FetchAcceptedIntakeRequestsAnswer
  :<|> "appointed" :> Get '[JSON] FetchAppointedIntakeRequestsAnswer
  :<|> "rejected"  :> From :> To :> Get '[JSON] FetchRejectedIntakeRequestsByRejectedAtAnswer
  :<|> "withdrawn" :> From :> To :> Get '[JSON] FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  :<|> "stale"     :> From :> To :> Get '[JSON] FetchStaleIntakeRequestsByStaleAtAnswer
  :<|> "closed"    :> From :> To :> Get '[JSON] FetchClosedIntakeRequestsByStartAnswer
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

intakeRequestsServer :: ServerT IntakeRequestsAPI AppM
intakeRequestsServer =
       submitH
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
    submitH (SubmitIntakeRequestRequest patientId narrative) = do
      createdAt <- now
      renderSubmitIntakeRequestAnswer <$> withPool (\pool ->
        S.submitIntakeRequest pool (toDomainPatientId patientId) narrative createdAt)
    fetchSubmittedH =
      renderFetchSubmittedIntakeRequestsAnswer <$> withPool S.fetchSubmittedIntakeRequests
    fetchAcceptedH =
      renderFetchAcceptedIntakeRequestsAnswer <$> withPool S.fetchAcceptedIntakeRequests
    fetchAppointedH =
      renderFetchAppointedIntakeRequestsAnswer <$> withPool S.fetchAppointedIntakeRequests
    fetchRejectedH from to =
      renderFetchRejectedIntakeRequestsByRejectedAtAnswer
        <$> withPool (\pool -> S.fetchRejectedIntakeRequestsByRejectedAt pool from to)
    fetchWithdrawnH from to =
      renderFetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
        <$> withPool (\pool -> S.fetchWithdrawnIntakeRequestsByWithdrawnAt pool from to)
    fetchStaleH from to =
      renderFetchStaleIntakeRequestsByStaleAtAnswer
        <$> withPool (\pool -> S.fetchStaleIntakeRequestsByStaleAt pool from to)
    fetchClosedH from to =
      renderFetchClosedIntakeRequestsByStartAnswer
        <$> withPool (\pool -> S.fetchClosedIntakeRequestsByStart pool from to)
    fetchIntakeRequestH requestId =
      renderFetchIntakeRequestAnswer
        <$> withPool (\pool -> S.fetchIntakeRequest pool (toDomainIntakeRequestId requestId))
    acceptH requestId (AcceptSubmittedIntakeRequestRequest serviceId priority doctorRequirement) = do
      triagedAt <- now
      renderAcceptSubmittedIntakeRequestAnswer <$> withPool (\pool ->
        S.acceptSubmittedIntakeRequest pool (toDomainIntakeRequestId requestId)
          (toDomainHealthcareServiceId serviceId)
          (toDomainIntakeRequestPriority priority)
          (toDomainDoctorRequirement doctorRequirement)
          triagedAt)
    rejectH requestId (RejectSubmittedIntakeRequestRequest rejectionReason) = do
      rejectedAt <- now
      renderRejectSubmittedIntakeRequestAnswer <$> withPool (\pool ->
        S.rejectSubmittedIntakeRequest pool (toDomainIntakeRequestId requestId)
          rejectedAt rejectionReason)
    matchToSlotH requestId (MatchAcceptedIntakeRequestToSlotRequest slotId) =
      renderMatchAcceptedIntakeRequestToSlotAnswer <$> withPool (\pool ->
        S.matchAcceptedIntakeRequestToSlot pool (toDomainIntakeRequestId requestId)
          (toDomainSlotId slotId))
    withdrawH requestId (WithdrawIntakeRequestRequest withdrawalNote) = do
      withdrawnAt <- now
      renderWithdrawIntakeRequestAnswer <$> withPool (\pool ->
        S.withdrawIntakeRequest pool (toDomainIntakeRequestId requestId)
          withdrawnAt withdrawalNote)
    markStaleH requestId = do
      staleAt <- now
      renderMarkAcceptedIntakeRequestStaleAnswer <$> withPool (\pool ->
        S.markAcceptedIntakeRequestStale pool (toDomainIntakeRequestId requestId) staleAt)
    closeH requestId (CloseAppointedIntakeRequestRequest closeReason) = do
      cancelledAt <- now
      renderCloseAppointedIntakeRequestAnswer <$> withPool (\pool ->
        S.closeAppointedIntakeRequest pool (toDomainIntakeRequestId requestId)
          (toDomainCloseReasonRequest cancelledAt closeReason))

-- ═══════════════════════════════════════════════════════════════════════════
-- /available-slots
-- ═══════════════════════════════════════════════════════════════════════════

type AvailableSlotsAPI = "available-slots" :>
  (    ReqBody '[JSON] CreateAvailableSlotRequest :> Post '[JSON] CreateAvailableSlotAnswer
  :<|> Capture "slotId" SlotIdDTO :> Get '[JSON] FetchAvailableSlotAnswer
  :<|> Capture "slotId" SlotIdDTO :> "match-by-priority"
         :> Post '[JSON] MatchAvailableSlotByPriorityAnswer
  )

availableSlotsServer :: ServerT AvailableSlotsAPI AppM
availableSlotsServer = createAvailableSlotH :<|> fetchAvailableSlotH :<|> matchByPriorityH
  where
    createAvailableSlotH (CreateAvailableSlotRequest doctorId serviceId start) =
      renderCreateAvailableSlotAnswer <$> withPool (\pool ->
        S.createAvailableSlot pool (toDomainDoctorId doctorId)
          (toDomainHealthcareServiceId serviceId) start)
    fetchAvailableSlotH slotId =
      renderFetchAvailableSlotAnswer <$> withPool (\pool -> S.fetchAvailableSlot pool (toDomainSlotId slotId))
    matchByPriorityH slotId =
      renderMatchAvailableSlotByPriorityAnswer
        <$> withPool (\pool -> S.matchAvailableSlotByPriority pool (toDomainSlotId slotId))

-- ═══════════════════════════════════════════════════════════════════════════
-- /doctor-calendar
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorCalendarAPI = "doctor-calendar" :>
  From :> To :> Get '[JSON] FetchDoctorCalendarEntriesOverlappingAnswer

doctorCalendarServer :: ServerT DoctorCalendarAPI AppM
doctorCalendarServer from to =
  renderFetchDoctorCalendarEntriesOverlappingAnswer
    <$> withPool (\pool -> S.fetchDoctorCalendarEntriesOverlapping pool from to)

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEC, APPLICATION, CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

openApi :: OpenApi
openApi = toOpenApi (Proxy @API)
  & info . title   .~ "triage"
  & info . version .~ "0.1.0.0"

-- The API, plus Swagger UI at /swagger-ui and the spec at /openapi.json.
type App = API :<|> SwaggerSchemaUI "swagger-ui" "openapi.json"

-- The frontend's origin (Vite's dev server).
corsPolicy :: CorsResourcePolicy
corsPolicy = simpleCorsResourcePolicy
  { corsOrigins        = Just (["http://localhost:5173"], False)
  , corsMethods        = ["GET", "POST"]
  , corsRequestHeaders = ["Content-Type"]
  }

app :: ConnectionPool -> Application
app pool =
  cors (const (Just corsPolicy)) $
    serve (Proxy @App) $
      hoistServer (Proxy @API) (toHandler pool) server
        :<|> swaggerSchemaUIServer openApi

-- Only serves; migrations are a separate, manual step.
main :: IO ()
main = do
  dbUrl   <- fromMaybe "postgresql://localhost/triage" <$> lookupEnv "TRIAGE_DB_URL"
  portVar <- lookupEnv "TRIAGE_PORT"
  port    <- case portVar of
    Nothing -> pure 8080
    Just s  -> case readMaybe s of
      Just p | p > 0 && p < 65536 -> pure p
      _                           -> die ("TRIAGE_PORT is not a port number: " <> show s)
  pool <- newPool (defaultPoolConfig (connectPostgreSQL (Text.encodeUtf8 (Text.pack dbUrl))) close 60 10)
  run port (app pool)
