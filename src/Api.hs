{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- Derived from src/Domain.hs and src/Service.hs by the triage-api-codegen
-- skill. One endpoint per public Service function, grouped per resource
-- (one sub-API per table). Handlers parse, supply the current time, call
-- Service and render its answer; nothing else.
module Api
  ( API
  , TriageAPI
  , openApi
  , app
  , main
  ) where

import Control.Exception            (Exception, SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Lens                 ((%~), (&), (.~))
import Control.Monad.IO.Class       (liftIO)
import Control.Monad.Trans.Except   (ExceptT (..))
import Control.Monad.Trans.Reader   (ReaderT, ask, runReaderT)
import Data.Maybe                   (fromMaybe)
import Data.OpenApi                 (OpenApi, allOperations, info, responses, title, version)
import Data.Time                    (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple   (close, connectPostgreSQL)
import Network.Wai.Handler.Warp     (run)
import Network.Wai.Middleware.Cors  (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import Servant
import Servant.OpenApi              (toOpenApi)
import Servant.Swagger.UI           (SwaggerSchemaUI, swaggerSchemaUIServer)
import System.Environment           (lookupEnv)
import System.Exit                  (die)
import System.IO                    (hPutStrLn, stderr)
import Text.Read                    (readMaybe)

import qualified Data.ByteString.Char8      as BS8
import qualified Data.HashMap.Strict.InsOrd as InsOrd
import qualified Data.Pool                  as Pool

import Persistence (ConnectionPool, DecodeError)
import Service
  ( MatchOutcome (..), PriorityMatchOutcome (..), ServiceError (..), SlotCreationOutcome (..)
  , TransitionOutcome (..) )
import Transport

import qualified Service

-- ═══════════════════════════════════════════════════════════════════════════
-- APP MONAD
-- ═══════════════════════════════════════════════════════════════════════════

type AppM = ReaderT ConnectionPool Handler

-- The time an action is recorded.
now :: AppM UTCTime
now = liftIO getCurrentTime

-- Runs a Service function with the pool.
service :: (ConnectionPool -> IO a) -> AppM a
service call = ask >>= liftIO . call

type Range a = QueryParam' '[Required, Strict] "from" UTCTime
            :> QueryParam' '[Required, Strict] "to"   UTCTime
            :> Get '[JSON] a

-- ═══════════════════════════════════════════════════════════════════════════
-- RENDERING ANSWERS
-- One exhaustive function per Service answer type, shared by every handler
-- that returns it. Only a decode failure leaves the 200 envelope.
-- ═══════════════════════════════════════════════════════════════════════════

internalError :: ServerError
internalError = err500
  { errBody    = "Internal server error"
  , errHeaders = [("Content-Type", "text/plain; charset=utf-8")]
  }

-- A stored row no Domain value can be built from: raised so that toHandler,
-- the one place every 500 passes through, logs it.
newtype DecodeFailure = DecodeFailure DecodeError
  deriving Show

instance Exception DecodeFailure

renderServiceError :: ServiceError -> AppM ServiceErrorDTO
renderServiceError = \case
  DecodeFailed err              -> liftIO (throwIO (DecodeFailure err))
  DoctorNotFound d              -> pure (DoctorNotFoundDTO (fromDomainDoctorId d))
  PatientNotFound p             -> pure (PatientNotFoundDTO (fromDomainPatientId p))
  HealthcareServiceNotFound s   -> pure (HealthcareServiceNotFoundDTO (fromDomainHealthcareServiceId s))
  IntakeRequestNotFound r       -> pure (IntakeRequestNotFoundDTO (fromDomainIntakeRequestId r))
  IntakeRequestInWrongState r   -> pure (IntakeRequestInWrongStateDTO (fromDomainIntakeRequest r))
  SlotDoesNotMatchIntakeRequest -> pure SlotDoesNotMatchIntakeRequestDTO

renderResult :: (a -> b) -> Either ServiceError a -> AppM (Either ServiceErrorDTO b)
renderResult render = \case
  Left err -> Left <$> renderServiceError err
  Right a  -> pure (Right (render a))

renderTransitionOutcome :: (a -> b) -> TransitionOutcome a -> TransitionOutcomeDTO b
renderTransitionOutcome render = \case
  Transitioned a -> TransitionedDTO (render a)
  MovedOn r      -> MovedOnDTO (fromDomainIntakeRequest r)

renderMatchOutcome :: MatchOutcome -> MatchOutcomeDTO
renderMatchOutcome = \case
  Matched a               -> MatchedDTO (fromDomainAppointedIntakeRequest a)
  AvailableSlotConsumed   -> AvailableSlotConsumedDTO
  IntakeRequestMovedOn r  -> IntakeRequestMovedOnDTO (fromDomainIntakeRequest r)

renderPriorityMatchOutcome :: PriorityMatchOutcome -> PriorityMatchOutcomeDTO
renderPriorityMatchOutcome = \case
  NoMatchingIntakeRequest -> NoMatchingIntakeRequestDTO
  MatchAttempted m        -> MatchAttemptedDTO (renderMatchOutcome m)

renderSlotCreationOutcome :: SlotCreationOutcome -> SlotCreationOutcomeDTO
renderSlotCreationOutcome = \case
  SlotCreated s              -> SlotCreatedDTO (fromDomainAvailableSlot s)
  SlotOverlapsDoctorCalendar -> SlotOverlapsDoctorCalendarDTO

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
    createDoctorH :: CreateDoctorRequest -> AppM CreateDoctorAnswer
    createDoctorH body =
      Answer . Ok . fromDomainDoctor <$> service (\pool -> Service.createDoctor pool body.name)

    fetchDoctorsH :: AppM FetchDoctorsAnswer
    fetchDoctorsH =
      Answer . Ok . map fromDomainDoctor <$> service Service.fetchDoctors

    fetchDoctorH :: DoctorIdDTO -> AppM FetchDoctorAnswer
    fetchDoctorH doctor =
      service (\pool -> Service.fetchDoctor pool (toDomainDoctorId doctor))
        >>= fmap Answer . renderResult (Ok . fromDomainDoctor)

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
    createPatientH :: CreatePatientRequest -> AppM CreatePatientAnswer
    createPatientH body =
      Answer . Ok . fromDomainPatient <$> service (\pool -> Service.createPatient pool body.name)

    fetchPatientsH :: AppM FetchPatientsAnswer
    fetchPatientsH =
      Answer . Ok . map fromDomainPatient <$> service Service.fetchPatients

    fetchPatientH :: PatientIdDTO -> AppM FetchPatientAnswer
    fetchPatientH patient =
      service (\pool -> Service.fetchPatient pool (toDomainPatientId patient))
        >>= fmap Answer . renderResult (Ok . fromDomainPatient)

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
    createHealthcareServiceH :: CreateHealthcareServiceRequest -> AppM CreateHealthcareServiceAnswer
    createHealthcareServiceH body =
      Answer . Ok . fromDomainHealthcareService
        <$> service (\pool ->
              Service.createHealthcareService pool body.name (toDomainDuration body.duration))

    fetchHealthcareServicesH :: AppM FetchHealthcareServicesAnswer
    fetchHealthcareServicesH =
      service Service.fetchHealthcareServices
        >>= fmap Answer . renderResult (Ok . map fromDomainHealthcareService)

    fetchHealthcareServiceH :: HealthcareServiceIdDTO -> AppM FetchHealthcareServiceAnswer
    fetchHealthcareServiceH serviceId =
      service (\pool -> Service.fetchHealthcareService pool (toDomainHealthcareServiceId serviceId))
        >>= fmap Answer . renderResult (Ok . fromDomainHealthcareService)

-- ═══════════════════════════════════════════════════════════════════════════
-- /intake-requests
-- Fixed segments come before the {intakeRequestId} capture.
-- ═══════════════════════════════════════════════════════════════════════════

type IntakeRequestsAPI = "intake-requests" :>
  (    ReqBody '[JSON] SubmitIntakeRequestRequest :> Post '[JSON] SubmitIntakeRequestAnswer
  :<|> "submitted" :> Get '[JSON] FetchSubmittedIntakeRequestsAnswer
  :<|> "accepted"  :> Get '[JSON] FetchAcceptedIntakeRequestsAnswer
  :<|> "appointed" :> Get '[JSON] FetchAppointedIntakeRequestsAnswer
  :<|> "rejected"  :> Range FetchRejectedIntakeRequestsByRejectedAtAnswer
  :<|> "withdrawn" :> Range FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  :<|> "stale"     :> Range FetchStaleIntakeRequestsByStaleAtAnswer
  :<|> "closed"    :> Range FetchClosedIntakeRequestsByStartAnswer
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
    submitIntakeRequestH :: SubmitIntakeRequestRequest -> AppM SubmitIntakeRequestAnswer
    submitIntakeRequestH body = do
      recordedAt <- now
      service (\pool ->
          Service.submitIntakeRequest pool (toDomainPatientId body.patientId) body.narrative recordedAt)
        >>= fmap Answer . renderResult (Ok . fromDomainSubmittedIntakeRequest)

    fetchSubmittedH :: AppM FetchSubmittedIntakeRequestsAnswer
    fetchSubmittedH =
      service Service.fetchSubmittedIntakeRequests
        >>= fmap Answer . renderResult (Ok . map fromDomainSubmittedIntakeRequest)

    fetchAcceptedH :: AppM FetchAcceptedIntakeRequestsAnswer
    fetchAcceptedH =
      service Service.fetchAcceptedIntakeRequests
        >>= fmap Answer . renderResult (Ok . map fromDomainTriagedIntakeRequest)

    fetchAppointedH :: AppM FetchAppointedIntakeRequestsAnswer
    fetchAppointedH =
      service Service.fetchAppointedIntakeRequests
        >>= fmap Answer . renderResult (Ok . map fromDomainAppointedIntakeRequest)

    fetchRejectedH :: UTCTime -> UTCTime -> AppM FetchRejectedIntakeRequestsByRejectedAtAnswer
    fetchRejectedH from to =
      service (\pool -> Service.fetchRejectedIntakeRequestsByRejectedAt pool from to)
        >>= fmap Answer . renderResult (Ok . map fromDomainRejectedIntakeRequest)

    fetchWithdrawnH :: UTCTime -> UTCTime -> AppM FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
    fetchWithdrawnH from to =
      service (\pool -> Service.fetchWithdrawnIntakeRequestsByWithdrawnAt pool from to)
        >>= fmap Answer . renderResult (Ok . map fromDomainWithdrawnIntakeRequest)

    fetchStaleH :: UTCTime -> UTCTime -> AppM FetchStaleIntakeRequestsByStaleAtAnswer
    fetchStaleH from to =
      service (\pool -> Service.fetchStaleIntakeRequestsByStaleAt pool from to)
        >>= fmap Answer . renderResult (Ok . map fromDomainStaleIntakeRequest)

    fetchClosedH :: UTCTime -> UTCTime -> AppM FetchClosedIntakeRequestsByStartAnswer
    fetchClosedH from to =
      service (\pool -> Service.fetchClosedIntakeRequestsByStart pool from to)
        >>= fmap Answer . renderResult (Ok . map fromDomainClosedIntakeRequest)

    fetchIntakeRequestH :: IntakeRequestIdDTO -> AppM FetchIntakeRequestAnswer
    fetchIntakeRequestH requestId =
      service (\pool -> Service.fetchIntakeRequest pool (toDomainIntakeRequestId requestId))
        >>= fmap Answer . renderResult (Ok . fromDomainIntakeRequest)

    acceptH :: IntakeRequestIdDTO -> AcceptSubmittedIntakeRequestRequest
            -> AppM AcceptSubmittedIntakeRequestAnswer
    acceptH requestId body = do
      recordedAt <- now
      service (\pool ->
          Service.acceptSubmittedIntakeRequest pool
            (toDomainIntakeRequestId requestId)
            (toDomainHealthcareServiceId body.healthcareServiceId)
            (toDomainIntakeRequestPriority body.priority)
            (toDomainDoctorRequirement body.doctorRequirement)
            recordedAt)
        >>= fmap Answer . renderResult (renderTransitionOutcome fromDomainTriagedIntakeRequest)

    rejectH :: IntakeRequestIdDTO -> RejectSubmittedIntakeRequestRequest
            -> AppM RejectSubmittedIntakeRequestAnswer
    rejectH requestId body = do
      recordedAt <- now
      service (\pool ->
          Service.rejectSubmittedIntakeRequest pool
            (toDomainIntakeRequestId requestId) recordedAt body.rejectionReason)
        >>= fmap Answer . renderResult (renderTransitionOutcome fromDomainRejectedIntakeRequest)

    matchToSlotH :: IntakeRequestIdDTO -> MatchAcceptedIntakeRequestToSlotRequest
                 -> AppM MatchAcceptedIntakeRequestToSlotAnswer
    matchToSlotH requestId body =
      service (\pool ->
          Service.matchAcceptedIntakeRequestToSlot pool
            (toDomainIntakeRequestId requestId) (toDomainSlotId body.slotId))
        >>= fmap Answer . renderResult renderMatchOutcome

    withdrawH :: IntakeRequestIdDTO -> WithdrawIntakeRequestRequest -> AppM WithdrawIntakeRequestAnswer
    withdrawH requestId body = do
      recordedAt <- now
      service (\pool ->
          Service.withdrawIntakeRequest pool
            (toDomainIntakeRequestId requestId) recordedAt body.withdrawalNote)
        >>= fmap Answer . renderResult (renderTransitionOutcome fromDomainWithdrawnIntakeRequest)

    markStaleH :: IntakeRequestIdDTO -> AppM MarkAcceptedIntakeRequestStaleAnswer
    markStaleH requestId = do
      recordedAt <- now
      service (\pool ->
          Service.markAcceptedIntakeRequestStale pool (toDomainIntakeRequestId requestId) recordedAt)
        >>= fmap Answer . renderResult (renderTransitionOutcome fromDomainStaleIntakeRequest)

    closeH :: IntakeRequestIdDTO -> CloseAppointedIntakeRequestRequest
           -> AppM CloseAppointedIntakeRequestAnswer
    closeH requestId body = do
      recordedAt <- now
      service (\pool ->
          Service.closeAppointedIntakeRequest pool
            (toDomainIntakeRequestId requestId) (requestedCloseReason recordedAt body.closeReason))
        >>= fmap Answer . renderResult (renderTransitionOutcome fromDomainClosedIntakeRequest)

-- ═══════════════════════════════════════════════════════════════════════════
-- /available-slots
-- ═══════════════════════════════════════════════════════════════════════════

type AvailableSlotsAPI = "available-slots" :>
  (    ReqBody '[JSON] CreateAvailableSlotRequest :> Post '[JSON] CreateAvailableSlotAnswer
  :<|> Capture "slotId" SlotIdDTO :> Get '[JSON] FetchAvailableSlotAnswer
  :<|> Capture "slotId" SlotIdDTO :> "match-by-priority" :> Post '[JSON] MatchAvailableSlotByPriorityAnswer
  )

availableSlotsServer :: ServerT AvailableSlotsAPI AppM
availableSlotsServer = createAvailableSlotH :<|> fetchAvailableSlotH :<|> matchByPriorityH
  where
    createAvailableSlotH :: CreateAvailableSlotRequest -> AppM CreateAvailableSlotAnswer
    createAvailableSlotH body =
      service (\pool ->
          Service.createAvailableSlot pool
            (toDomainDoctorId body.doctorId)
            (toDomainHealthcareServiceId body.healthcareServiceId)
            body.start)
        >>= fmap Answer . renderResult renderSlotCreationOutcome

    fetchAvailableSlotH :: SlotIdDTO -> AppM FetchAvailableSlotAnswer
    fetchAvailableSlotH slot =
      service (\pool -> Service.fetchAvailableSlot pool (toDomainSlotId slot))
        >>= fmap Answer . renderResult (fmap fromDomainAvailableSlot)

    matchByPriorityH :: SlotIdDTO -> AppM MatchAvailableSlotByPriorityAnswer
    matchByPriorityH slot =
      service (\pool -> Service.matchAvailableSlotByPriority pool (toDomainSlotId slot))
        >>= fmap Answer . renderResult renderPriorityMatchOutcome

-- ═══════════════════════════════════════════════════════════════════════════
-- /doctor-calendar
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorCalendarAPI = "doctor-calendar" :> Range FetchDoctorCalendarEntriesOverlappingAnswer

doctorCalendarServer :: ServerT DoctorCalendarAPI AppM
doctorCalendarServer from to =
  service (\pool -> Service.fetchDoctorCalendarEntriesOverlapping pool from to)
    >>= fmap Answer . renderResult (Ok . map fromDomainDoctorCalendarEntry)

-- ═══════════════════════════════════════════════════════════════════════════
-- API, SPEC, SERVER
-- ═══════════════════════════════════════════════════════════════════════════

type TriageAPI =
       DoctorsAPI
  :<|> PatientsAPI
  :<|> HealthcareServicesAPI
  :<|> IntakeRequestsAPI
  :<|> AvailableSlotsAPI
  :<|> DoctorCalendarAPI

-- The spec at /openapi.json, and Swagger UI reading it at /swagger-ui.
type API = TriageAPI :<|> SwaggerSchemaUI "swagger-ui" "openapi.json"

-- servant-openapi3 documents a 404 for every capture; an id that doesn't
-- exist is a 200 with its not-found answer, so those entries are removed.
openApi :: OpenApi
openApi = toOpenApi (Proxy @TriageAPI)
  & info . title   .~ "triage"
  & info . version .~ "0.1.0.0"
  & allOperations . responses . responses %~ InsOrd.delete 404

triageServer :: ServerT TriageAPI AppM
triageServer =
       doctorsServer
  :<|> patientsServer
  :<|> healthcareServicesServer
  :<|> intakeRequestsServer
  :<|> availableSlotsServer
  :<|> doctorCalendarServer

-- Every 500 passes through here: the cause goes to stderr, the client gets
-- the plain internalError body.
toHandler :: ConnectionPool -> AppM a -> Handler a
toHandler pool m = Handler . ExceptT $ do
  result <- try (runHandler (runReaderT m pool))
  case result of
    Right r -> pure r
    Left (e :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> do
          hPutStrLn stderr ("triage-server: " <> show e)
          pure (Left internalError)

app :: ConnectionPool -> Application
app pool = serve (Proxy @API) $
       hoistServer (Proxy @TriageAPI) (toHandler pool) triageServer
  :<|> swaggerSchemaUIServer openApi

-- The frontend's origin (Vite's dev server).
corsPolicy :: CorsResourcePolicy
corsPolicy = simpleCorsResourcePolicy
  { corsOrigins        = Just (["http://localhost:5173"], False)
  , corsMethods        = ["GET", "POST"]
  , corsRequestHeaders = ["Content-Type"]
  }

-- Serves only: migrations are a separate, manual step.
main :: IO ()
main = do
  dbUrl <- fromMaybe "postgresql://localhost/triage" <$> lookupEnv "TRIAGE_DB_URL"
  port  <- lookupEnv "TRIAGE_PORT" >>= \case
    Nothing  -> pure 8080
    Just raw -> maybe (die ("TRIAGE_PORT is not a port number: " <> raw)) pure (readMaybe raw)
  pool <- Pool.newPool (Pool.defaultPoolConfig (connectPostgreSQL (BS8.pack dbUrl)) close 60 10)
  run port (cors (const (Just corsPolicy)) (app pool))
