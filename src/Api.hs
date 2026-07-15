{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- REST API layer, built on Servant per .claude/skills/triage-api-codegen's
-- SKILL.md and references/servant-implementation.md — read both before
-- extending this file. Single file, sectioned per resource (route type +
-- handlers + sub-server wiring interleaved), same banner-comment
-- convention as Persistence.hs/Service.hs, not a signatures-then-bodies
-- split (servant-implementation.md section 2).
--
-- Only DoctorAPI/PatientAPI exist so far. Both are servant-implementation.md
-- shape (a): bare IO all the way down (createDoctor/fetchDoctor/
-- fetchDoctors and their Patient equivalents have no Either anywhere in
-- Service.hs), so there is deliberately no envelope and no runService/
-- runRead middleware here — that machinery exists for shapes (b)/(c),
-- which the later resource sections (HealthcareService/Slot/IntakeRequest/
-- Calendar) will actually need.

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

    -- ── Top-level API ────────────────────────────────────────────────────
  , API
  , server
  ) where

import Control.Monad.IO.Class     (liftIO)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.ByteString            (ByteString)
import Data.Maybe                 (fromMaybe)
import Data.Pool                  (defaultPoolConfig, newPool)
import Data.UUID                  (UUID)
import Network.Wai.Handler.Warp   (run)
import Servant
import System.Environment         (lookupEnv)
import System.Exit                (exitFailure)
import System.IO                  (hPutStrLn, stderr)
import Text.Read                  (readMaybe)

import qualified Data.ByteString.Char8     as BS8
import qualified Database.PostgreSQL.Simple as PG
import qualified Service

import Domain      (DoctorId (..), PatientId (..))
import Persistence (ConnectionPool)
import Transport
  ( CreateDoctorRequest (..)
  , CreatePatientRequest (..)
  , DoctorDTO
  , PatientDTO
  , fromDomainDoctor
  , fromDomainPatient
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
-- TOP-LEVEL API
-- HealthcareServiceAPI/SlotAPI/IntakeRequestAPI/CalendarAPI are not
-- stubbed here — they're added, each with its own section above this
-- one, when their own passes come.
-- ═══════════════════════════════════════════════════════════════════════

type API = "doctors" :> DoctorAPI :<|> "patients" :> PatientAPI

server :: ServerT API AppM
server = doctorServer :<|> patientServer
