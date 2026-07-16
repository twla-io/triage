{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- REST API layer, built on Servant per .claude/skills/triage-api-codegen's
-- SKILL.md and references/servant-implementation.md — read both before
-- extending this file. Single file, sectioned per resource (route type +
-- handlers + sub-server wiring interleaved), same banner-comment
-- convention as Persistence.hs/Service.hs, not a signatures-then-bodies
-- split (servant-implementation.md section 2).
--
-- DoctorAPI/PatientAPI/HealthcareServiceAPI/SlotAPI exist so far.
-- Doctor/Patient are both servant-implementation.md shape (a): bare IO all
-- the way down (createDoctor/fetchDoctor/fetchDoctors and their Patient
-- equivalents have no Either anywhere in Service.hs), so neither needs an
-- envelope or any middleware. HealthcareServiceAPI's create is shape (a)
-- too, but its list/get reads are shape (b) (IO (Either DecodeError a)) —
-- the first section to actually need the runRead helper (see the
-- MIDDLEWARE section below). SlotAPI's create is shape (c)'s
-- SlotCreationOutcome relative (no ServiceError/Either at all — see
-- MIDDLEWARE's own runSlotCreation), its list is shape (b) again. Full
-- runService/runMatchOutcome (shape (c) proper, for mutations with a
-- ServiceError layer) aren't needed by anything built so far;
-- IntakeRequest/Calendar's own passes will add them alongside the
-- endpoints that actually require them.

module Api
  ( -- ── Application monad ────────────────────────────────────────────────
    AppM
  , runAppM

    -- ── Config / wiring ──────────────────────────────────────────────────
  , AppConfig (..)
  , loadConfig
  , mkPool
  , app
  , main

    -- ── Doctor ───────────────────────────────────────────────────────────
  , DoctorAPI
  , doctorServer

    -- ── Patient ──────────────────────────────────────────────────────────
  , PatientAPI
  , patientServer

    -- ── Healthcare Service ───────────────────────────────────────────────
  , HealthcareServiceAPI
  , healthcareServiceServer

    -- ── Slot ─────────────────────────────────────────────────────────────
  , SlotAPI
  , slotServer

    -- ── Top-level API ────────────────────────────────────────────────────
  , API
  , server
  ) where

import Control.Monad.IO.Class     (liftIO)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.Aeson                 (ToJSON, Value (Null), object, toJSON, (.=))
import Data.ByteString            (ByteString)
import Data.Maybe                 (fromMaybe)
import Data.Pool                  (defaultPoolConfig, newPool)
import Data.Text                  (Text)
import Data.Time                  (UTCTime)
import Data.UUID                  (UUID)
import Network.Wai.Handler.Warp   (run)
import Servant
import System.Environment         (lookupEnv)
import System.Exit                (exitFailure)
import System.IO                  (hPutStrLn, stderr)
import Text.Read                  (readMaybe)

import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import qualified Database.PostgreSQL.Simple as PG
import qualified Service

import Domain      (AvailableSlot (..), DoctorId (..), HealthcareServiceId (..), PatientId (..))
import Persistence (ConnectionPool, DecodeError)
import Service     (SlotCreationOutcome (..))
import Transport
  ( AvailableSlotDTO
  , CreateAvailableSlotRequest (..)
  , CreateDoctorRequest (..)
  , CreateHealthcareServiceRequest (..)
  , CreatePatientRequest (..)
  , DoctorDTO
  , HealthcareServiceDTO
  , PatientDTO
  , fromDomainAvailableSlot
  , fromDomainDoctor
  , fromDomainHealthcareService
  , fromDomainPatient
  , toDomainDuration
  )

-- ═══════════════════════════════════════════════════════════════════════
-- APPLICATION MONAD
-- Bare ReaderT ConnectionPool Handler — no AppEnv wrapper record.
-- Deliberately does not inherit Service.hs's own explicit-ConnectionPool-
-- parameter convention: Service.hs functions are library-style entry
-- points called from multiple contexts (test/Spec.hs, this module), so an
-- explicit parameter keeps them composable; handlers here are called from
-- exactly one place (Servant's own dispatch), so there is no composability
-- to protect by keeping the pool explicit at this layer too. See
-- servant-implementation.md section 3 for the full reasoning.
-- ═══════════════════════════════════════════════════════════════════════

type AppM = ReaderT ConnectionPool Handler

runAppM :: ConnectionPool -> AppM a -> Handler a
runAppM pool action = runReaderT action pool

-- ═══════════════════════════════════════════════════════════════════════
-- CONFIG / WIRING
-- See servant-implementation.md section 7 for the deliberate asymmetry
-- between the two env vars below: a missing TRIAGE_DB_URL silently
-- defaults (a wrong connection string fails loudly the moment mkPool
-- actually tries to connect, same as any other infra hiccup), but a
-- present-but-malformed TRIAGE_PORT fails loudly at startup rather than
-- silently falling back to 8080 — a wrong port that silently defaulted
-- could run unnoticed (the server comes up, appears healthy, and is
-- simply listening somewhere nobody expects), whereas a startup crash on
-- bad config is immediately actionable and costs nothing at boot, since
-- nothing has served a single request yet.
-- ═══════════════════════════════════════════════════════════════════════

data AppConfig = AppConfig
  { dbConnectionString :: ByteString
  , serverPort         :: Int
  }

-- A local-dev default, not meant to be relied on beyond that.
defaultDbConnectionString :: String
defaultDbConnectionString = "postgresql://localhost/triage"

defaultServerPort :: Int
defaultServerPort = 8080

loadConfig :: IO AppConfig
loadConfig = do
  mDbUrl <- lookupEnv "TRIAGE_DB_URL"
  let connStr = fromMaybe defaultDbConnectionString mDbUrl
  mPortStr <- lookupEnv "TRIAGE_PORT"
  port <- case mPortStr of
    Nothing      -> pure defaultServerPort
    Just portStr -> case readMaybe portStr of
      Just p  -> pure p
      Nothing -> do
        hPutStrLn stderr
          ("TRIAGE_PORT is set but not a valid port number: " ++ show portStr)
        exitFailure
  pure AppConfig { dbConnectionString = BS8.pack connStr, serverPort = port }

-- 10 connections / 60-second idle timeout — both explicitly unrefined
-- placeholders appropriate to current scale (2-3 doctors), not tuned
-- values. Revisit if/when connection contention or idle-churn actually
-- becomes observable, not preemptively.
mkPool :: AppConfig -> IO ConnectionPool
mkPool config = newPool $ defaultPoolConfig
  (PG.connectPostgreSQL config.dbConnectionString)
  PG.close
  60
  10

main :: IO ()
main = do
  config <- loadConfig
  pool   <- mkPool config
  putStrLn $ "Starting triage API on port " ++ show config.serverPort
  run config.serverPort (app pool)

-- hoistServer supplies runAppM pool once, at server-construction time —
-- not per-handler. Every handler below is written against AppM; this is
-- the one call that threads the pool through all of them uniformly.
app :: ConnectionPool -> Application
app pool = serve (Proxy @API) (hoistServer (Proxy @API) (runAppM pool) server)

-- ═══════════════════════════════════════════════════════════════════════
-- MIDDLEWARE
-- Shared AppM helpers translating Service.hs/Persistence.hs result shapes
-- into HTTP responses, per servant-implementation.md section 4.
--
-- runRead exists for shape (b) (IO (Either DecodeError a)) —
-- HealthcareServiceAPI's list/get reads were the first section that
-- needed it. runSlotCreation/envelope/envelopeEmpty now also exist, for
-- SlotAPI's create (IO SlotCreationOutcome — no ServiceError/Either at
-- all, its own outcome-typed shape per servant-implementation.md section
-- 4's "runSlotCreation" worked example). Full runService/runMatchOutcome
-- (shape (c) proper, for mutations with a genuine ServiceError layer)
-- still don't exist — nothing built so far calls a Service.hs mutation
-- that returns Either ServiceError a, so there is nothing yet to move
-- here from an earlier resource section; IntakeRequest's own pass will
-- add them alongside the endpoints that actually require them.
--
-- DecodeError (Persistence.hs) derives only (Show, Eq) — no Generic, no
-- hand-written ToJSON anywhere in this codebase (verified, not assumed).
-- A decode failure is outside the domain's error vocabulary regardless
-- (error-vs-outcome-mapping's own 500 case: "anything genuinely
-- unexpected that no ServiceError/outcome constructor was written to
-- describe"), so its body is a plain-text `show`, not a JSON encoding
-- there is no instance to produce.
-- ═══════════════════════════════════════════════════════════════════════

runRead :: IO (Either DecodeError a) -> AppM a
runRead action = do
  result <- liftIO action
  case result of
    Left e  -> throwError err500 { errBody = LBS8.pack (show e) }
    Right a -> pure a

-- Generic response envelope for mutations with an outcome to discriminate
-- in-body, per error-vs-outcome-mapping/servant-implementation.md section
-- 4 — one shared shape ({"outcome", "detail"}), not a bespoke response
-- DTO per endpoint. envelopeEmpty is for outcome constructors with no
-- payload — "detail" is always present as a key, its value null rather
-- than the key being omitted.
envelope :: ToJSON dto => Text -> dto -> Value
envelope tag detail = object ["outcome" .= tag, "detail" .= toJSON detail]

envelopeEmpty :: Text -> Value
envelopeEmpty tag = object ["outcome" .= tag, "detail" .= Null]

-- For createAvailableSlot's bare IO SlotCreationOutcome shape — no
-- ServiceError/Either at all (verified against Service.hs directly:
-- SlotCreated AvailableSlot | SlotConflict). Per checkwaitlist-not-an-
-- endpoint/servant-implementation.md section 4's own resolved design
-- question, this deliberately does NOT also invoke matchWaitlistToSlot —
-- the response reflects only SlotCreationOutcome, full stop.
runSlotCreation :: IO SlotCreationOutcome -> AppM Value
runSlotCreation action = do
  outcome <- liftIO action
  pure $ case outcome of
    SlotCreated slot -> envelope "slotCreated" (fromDomainAvailableSlot slot)
    SlotConflict     -> envelopeEmpty "slotConflict"

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTOR
-- All three operations are shape (a) (bare IO, no Either) — verified
-- against Service.hs directly: createDoctor :: ConnectionPool -> Text ->
-- IO Doctor, fetchDoctor :: ConnectionPool -> DoctorId -> IO (Maybe
-- Doctor), fetchDoctors :: ConnectionPool -> IO [Doctor]. No envelope, no
-- runService/runRead here — just call Service.hs, convert through
-- Transport.hs, return the DTO directly as the 200 body.
--
-- getDoctorHandler's 404 is a genuine exception to error-vs-outcome-
-- mapping's usual "200, discriminated in-body" rule: fetchDoctor's
-- return type is bare Maybe Doctor, with no ServiceError/outcome-type
-- layer at all to discriminate a 200 body around. Unlike RequestNotFound
-- on the mutation side (which has that layer, via ServiceError, and
-- stays 200), there is no comparable envelope here to put "not found"
-- inside — 404 is the only honest option once Nothing comes back.
-- ═══════════════════════════════════════════════════════════════════════

type DoctorAPI =
       ReqBody '[JSON] CreateDoctorRequest :> Post '[JSON] DoctorDTO
  :<|> Get '[JSON] [DoctorDTO]
  :<|> Capture "id" UUID :> Get '[JSON] DoctorDTO

createDoctorHandler :: CreateDoctorRequest -> AppM DoctorDTO
createDoctorHandler req = do
  pool   <- ask
  doctor <- liftIO (Service.createDoctor pool req.name)
  pure (fromDomainDoctor doctor)

listDoctorsHandler :: AppM [DoctorDTO]
listDoctorsHandler = do
  pool    <- ask
  doctors <- liftIO (Service.fetchDoctors pool)
  pure (map fromDomainDoctor doctors)

getDoctorHandler :: UUID -> AppM DoctorDTO
getDoctorHandler uid = do
  pool    <- ask
  mDoctor <- liftIO (Service.fetchDoctor pool (DoctorId uid))
  case mDoctor of
    Just doctor -> pure (fromDomainDoctor doctor)
    Nothing     -> throwError err404

doctorServer :: ServerT DoctorAPI AppM
doctorServer = createDoctorHandler :<|> listDoctorsHandler :<|> getDoctorHandler

-- ═══════════════════════════════════════════════════════════════════════
-- PATIENT
-- Mirrors Doctor exactly: createPatient/fetchPatient/fetchPatients are
-- the same three shape-(a) operations, verified against Service.hs
-- directly (createPatient :: ConnectionPool -> Text -> IO Patient;
-- fetchPatient :: ConnectionPool -> PatientId -> IO (Maybe Patient);
-- fetchPatients :: ConnectionPool -> IO [Patient]) — same reasoning
-- throughout, not restated.
-- ═══════════════════════════════════════════════════════════════════════

type PatientAPI =
       ReqBody '[JSON] CreatePatientRequest :> Post '[JSON] PatientDTO
  :<|> Get '[JSON] [PatientDTO]
  :<|> Capture "id" UUID :> Get '[JSON] PatientDTO

createPatientHandler :: CreatePatientRequest -> AppM PatientDTO
createPatientHandler req = do
  pool    <- ask
  patient <- liftIO (Service.createPatient pool req.name)
  pure (fromDomainPatient patient)

listPatientsHandler :: AppM [PatientDTO]
listPatientsHandler = do
  pool     <- ask
  patients <- liftIO (Service.fetchPatients pool)
  pure (map fromDomainPatient patients)

getPatientHandler :: UUID -> AppM PatientDTO
getPatientHandler uid = do
  pool     <- ask
  mPatient <- liftIO (Service.fetchPatient pool (PatientId uid))
  case mPatient of
    Just patient -> pure (fromDomainPatient patient)
    Nothing      -> throwError err404

patientServer :: ServerT PatientAPI AppM
patientServer = createPatientHandler :<|> listPatientsHandler :<|> getPatientHandler

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICE
-- createHealthcareServiceHandler is shape (a) — verified against
-- Service.hs directly: createHealthcareService :: ConnectionPool -> Text
-- -> Duration -> IO HealthcareService, bare IO, no Either. Mirrors
-- createDoctorHandler exactly, plus unwrapping the request DTO's
-- duration field through toDomainDuration (total — see Transport.hs's own
-- DURATION section).
--
-- listHealthcareServicesHandler/getHealthcareServiceHandler are shape (b)
-- — verified against Service.hs directly: fetchHealthcareServices ::
-- ConnectionPool -> IO (Either DecodeError [HealthcareService]);
-- fetchHealthcareService :: ConnectionPool -> HealthcareServiceId -> IO
-- (Either DecodeError (Maybe HealthcareService)) — a decode failure
-- (outer Either) and a missing row (inner Maybe) are two independent,
-- layered possibilities, unlike Doctor/Patient's bare Maybe. runRead
-- narrows away the outer DecodeError layer (500 on Left, per MIDDLEWARE
-- above), leaving a plain Maybe HealthcareService to pattern-match on —
-- same 404-on-Nothing shape as getDoctorHandler, just with runRead
-- handling the outer layer first.
-- ═══════════════════════════════════════════════════════════════════════

type HealthcareServiceAPI =
       ReqBody '[JSON] CreateHealthcareServiceRequest :> Post '[JSON] HealthcareServiceDTO
  :<|> Get '[JSON] [HealthcareServiceDTO]
  :<|> Capture "id" UUID :> Get '[JSON] HealthcareServiceDTO

createHealthcareServiceHandler :: CreateHealthcareServiceRequest -> AppM HealthcareServiceDTO
createHealthcareServiceHandler req = do
  pool    <- ask
  service <- liftIO (Service.createHealthcareService pool req.name (toDomainDuration req.duration))
  pure (fromDomainHealthcareService service)

listHealthcareServicesHandler :: AppM [HealthcareServiceDTO]
listHealthcareServicesHandler = do
  pool     <- ask
  services <- runRead (Service.fetchHealthcareServices pool)
  pure (map fromDomainHealthcareService services)

getHealthcareServiceHandler :: UUID -> AppM HealthcareServiceDTO
getHealthcareServiceHandler uid = do
  pool     <- ask
  mService <- runRead (Service.fetchHealthcareService pool (HealthcareServiceId uid))
  case mService of
    Just service -> pure (fromDomainHealthcareService service)
    Nothing      -> throwError err404

healthcareServiceServer :: ServerT HealthcareServiceAPI AppM
healthcareServiceServer =
  createHealthcareServiceHandler :<|> listHealthcareServicesHandler :<|> getHealthcareServiceHandler

-- ═══════════════════════════════════════════════════════════════════════
-- SLOT
-- createAvailableSlotHandler is SlotCreationOutcome-shaped — verified
-- against Service.hs directly: createAvailableSlot :: ConnectionPool ->
-- AvailableSlot -> IO SlotCreationOutcome, no ServiceError/Either at all.
-- Unlike every other create* handler, the request DTO has no id field
-- (CreateAvailableSlotRequest, see Transport.hs) — Service.hs mints no
-- SlotId internally the way createDoctor/createPatient/
-- createHealthcareService mint their own IDs, so this handler mints one
-- itself (Service.newSlotId) before constructing the AvailableSlot to
-- pass down. The response is the {"outcome", "detail"} envelope via
-- runSlotCreation, not a bare AvailableSlotDTO — and per
-- checkwaitlist-not-an-endpoint's already-settled resolution, this does
-- NOT also call matchWaitlistToSlot; the response reflects only this
-- call's own SlotCreationOutcome.
--
-- listAvailableSlotsHandler is shape (b) — verified against Service.hs
-- directly: fetchAvailableSlots :: ConnectionPool -> UTCTime -> UTCTime ->
-- Maybe DoctorId -> Maybe HealthcareServiceId -> IO (Either DecodeError
-- [AvailableSlot]) — a required date range plus two optional filters, not
-- a bare no-argument list the way listDoctorsHandler/
-- listPatientsHandler are. The route needs two required query params
-- (start/end) and two optional ones (doctorId/healthcareServiceId,
-- plain UUID on the wire per opaque-uuid-ids, converted to
-- Maybe DoctorId/Maybe HealthcareServiceId in the handler, same
-- Capture-then-wrap pattern as getDoctorHandler). Plain list of
-- AvailableSlotDTO as the 200 body via runRead — no envelope, since reads
-- never get the outcome envelope (servant-implementation.md section 4's
-- closing note: "Reads have no equivalent envelope").
-- ═══════════════════════════════════════════════════════════════════════

type SlotAPI =
       ReqBody '[JSON] CreateAvailableSlotRequest :> Post '[JSON] Value
  :<|> QueryParam' '[Required, Strict] "start" UTCTime
       :> QueryParam' '[Required, Strict] "end" UTCTime
       :> QueryParam "doctorId" UUID
       :> QueryParam "healthcareServiceId" UUID
       :> Get '[JSON] [AvailableSlotDTO]

createAvailableSlotHandler :: CreateAvailableSlotRequest -> AppM Value
createAvailableSlotHandler req = do
  pool   <- ask
  slotId <- liftIO Service.newSlotId
  let slot = AvailableSlot
        { id                  = slotId
        , doctorId            = DoctorId req.doctorId
        , healthcareServiceId = HealthcareServiceId req.healthcareServiceId
        , start               = req.start
        , duration            = toDomainDuration req.duration
        }
  runSlotCreation (Service.createAvailableSlot pool slot)

listAvailableSlotsHandler :: UTCTime -> UTCTime -> Maybe UUID -> Maybe UUID -> AppM [AvailableSlotDTO]
listAvailableSlotsHandler rangeStart rangeEnd mDoctorUUID mServiceUUID = do
  pool  <- ask
  slots <- runRead
    (Service.fetchAvailableSlots pool rangeStart rangeEnd
      (DoctorId <$> mDoctorUUID) (HealthcareServiceId <$> mServiceUUID))
  pure (map fromDomainAvailableSlot slots)

slotServer :: ServerT SlotAPI AppM
slotServer = createAvailableSlotHandler :<|> listAvailableSlotsHandler

-- ═══════════════════════════════════════════════════════════════════════
-- TOP-LEVEL API
-- IntakeRequestAPI/CalendarAPI are not stubbed here — they're added, each
-- with its own section above this one, when their own passes come.
-- ═══════════════════════════════════════════════════════════════════════

type API =
       "doctors" :> DoctorAPI
  :<|> "patients" :> PatientAPI
  :<|> "healthcare-services" :> HealthcareServiceAPI
  :<|> "slots" :> SlotAPI

server :: ServerT API AppM
server = doctorServer :<|> patientServer :<|> healthcareServiceServer :<|> slotServer
