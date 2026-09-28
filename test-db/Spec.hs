{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

-- Database-backed tests: the SQL behind Persistence.hs and Service.hs,
-- run against a real PostgreSQL. Each run creates a throwaway database
-- (triage_test_<random>), applies migrations/0001_init.sql, and drops it at
-- the end. Tables are emptied before every test.
--
-- Needs a running PostgreSQL the current user can create databases on.
-- TRIAGE_TEST_PG holds extra libpq connection keywords (e.g.
-- "host=localhost port=5433 user=me"); by default the local server is used.
--
-- Races are simulated deterministically: a write is given a row version
-- that is already stale, instead of running two threads and hoping they
-- collide.

module Main (main) where

import Prelude hiding (id)

import Control.Exception          (bracket, try)
import Data.Maybe                 (fromMaybe)
import Data.Pool                  (defaultPoolConfig, destroyAllResources, newPool, withResource)
import Data.String                (fromString)
import Data.Time                  (UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection, Only (..), SqlError (..), close, connectPostgreSQL,
                                   execute, execute_)
import System.Environment         (lookupEnv)
import Test.Hspec

import qualified Data.UUID  as UUID
import qualified Persistence as P
import qualified Service    as S

import Domain
import Persistence (ClaimOutcome (..), ConnectionPool, MatchPersistOutcome (..), RowVersion (..),
                    SlotOverlap (..), Versioned (..))
import Service     (Fresh (..), MatchOutcome (..), ServiceError (..), SlotCreationOutcome (..))

-- ═══════════════════════════════════════════════════════════════════════════
-- THROWAWAY DATABASE
-- ═══════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
  base <- fromMaybe "" <$> lookupEnv "TRIAGE_TEST_PG"
  dbName <- ("triage_test_" ++) . take 12 . filter (/= '-') . UUID.toString <$> nextRandom
  let admin   = base ++ " dbname=postgres"
      testDb  = base ++ " dbname=" ++ dbName
  bracket (createDatabase admin dbName testDb) (dropDatabase admin dbName) $ \pool ->
    hspec (before_ (emptyTables pool) (spec pool))

createDatabase :: String -> String -> String -> IO ConnectionPool
createDatabase admin dbName testDb = do
  _ <- withConnection admin $ \c -> execute_ c (fromString ("CREATE DATABASE " ++ dbName))
  schema <- readFile "migrations/0001_init.sql"
  _ <- withConnection testDb $ \c -> execute_ c (fromString schema)
  newPool (defaultPoolConfig (connectPostgreSQL (fromString testDb)) close 60 4)

dropDatabase :: String -> String -> ConnectionPool -> IO ()
dropDatabase admin dbName pool = do
  destroyAllResources pool
  _ <- withConnection admin $ \c -> execute_ c (fromString ("DROP DATABASE " ++ dbName ++ " WITH (FORCE)"))
  pure ()

withConnection :: String -> (Connection -> IO a) -> IO a
withConnection conninfo = bracket (connectPostgreSQL (fromString conninfo)) close

emptyTables :: ConnectionPool -> IO ()
emptyTables pool = withResource pool $ \c -> do
  _ <- execute_ c
    "TRUNCATE doctor_calendar, slots, intake_requests, healthcare_services, patients, doctors CASCADE"
  pure ()

-- ═══════════════════════════════════════════════════════════════════════════
-- FIXTURES
-- ═══════════════════════════════════════════════════════════════════════════

data Fixture = Fixture
  { doctor  :: Doctor
  , patient :: Patient
  , service :: HealthcareService   -- 30 minutes
  }

fixture :: ConnectionPool -> IO Fixture
fixture pool =
  Fixture <$> S.createDoctor pool "Dr A"
          <*> S.createPatient pool "Patient P"
          <*> S.createHealthcareService pool "Consultation" HalfAnHour

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 10 1) (9 * 3600)

minutes :: Integer -> UTCTime -> UTCTime
minutes m = addUTCTime (fromIntegral (m * 60))

submit :: ConnectionPool -> Fixture -> IO SubmittedIntakeRequest
submit pool fx = S.submitIntakeRequest pool fx.patient.id "needs care" t0

accept :: ConnectionPool -> Fixture -> DoctorRequirement -> IO TriagedIntakeRequest
accept pool fx requirement = do
  s <- submit pool fx
  Right (Applied t) <- S.acceptSubmittedIntakeRequest pool s.id fx.service.id (Routine RoutineAnytime) requirement t0
  pure t

