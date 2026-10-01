{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

-- Derived from src/Domain.hs and src/Service.hs by the triage-api-codegen
-- skill: one REST endpoint per public Service function. Handlers parse,
-- supply the current time, call Service and render its answer; nothing
-- else. Every 200 body is {"outcome": <tag>, "detail": <payload or null>}.
module Api
  ( API
  , api
  , swaggerDoc
  , main
  ) where

import Control.Exception          (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Lens               ((&), (.~), (?~))
import Control.Monad.IO.Class     (liftIO)
import Control.Monad.Trans.Except (ExceptT (..))
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.Aeson                 (ToJSON (..), Value (..), object, (.=))
import Data.Maybe                 (fromMaybe)
import Data.Pool                  (defaultPoolConfig, newPool)
import Data.Swagger
  ( Definitions, NamedSchema (..), Referenced (..), Schema, Swagger, SwaggerType (..)
  , Reference (..), ToSchema (..), declareSchemaRef, description, enum_, info, properties, required
  , schemaName, title, type_, version )
import Data.Swagger.Declare       (Declare, declare)
import Data.Text                  (Text)
import Data.Time                  (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (close, connectPostgreSQL)
import GHC.Exts                   (fromList)
import GHC.TypeLits               (KnownSymbol, Symbol, symbolVal)
import Network.Wai                (Middleware)
import Network.Wai.Handler.Warp   (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..), cors, simpleCorsResourcePolicy )
import Servant
import Servant.Swagger            (toSwagger)
import Servant.Swagger.UI         (SwaggerSchemaUI, swaggerSchemaUIServer)
import System.Environment         (lookupEnv)
import System.IO                  (hPutStrLn, stderr)
import Text.Read                  (readMaybe)

import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text             as Text

import Domain
import Persistence (ConnectionPool)
import Service
import Transport

-- ═══════════════════════════════════════════════════════════════════════════
-- ANSWERS
-- The envelope, one rendering function per Service answer type (exhaustive,
-- no wildcard), and each endpoint's response schema.
-- ═══════════════════════════════════════════════════════════════════════════

data Envelope = Envelope Text (Maybe Value)

envelopeValue :: Envelope -> Value
envelopeValue (Envelope outcome detail) = object ["outcome" .= outcome, "detail" .= detail]

-- A plain value with no constructor of its own.
ok :: ToJSON a => a -> Envelope
ok = Envelope "ok" . Just . toJSON

tagged :: ToJSON a => Text -> a -> Envelope
tagged outcome = Envelope outcome . Just . toJSON

bare :: Text -> Envelope
bare outcome = Envelope outcome Nothing

-- The body of one endpoint's 200 response, named after its Service function.
newtype Answer (useCase :: Symbol) = Answer Envelope

instance ToJSON (Answer useCase) where
  toJSON (Answer e) = envelopeValue e

-- Only a decode failure is outside the domain's vocabulary: a 500.
renderServiceError :: ServiceError -> AppM Envelope
renderServiceError e = case e of
  DecodeFailed _                  -> throwError internalError
  DoctorNotFound i                -> pure (tagged "doctorNotFound" (fromDomainDoctorId i))
  PatientNotFound i               -> pure (tagged "patientNotFound" (fromDomainPatientId i))
  HealthcareServiceNotFound i     ->
    pure (tagged "healthcareServiceNotFound" (fromDomainHealthcareServiceId i))
  IntakeRequestNotFound i         ->
    pure (tagged "intakeRequestNotFound" (fromDomainIntakeRequestId i))
  IntakeRequestInWrongState r     ->
    pure (tagged "intakeRequestInWrongState" (fromDomainIntakeRequest r))
  SlotDoesNotMatchIntakeRequest   -> pure (bare "slotDoesNotMatchIntakeRequest")

renderTransitionOutcome :: ToJSON dto => (a -> dto) -> TransitionOutcome a -> Envelope
renderTransitionOutcome render outcome = case outcome of
  Transitioned a -> tagged "transitioned" (render a)
  MovedOn r      -> tagged "movedOn" (fromDomainIntakeRequest r)

renderMatchOutcome :: MatchOutcome -> Envelope
renderMatchOutcome outcome = case outcome of
  Matched a              -> tagged "matched" (fromDomainAppointedIntakeRequest a)
  AvailableSlotConsumed  -> bare "availableSlotConsumed"
  IntakeRequestMovedOn r -> tagged "intakeRequestMovedOn" (fromDomainIntakeRequest r)

renderPriorityMatchOutcome :: PriorityMatchOutcome -> Envelope
renderPriorityMatchOutcome outcome = case outcome of
  NoMatchingIntakeRequest -> bare "noMatchingIntakeRequest"
  MatchAttempted m        -> Envelope "matchAttempted" (Just (envelopeValue (renderMatchOutcome m)))

renderSlotCreationOutcome :: SlotCreationOutcome -> Envelope
renderSlotCreationOutcome outcome = case outcome of
  SlotCreated s              -> tagged "slotCreated" (fromDomainAvailableSlot s)
  SlotOverlapsDoctorCalendar -> bare "slotOverlapsDoctorCalendar"

-- A slot is deleted on consumption: Nothing is the same fact as Service's
-- AvailableSlotConsumed.
renderAvailableSlotRead :: Maybe AvailableSlot -> Envelope
renderAvailableSlotRead found = case found of
  Just s  -> ok (fromDomainAvailableSlot s)
  Nothing -> bare "availableSlotConsumed"

answered :: (a -> Envelope) -> Either ServiceError a -> AppM (Answer useCase)
answered render = fmap Answer . either renderServiceError (pure . render)

answer :: Envelope -> AppM (Answer useCase)
answer = pure . Answer

-- ── Response schemas ────────────────────────────────────────────────────
-- Swagger 2.0 cannot tie "detail"'s type to "outcome", so each endpoint's
-- schema lists its tags as an enum, declares every payload's schema, and
-- names the payload of each tag in "detail"'s description.

type Decl = Declare (Definitions Schema)

data Payload = Payload Text (Decl (Referenced Schema))

data AnswerCase = AnswerCase Text (Maybe Payload)

one :: forall a. ToSchema a => Proxy a -> Maybe Payload
one p = Just (Payload (fromMaybe "value" (schemaName p)) (declareSchemaRef p))

many :: forall a. (ToSchema a, ToSchema [a]) => Proxy a -> Maybe Payload
many p = Just (Payload ("array of " <> fromMaybe "value" (schemaName p)) (declareSchemaRef (Proxy @[a])))

okCase :: Maybe Payload -> [AnswerCase]
okCase p = [AnswerCase "ok" p]

serviceErrorCases :: [AnswerCase]
serviceErrorCases =
  [ AnswerCase "doctorNotFound" (one (Proxy @DoctorIdDTO))
  , AnswerCase "patientNotFound" (one (Proxy @PatientIdDTO))
  , AnswerCase "healthcareServiceNotFound" (one (Proxy @HealthcareServiceIdDTO))
  , AnswerCase "intakeRequestNotFound" (one (Proxy @IntakeRequestIdDTO))
  , AnswerCase "intakeRequestInWrongState" (one (Proxy @IntakeRequestDTO))
  , AnswerCase "slotDoesNotMatchIntakeRequest" Nothing
  ]

transitionCases :: ToSchema dto => Proxy dto -> [AnswerCase]
transitionCases p =
  [ AnswerCase "transitioned" (one p)
  , AnswerCase "movedOn" (one (Proxy @IntakeRequestDTO))
  ]

matchOutcomeCases :: [AnswerCase]
matchOutcomeCases =
  [ AnswerCase "matched" (one (Proxy @AppointedIntakeRequestDTO))
  , AnswerCase "availableSlotConsumed" Nothing
  , AnswerCase "intakeRequestMovedOn" (one (Proxy @IntakeRequestDTO))
  ]

priorityMatchOutcomeCases :: [AnswerCase]
priorityMatchOutcomeCases =
  [ AnswerCase "noMatchingIntakeRequest" Nothing
  , AnswerCase "matchAttempted"
      (Just (Payload "MatchOutcome" (declareAnswer "MatchOutcome" matchOutcomeCases)))
  ]

slotCreationOutcomeCases :: [AnswerCase]
slotCreationOutcomeCases =
  [ AnswerCase "slotCreated" (one (Proxy @AvailableSlotDTO))
  , AnswerCase "slotOverlapsDoctorCalendar" Nothing
  ]

availableSlotReadCases :: [AnswerCase]
availableSlotReadCases =
  [ AnswerCase "ok" (one (Proxy @AvailableSlotDTO))
  , AnswerCase "availableSlotConsumed" Nothing
  ]

answerSchema :: [AnswerCase] -> Decl Schema
answerSchema cases = do
  described <- traverse describe cases
  let outcomeSchema = mempty & type_ ?~ SwaggerString & enum_ ?~ [String t | AnswerCase t _ <- cases]
      detailSchema  = mempty & description ?~
        ("By outcome: " <> Text.intercalate "; " described)
  pure $ mempty
    & type_ ?~ SwaggerObject
    & properties .~ fromList [("outcome", Inline outcomeSchema), ("detail", Inline detailSchema)]
    & required .~ ["outcome", "detail"]
  where
    describe (AnswerCase t Nothing)                = pure (t <> ": null")
    describe (AnswerCase t (Just (Payload n decl))) = (t <> ": " <> n) <$ decl

-- A nested envelope, declared once under its answer type's name.
declareAnswer :: Text -> [AnswerCase] -> Decl (Referenced Schema)
declareAnswer answerName cases = do
  s <- answerSchema cases
  declare (fromList [(answerName, s)])
  pure (Ref (Reference answerName))

class KnownSymbol useCase => AnswerCases (useCase :: Symbol) where
  answerCases :: Proxy useCase -> [AnswerCase]

instance AnswerCases useCase => ToSchema (Answer useCase) where
  declareNamedSchema _ =
    NamedSchema (Just (capitalize (symbolVal (Proxy @useCase)) <> "Answer"))
      <$> answerSchema (answerCases (Proxy @useCase))
    where
      capitalize s = Text.toUpper (Text.take 1 (Text.pack s)) <> Text.drop 1 (Text.pack s)

orError :: [AnswerCase] -> [AnswerCase]
orError cases = cases <> serviceErrorCases

instance AnswerCases "createDoctor" where answerCases _ = okCase (one (Proxy @DoctorDTO))
instance AnswerCases "fetchDoctors" where answerCases _ = okCase (many (Proxy @DoctorDTO))
instance AnswerCases "fetchDoctor" where answerCases _ = orError (okCase (one (Proxy @DoctorDTO)))
instance AnswerCases "createPatient" where answerCases _ = okCase (one (Proxy @PatientDTO))
instance AnswerCases "fetchPatients" where answerCases _ = okCase (many (Proxy @PatientDTO))
instance AnswerCases "fetchPatient" where answerCases _ = orError (okCase (one (Proxy @PatientDTO)))
instance AnswerCases "createHealthcareService" where
  answerCases _ = okCase (one (Proxy @HealthcareServiceDTO))
instance AnswerCases "fetchHealthcareServices" where
  answerCases _ = orError (okCase (many (Proxy @HealthcareServiceDTO)))
instance AnswerCases "fetchHealthcareService" where
  answerCases _ = orError (okCase (one (Proxy @HealthcareServiceDTO)))
instance AnswerCases "submitIntakeRequest" where
  answerCases _ = orError (okCase (one (Proxy @SubmittedIntakeRequestDTO)))
instance AnswerCases "acceptSubmittedIntakeRequest" where
  answerCases _ = orError (transitionCases (Proxy @TriagedIntakeRequestDTO))
instance AnswerCases "rejectSubmittedIntakeRequest" where
  answerCases _ = orError (transitionCases (Proxy @RejectedIntakeRequestDTO))
instance AnswerCases "matchAcceptedIntakeRequestToSlot" where
  answerCases _ = orError matchOutcomeCases
instance AnswerCases "withdrawIntakeRequest" where
  answerCases _ = orError (transitionCases (Proxy @WithdrawnIntakeRequestDTO))
instance AnswerCases "markAcceptedIntakeRequestStale" where
  answerCases _ = orError (transitionCases (Proxy @StaleIntakeRequestDTO))
instance AnswerCases "closeAppointedIntakeRequest" where
  answerCases _ = orError (transitionCases (Proxy @ClosedIntakeRequestDTO))
instance AnswerCases "fetchIntakeRequest" where
  answerCases _ = orError (okCase (one (Proxy @IntakeRequestDTO)))
instance AnswerCases "fetchSubmittedIntakeRequests" where
  answerCases _ = orError (okCase (many (Proxy @SubmittedIntakeRequestDTO)))
instance AnswerCases "fetchAcceptedIntakeRequests" where
  answerCases _ = orError (okCase (many (Proxy @TriagedIntakeRequestDTO)))
instance AnswerCases "fetchAppointedIntakeRequests" where
  answerCases _ = orError (okCase (many (Proxy @AppointedIntakeRequestDTO)))
instance AnswerCases "fetchRejectedIntakeRequestsByRejectedAt" where
  answerCases _ = orError (okCase (many (Proxy @RejectedIntakeRequestDTO)))
instance AnswerCases "fetchWithdrawnIntakeRequestsByWithdrawnAt" where
  answerCases _ = orError (okCase (many (Proxy @WithdrawnIntakeRequestDTO)))
instance AnswerCases "fetchStaleIntakeRequestsByStaleAt" where
  answerCases _ = orError (okCase (many (Proxy @StaleIntakeRequestDTO)))
instance AnswerCases "fetchClosedIntakeRequestsByStart" where
  answerCases _ = orError (okCase (many (Proxy @ClosedIntakeRequestDTO)))
instance AnswerCases "createAvailableSlot" where
  answerCases _ = orError slotCreationOutcomeCases
instance AnswerCases "fetchAvailableSlot" where
  answerCases _ = orError availableSlotReadCases
instance AnswerCases "matchAvailableSlotByPriority" where
  answerCases _ = orError priorityMatchOutcomeCases
instance AnswerCases "fetchDoctorCalendarEntriesOverlapping" where
  answerCases _ = orError (okCase (many (Proxy @DoctorCalendarEntryDTO)))

-- ═══════════════════════════════════════════════════════════════════════════
-- HANDLER MONAD
-- ═══════════════════════════════════════════════════════════════════════════

type AppM = ReaderT ConnectionPool Handler

withPool :: (ConnectionPool -> IO a) -> AppM a
withPool f = ask >>= liftIO . f

now :: AppM UTCTime
now = liftIO getCurrentTime

-- A plain-text 500 that exposes no internals.
internalError :: ServerError
internalError = err500
  { errBody    = "Internal server error"
  , errHeaders = [("Content-Type", "text/plain; charset=utf-8")]
  }

-- Supplies the pool once; anything unexpected (a database failure) becomes
-- the same plain 500, logged to stderr.
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

type Range a = QueryParam' '[Required, Strict] "from" UTCTime
            :> QueryParam' '[Required, Strict] "to" UTCTime
            :> a

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTORS
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorsAPI = "doctors" :>
  (    ReqBody '[JSON] CreateDoctorRequest :> Post '[JSON] (Answer "createDoctor")
  :<|> Get '[JSON] (Answer "fetchDoctors")
  :<|> Capture "doctorId" DoctorIdDTO :> Get '[JSON] (Answer "fetchDoctor")
  )

doctorsServer :: ServerT DoctorsAPI AppM
doctorsServer = createDoctorHandler :<|> fetchDoctorsHandler :<|> fetchDoctorHandler
  where
    createDoctorHandler req =
      withPool (\p -> createDoctor p req.name) >>= answer . ok . fromDomainDoctor
    fetchDoctorsHandler =
      withPool fetchDoctors >>= answer . ok . map fromDomainDoctor
    fetchDoctorHandler doctorIdDTO =
      withPool (\p -> fetchDoctor p (toDomainDoctorId doctorIdDTO))
        >>= answered (ok . fromDomainDoctor)

-- ═══════════════════════════════════════════════════════════════════════════
-- PATIENTS
-- ═══════════════════════════════════════════════════════════════════════════

type PatientsAPI = "patients" :>
  (    ReqBody '[JSON] CreatePatientRequest :> Post '[JSON] (Answer "createPatient")
  :<|> Get '[JSON] (Answer "fetchPatients")
  :<|> Capture "patientId" PatientIdDTO :> Get '[JSON] (Answer "fetchPatient")
  )

patientsServer :: ServerT PatientsAPI AppM
patientsServer = createPatientHandler :<|> fetchPatientsHandler :<|> fetchPatientHandler
  where
    createPatientHandler req =
      withPool (\p -> createPatient p req.name) >>= answer . ok . fromDomainPatient
    fetchPatientsHandler =
      withPool fetchPatients >>= answer . ok . map fromDomainPatient
    fetchPatientHandler patientIdDTO =
      withPool (\p -> fetchPatient p (toDomainPatientId patientIdDTO))
        >>= answered (ok . fromDomainPatient)

-- ═══════════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICES
-- ═══════════════════════════════════════════════════════════════════════════

type HealthcareServicesAPI = "healthcare-services" :>
  (    ReqBody '[JSON] CreateHealthcareServiceRequest
         :> Post '[JSON] (Answer "createHealthcareService")
  :<|> Get '[JSON] (Answer "fetchHealthcareServices")
  :<|> Capture "healthcareServiceId" HealthcareServiceIdDTO
         :> Get '[JSON] (Answer "fetchHealthcareService")
  )

healthcareServicesServer :: ServerT HealthcareServicesAPI AppM
healthcareServicesServer =
  createHealthcareServiceHandler :<|> fetchHealthcareServicesHandler :<|> fetchHealthcareServiceHandler
  where
    createHealthcareServiceHandler req =
      withPool (\p -> createHealthcareService p req.name (toDomainDuration req.duration))
        >>= answer . ok . fromDomainHealthcareService
    fetchHealthcareServicesHandler =
      withPool fetchHealthcareServices >>= answered (ok . map fromDomainHealthcareService)
    fetchHealthcareServiceHandler serviceId =
      withPool (\p -> fetchHealthcareService p (toDomainHealthcareServiceId serviceId))
        >>= answered (ok . fromDomainHealthcareService)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUESTS
-- ═══════════════════════════════════════════════════════════════════════════

type IntakeRequestsAPI = "intake-requests" :>
  (    ReqBody '[JSON] SubmitIntakeRequestRequest :> Post '[JSON] (Answer "submitIntakeRequest")
  :<|> "submitted" :> Get '[JSON] (Answer "fetchSubmittedIntakeRequests")
  :<|> "accepted" :> Get '[JSON] (Answer "fetchAcceptedIntakeRequests")
  :<|> "appointed" :> Get '[JSON] (Answer "fetchAppointedIntakeRequests")
  :<|> "rejected" :> Range (Get '[JSON] (Answer "fetchRejectedIntakeRequestsByRejectedAt"))
  :<|> "withdrawn" :> Range (Get '[JSON] (Answer "fetchWithdrawnIntakeRequestsByWithdrawnAt"))
  :<|> "stale" :> Range (Get '[JSON] (Answer "fetchStaleIntakeRequestsByStaleAt"))
  :<|> "closed" :> Range (Get '[JSON] (Answer "fetchClosedIntakeRequestsByStart"))
  :<|> Capture "intakeRequestId" IntakeRequestIdDTO :>
         (    Get '[JSON] (Answer "fetchIntakeRequest")
         :<|> "accept" :> ReqBody '[JSON] AcceptSubmittedIntakeRequestRequest
                :> Post '[JSON] (Answer "acceptSubmittedIntakeRequest")
         :<|> "reject" :> ReqBody '[JSON] RejectSubmittedIntakeRequestRequest
                :> Post '[JSON] (Answer "rejectSubmittedIntakeRequest")
         :<|> "match-to-slot" :> ReqBody '[JSON] MatchAcceptedIntakeRequestToSlotRequest
                :> Post '[JSON] (Answer "matchAcceptedIntakeRequestToSlot")
         :<|> "withdraw" :> ReqBody '[JSON] WithdrawIntakeRequestRequest
                :> Post '[JSON] (Answer "withdrawIntakeRequest")
         :<|> "mark-stale" :> Post '[JSON] (Answer "markAcceptedIntakeRequestStale")
         :<|> "close" :> ReqBody '[JSON] CloseAppointedIntakeRequestRequest
                :> Post '[JSON] (Answer "closeAppointedIntakeRequest")
         )
  )

intakeRequestsServer :: ServerT IntakeRequestsAPI AppM
intakeRequestsServer =
       submitHandler
  :<|> withPool fetchSubmittedIntakeRequests
         `readWith` map fromDomainSubmittedIntakeRequest
  :<|> withPool fetchAcceptedIntakeRequests
         `readWith` map fromDomainTriagedIntakeRequest
  :<|> withPool fetchAppointedIntakeRequests
         `readWith` map fromDomainAppointedIntakeRequest
  :<|> (\from to -> withPool (\p -> fetchRejectedIntakeRequestsByRejectedAt p from to)
         `readWith` map fromDomainRejectedIntakeRequest)
  :<|> (\from to -> withPool (\p -> fetchWithdrawnIntakeRequestsByWithdrawnAt p from to)
         `readWith` map fromDomainWithdrawnIntakeRequest)
  :<|> (\from to -> withPool (\p -> fetchStaleIntakeRequestsByStaleAt p from to)
         `readWith` map fromDomainStaleIntakeRequest)
  :<|> (\from to -> withPool (\p -> fetchClosedIntakeRequestsByStart p from to)
         `readWith` map fromDomainClosedIntakeRequest)
  :<|> byId
  where
    readWith :: ToJSON dto => AppM (Either ServiceError a) -> (a -> dto) -> AppM (Answer useCase)
    readWith fetch render = fetch >>= answered (ok . render)

    submitHandler req = do
      recordedAt <- now
      withPool (\p -> submitIntakeRequest p (toDomainPatientId req.patientId) req.narrative recordedAt)
        >>= answered (ok . fromDomainSubmittedIntakeRequest)

    byId requestIdDTO =
           fetchHandler
      :<|> acceptHandler
      :<|> rejectHandler
      :<|> matchToSlotHandler
      :<|> withdrawHandler
      :<|> markStaleHandler
      :<|> closeHandler
      where
        requestId = toDomainIntakeRequestId requestIdDTO

        fetchHandler =
          withPool (\p -> fetchIntakeRequest p requestId)
            >>= answered (ok . fromDomainIntakeRequest)

        acceptHandler req = do
          recordedAt <- now
          withPool (\p -> acceptSubmittedIntakeRequest p requestId
                      (toDomainHealthcareServiceId req.healthcareServiceId)
                      (toDomainIntakeRequestPriority req.priority)
                      (toDomainDoctorRequirement req.doctorRequirement)
                      recordedAt)
            >>= answered (renderTransitionOutcome fromDomainTriagedIntakeRequest)

        rejectHandler req = do
          recordedAt <- now
          withPool (\p -> rejectSubmittedIntakeRequest p requestId recordedAt req.rejectionReason)
            >>= answered (renderTransitionOutcome fromDomainRejectedIntakeRequest)

        matchToSlotHandler req =
          withPool (\p -> matchAcceptedIntakeRequestToSlot p requestId (toDomainSlotId req.slotId))
            >>= answered renderMatchOutcome

        withdrawHandler req = do
          recordedAt <- now
          withPool (\p -> withdrawIntakeRequest p requestId recordedAt req.withdrawalNote)
            >>= answered (renderTransitionOutcome fromDomainWithdrawnIntakeRequest)

        markStaleHandler = do
          recordedAt <- now
          withPool (\p -> markAcceptedIntakeRequestStale p requestId recordedAt)
            >>= answered (renderTransitionOutcome fromDomainStaleIntakeRequest)

        closeHandler req = do
          recordedAt <- now
          withPool (\p -> closeAppointedIntakeRequest p requestId
                      (toDomainCloseReasonRequest recordedAt req.closeReason))
            >>= answered (renderTransitionOutcome fromDomainClosedIntakeRequest)

-- ═══════════════════════════════════════════════════════════════════════════
-- AVAILABLE SLOTS
-- ═══════════════════════════════════════════════════════════════════════════

type AvailableSlotsAPI = "available-slots" :>
  (    ReqBody '[JSON] CreateAvailableSlotRequest :> Post '[JSON] (Answer "createAvailableSlot")
  :<|> Capture "slotId" SlotIdDTO :>
         (    Get '[JSON] (Answer "fetchAvailableSlot")
         :<|> "match-by-priority" :> Post '[JSON] (Answer "matchAvailableSlotByPriority")
         )
  )

availableSlotsServer :: ServerT AvailableSlotsAPI AppM
availableSlotsServer = createHandler :<|> byId
  where
    createHandler req =
      withPool (\p -> createAvailableSlot p
                  (toDomainDoctorId req.doctorId)
                  (toDomainHealthcareServiceId req.healthcareServiceId)
                  req.start)
        >>= answered renderSlotCreationOutcome

    byId slotIdDTO = fetchHandler :<|> matchByPriorityHandler
      where
        domainSlotId = toDomainSlotId slotIdDTO
        fetchHandler =
          withPool (\p -> fetchAvailableSlot p domainSlotId) >>= answered renderAvailableSlotRead
        matchByPriorityHandler =
          withPool (\p -> matchAvailableSlotByPriority p domainSlotId)
            >>= answered renderPriorityMatchOutcome

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR CALENDAR
-- ═══════════════════════════════════════════════════════════════════════════

type DoctorCalendarAPI = "doctor-calendar" :>
  Range (Get '[JSON] (Answer "fetchDoctorCalendarEntriesOverlapping"))

doctorCalendarServer :: ServerT DoctorCalendarAPI AppM
doctorCalendarServer from to =
  withPool (\p -> fetchDoctorCalendarEntriesOverlapping p from to)
    >>= answered (ok . map fromDomainDoctorCalendarEntry)

-- ═══════════════════════════════════════════════════════════════════════════
-- API
-- ═══════════════════════════════════════════════════════════════════════════

type API =
       DoctorsAPI
  :<|> PatientsAPI
  :<|> HealthcareServicesAPI
  :<|> IntakeRequestsAPI
  :<|> AvailableSlotsAPI
  :<|> DoctorCalendarAPI

api :: Proxy API
api = Proxy

server :: ServerT API AppM
server =
       doctorsServer
  :<|> patientsServer
  :<|> healthcareServicesServer
  :<|> intakeRequestsServer
  :<|> availableSlotsServer
  :<|> doctorCalendarServer

swaggerDoc :: Swagger
swaggerDoc = toSwagger api
  & info . title   .~ "triage API"
  & info . version .~ "0.1.0.0"

type AppAPI = SwaggerSchemaUI "swagger-ui" "swagger.json" :<|> API

appServer :: ConnectionPool -> Server AppAPI
appServer pool = swaggerSchemaUIServer swaggerDoc :<|> hoistServer api (toHandler pool) server

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIGURATION / MAIN
-- Only serves: migrations are a separate, manual step.
-- ═══════════════════════════════════════════════════════════════════════════

frontendOrigin :: BS8.ByteString
frontendOrigin = "http://localhost:5173"

corsMiddleware :: Middleware
corsMiddleware = cors . const . Just $ simpleCorsResourcePolicy
  { corsOrigins        = Just ([frontendOrigin], False)
  , corsMethods        = ["GET", "POST"]
  , corsRequestHeaders = ["Content-Type"]
  }

main :: IO ()
main = do
  dbUrl <- fromMaybe "postgresql://localhost/triage" <$> lookupEnv "TRIAGE_DB_URL"
  port  <- lookupEnv "TRIAGE_PORT" >>= \v -> case v of
    Nothing -> pure 8080
    Just s  -> case readMaybe s of
      Just n | n > 0 && n < 65536 -> pure n
      _ -> ioError (userError ("TRIAGE_PORT is not a valid port: " <> show s))
  pool <- newPool (defaultPoolConfig (connectPostgreSQL (BS8.pack dbUrl)) close 60 10)
  run port (corsMiddleware (serve (Proxy @AppAPI) (appServer pool)))