slotAt :: ConnectionPool -> Fixture -> UTCTime -> IO AvailableSlot
slotAt pool fx at = do
  Right (SlotCreated slot) <- S.createAvailableSlot pool fx.doctor.id fx.service.id at
  pure slot

appoint :: ConnectionPool -> Fixture -> UTCTime -> IO (TriagedIntakeRequest, AvailableSlot, AppointedIntakeRequest)
appoint pool fx at = do
  t    <- accept pool fx AnyDoctor
  slot <- slotAt pool fx at
  Right (Matched a) <- S.matchAcceptedIntakeRequestToSlot pool t.submitted.id slot.id
  pure (t, slot, a)

stored :: ConnectionPool -> IntakeRequestId -> IO (Versioned IntakeRequest)
stored pool rid = withResource pool $ \c -> do
  Right (Just v) <- P.fetchIntakeRequest c rid
  pure v

versionOf :: ConnectionPool -> IntakeRequestId -> IO RowVersion
versionOf pool rid = (.version) <$> stored pool rid

-- An update that changes nothing but still fires the version trigger —
-- stands in for "someone else wrote this row in the meantime".
touch :: ConnectionPool -> IntakeRequestId -> IO ()
touch pool (IntakeRequestId rid) = withResource pool $ \c -> do
  _ <- execute c "UPDATE intake_requests SET narrative = narrative WHERE id = ?" (Only rid)
  pure ()

stateOf :: ConnectionPool -> IntakeRequestId -> IO String
stateOf pool rid = do
  v <- stored pool rid
  pure $ case v.value of
    Submitted {} -> "submitted"
    Rejected {}  -> "rejected"
    Accepted {}  -> "accepted"
    Appointed {} -> "appointed"
    Withdrawn {} -> "withdrawn"
    Stale {}     -> "stale"
    Closed {}    -> "closed"

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEC
-- ═══════════════════════════════════════════════════════════════════════════

spec :: ConnectionPool -> Spec
spec pool = do
  describe "round trips" $ do
    it "a submitted request reads back unchanged" $ do
      fx <- fixture pool
      s  <- submit pool fx
      (.value) <$> stored pool s.id `shouldReturn` Submitted s

    it "an accepted request keeps its priority and doctor requirement" $ do
      fx <- fixture pool
      t  <- accept pool fx (SpecificDoctor fx.doctor.id)
      (.value) <$> stored pool t.submitted.id `shouldReturn` Accepted t

    it "an appointed request reads back unchanged" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      (.value) <$> stored pool a.triaged.submitted.id `shouldReturn` Appointed a

  describe "version trigger" $
    it "bumps the version by one on every update" $ do
      fx <- fixture pool
      s  <- submit pool fx
      versionOf pool s.id `shouldReturn` RowVersion 0
      touch pool s.id
      versionOf pool s.id `shouldReturn` RowVersion 1
      _ <- S.acceptSubmittedIntakeRequest pool s.id fx.service.id (Routine RoutineAnytime) AnyDoctor t0
      versionOf pool s.id `shouldReturn` RowVersion 2

  describe "accept / reject" $ do
    it "rejecting an already accepted request is refused, and it stays accepted" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.rejectSubmittedIntakeRequest pool t.submitted.id t0 "too late"
        `shouldReturn` Left (RequestNotSubmittedAnymore t.submitted.id)
      stateOf pool t.submitted.id `shouldReturn` "accepted"

    it "an accept with a stale version writes nothing" $ do
      fx    <- fixture pool
      s     <- submit pool fx
      stale <- versionOf pool s.id
      touch pool s.id
      let t = acceptIntakeRequest s fx.service.id (Routine RoutineAnytime) AnyDoctor t0
      withResource pool (\c -> P.persistTriagedIntakeRequest c stale t) `shouldReturn` AlreadyClaimed
      stateOf pool s.id `shouldReturn` "submitted"

    it "a reject with the current version but the wrong state writes nothing" $ do
      fx      <- fixture pool
      t       <- accept pool fx AnyDoctor
      current <- versionOf pool t.submitted.id
      withResource pool (\c -> P.persistRejectedIntakeRequest c current t.submitted t0 "no")
        `shouldReturn` AlreadyClaimed
      stateOf pool t.submitted.id `shouldReturn` "accepted"

  describe "slots" $ do
    it "an overlapping slot is a conflict; a touching one is fine" $ do
      fx <- fixture pool
      _  <- slotAt pool fx t0
      S.createAvailableSlot pool fx.doctor.id fx.service.id (minutes 15 t0) `shouldReturn` Right SlotConflict
      Right (SlotCreated _) <- S.createAvailableSlot pool fx.doctor.id fx.service.id (minutes 30 t0)
      pure ()

    it "the database rejects an overlap even when the Domain check is bypassed" $ do
      fx      <- fixture pool
      _       <- slotAt pool fx t0
      otherId <- S.newSlotId
      let overlapping = AvailableSlot
            { id = otherId, doctorId = fx.doctor.id, healthcareServiceId = fx.service.id
            , start = minutes 15 t0, duration = HalfAnHour }
      withResource pool (\c -> P.insertAvailableSlot c overlapping) `shouldReturn` Left SlotOverlap

    it "the new slot takes its duration from the service" $ do
      fx   <- fixture pool
      slot <- slotAt pool fx t0
      slot.duration `shouldBe` fx.service.duration

  describe "match" $ do
    it "books the request and removes the slot" $ do
      fx           <- fixture pool
      (_, slot, a) <- appoint pool fx t0
      stateOf pool a.triaged.submitted.id `shouldReturn` "appointed"
      withResource pool (\c -> P.fetchSlot c slot.id) `shouldReturn` Right Nothing

    it "the same slot can't be matched twice" $ do
      fx           <- fixture pool
      (_, slot, _) <- appoint pool fx t0
      other        <- accept pool fx AnyDoctor
      S.matchAcceptedIntakeRequestToSlot pool other.submitted.id slot.id `shouldReturn` Right SlotAlreadyClaimed
      stateOf pool other.submitted.id `shouldReturn` "accepted"

    it "rolls the slot delete back when the request claim loses" $ do
      fx    <- fixture pool
      t     <- accept pool fx AnyDoctor
      slot  <- slotAt pool fx t0
      stale <- versionOf pool t.submitted.id
      touch pool t.submitted.id
      Just appointed <- pure (matchIntakeRequestToSlot slot t)
      withResource pool (\c -> P.persistMatchedIntakeRequest c slot.id stale appointed)
        `shouldReturn` RequestAlreadyMatched
      withResource pool (\c -> P.fetchSlot c slot.id) `shouldReturn` Right (Just slot)
      stateOf pool t.submitted.id `shouldReturn` "accepted"

  describe "reclaim / close / stale" $ do
    it "reclaim returns the same triaged request and frees the time" $ do
      fx        <- fixture pool
      (t, _, a) <- appoint pool fx t0
      S.reclaimAppointedIntakeRequest pool a.triaged.submitted.id `shouldReturn` Right (Applied t)
      stateOf pool t.submitted.id `shouldReturn` "accepted"
      Right (SlotCreated _) <- S.createAvailableSlot pool fx.doctor.id fx.service.id t0
      pure ()

    it "closing twice is refused the second time" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      let rid = a.triaged.submitted.id
      S.closeAppointedIntakeRequest pool rid Completed `shouldReturn` Right (Applied (Closed a Completed))
      S.closeAppointedIntakeRequest pool rid Completed `shouldReturn` Left (RequestAlreadyClosed rid)

    it "a close can't land on an appointment its caller never saw" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      let rid = a.triaged.submitted.id
      seen  <- versionOf pool rid
      -- Meanwhile: reclaimed and re-matched to a later slot.
      Right (Applied _) <- S.reclaimAppointedIntakeRequest pool rid
      later <- slotAt pool fx (minutes 60 t0)
      Right (Matched _) <- S.matchAcceptedIntakeRequestToSlot pool rid later.id
      withResource pool (\c -> P.persistClosedIntakeRequestIfAppointed c seen a Completed)
        `shouldReturn` AlreadyClaimed
      stateOf pool rid `shouldReturn` "appointed"

    it "mark stale works from accepted, not from submitted" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.markIntakeRequestStale pool t.submitted.id t0 `shouldReturn` Right (Applied t)
      s  <- submit pool fx
      S.markIntakeRequestStale pool s.id t0 `shouldReturn` Left (RequestNotAccepted s.id)

  describe "constraints" $
    it "a submitted request can't carry a decided doctor requirement" $ do
      fx <- fixture pool
      s  <- submit pool fx
      let IntakeRequestId rid = s.id
          DoctorId did        = fx.doctor.id
      result <- try (withResource pool (\c ->
        execute c "UPDATE intake_requests SET required_doctor_id = ? WHERE id = ?" (did, rid)))
      case result of
        Left e  -> sqlState e `shouldBe` "23514"   -- check_violation
        Right n -> expectationFailure ("the update was accepted (" ++ show n ++ " row)")
