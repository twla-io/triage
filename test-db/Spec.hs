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
-- Races are simulated deterministically: the row is moved on by another
-- write first, then the losing write runs, instead of running two threads
-- and hoping they collide.

module Main (main) where

import Prelude hiding (id)

import Control.Exception          (bracket, try)
import Data.Maybe                 (fromMaybe)
import Data.Pool                  (defaultPoolConfig, destroyAllResources, newPool, withResource)
import Data.String                (fromString)
import Data.Time                  (UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection, SqlError (..), close, connectPostgreSQL,
                                   execute, execute_)
import System.Environment         (lookupEnv)
import Test.Hspec

import qualified Data.UUID  as UUID
import qualified Persistence as P
import qualified Service    as S

import Domain
import Persistence (ClaimOutcome (..), ConnectionPool, MatchPersistOutcome (..), SlotOverlap (..))
import Service     (MatchOutcome (..), ServiceError (..), SlotCreationOutcome (..), TransitionOutcome (..))

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
submit pool fx = do
  Right s <- S.submitIntakeRequest pool fx.patient.id "needs care" t0
  pure s

accept :: ConnectionPool -> Fixture -> DoctorRequirement -> IO TriagedIntakeRequest
accept pool fx requirement = do
  s <- submit pool fx
  Right (Transitioned t) <- S.acceptSubmittedIntakeRequest pool s.id fx.service.id (Routine RoutineAnytime) requirement t0
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

stored :: ConnectionPool -> IntakeRequestId -> IO IntakeRequest
stored pool rid = withResource pool $ \c -> do
  Right (Just r) <- P.fetchIntakeRequest c rid
  pure r

stateOf :: ConnectionPool -> IntakeRequestId -> IO String
stateOf pool rid = do
  r <- stored pool rid
  pure $ case r of
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
      stored pool s.id `shouldReturn` Submitted s

    it "an accepted request keeps its priority and doctor requirement" $ do
      fx <- fixture pool
      t  <- accept pool fx (SpecificDoctor fx.doctor.id)
      stored pool t.submitted.id `shouldReturn` Accepted t

    it "an appointed request reads back unchanged" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      stored pool a.triaged.submitted.id `shouldReturn` Appointed a

  describe "accept / reject" $ do
    it "rejecting an already accepted request reports it moved on, and it stays accepted" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.rejectSubmittedIntakeRequest pool t.submitted.id t0 "too late"
        `shouldReturn` Right (MovedOn (Accepted t))
      stateOf pool t.submitted.id `shouldReturn` "accepted"

    it "accepting twice reports the first accept" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.acceptSubmittedIntakeRequest pool t.submitted.id fx.service.id (Routine RoutineAnytime) AnyDoctor t0
        `shouldReturn` Right (MovedOn (Accepted t))

    it "an accept after a concurrent reject writes nothing" $ do
      fx <- fixture pool
      s  <- submit pool fx
      -- Meanwhile: rejected.
      Right (Transitioned _) <- S.rejectSubmittedIntakeRequest pool s.id t0 "no"
      let t = acceptIntakeRequest s fx.service.id (Routine RoutineAnytime) AnyDoctor t0
      withResource pool (\c -> P.persistTriagedIntakeRequest c t) `shouldReturn` AlreadyClaimed
      stateOf pool s.id `shouldReturn` "rejected"

    it "a reject of an already accepted request writes nothing" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      withResource pool (\c -> P.persistRejectedIntakeRequest c t.submitted t0 "no")
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

    it "matching an already booked request reports the booking" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      later     <- slotAt pool fx (minutes 60 t0)
      S.matchAcceptedIntakeRequestToSlot pool a.triaged.submitted.id later.id
        `shouldReturn` Right (RequestMovedOn (Appointed a))

    it "the same slot can't be matched twice" $ do
      fx           <- fixture pool
      (_, slot, _) <- appoint pool fx t0
      other        <- accept pool fx AnyDoctor
      S.matchAcceptedIntakeRequestToSlot pool other.submitted.id slot.id `shouldReturn` Right SlotAlreadyClaimed
      stateOf pool other.submitted.id `shouldReturn` "accepted"

    it "rolls the slot delete back when the request claim loses" $ do
      fx   <- fixture pool
      t    <- accept pool fx AnyDoctor
      slot <- slotAt pool fx t0
      -- Meanwhile: marked stale.
      Right (Transitioned _) <- S.markIntakeRequestStale pool t.submitted.id t0
      Just appointed <- pure (matchIntakeRequestToSlot slot t)
      withResource pool (\c -> P.persistMatchedIntakeRequest c slot.id appointed)
        `shouldReturn` RequestAlreadyMatched
      withResource pool (\c -> P.fetchSlot c slot.id) `shouldReturn` Right (Just slot)
      stateOf pool t.submitted.id `shouldReturn` "stale"

  describe "close / stale" $ do
    it "cancelling an appointment frees its time" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      let rid       = a.triaged.submitted.id
          cancelled = Cancelled ByDoctor t0 Nothing
      S.closeAppointedIntakeRequest pool rid cancelled `shouldReturn` Right (Transitioned (Closed a cancelled))
      stateOf pool rid `shouldReturn` "closed"
      Right (SlotCreated _) <- S.createAvailableSlot pool fx.doctor.id fx.service.id t0
      pure ()

    it "closing twice: the second close reports the first one's reason" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      let rid       = a.triaged.submitted.id
          cancelled = Cancelled ByPatient t0 Nothing
      S.closeAppointedIntakeRequest pool rid cancelled `shouldReturn` Right (Transitioned (Closed a cancelled))
      S.closeAppointedIntakeRequest pool rid Completed `shouldReturn` Right (MovedOn (Closed a cancelled))

    it "closing a request that is still accepted is the wrong state" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.closeAppointedIntakeRequest pool t.submitted.id Completed
        `shouldReturn` Left (RequestInWrongState (Accepted t))

    it "mark stale works from accepted; from submitted it is the wrong state" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.markIntakeRequestStale pool t.submitted.id t0 `shouldReturn` Right (Transitioned t)
      s  <- submit pool fx
      S.markIntakeRequestStale pool s.id t0 `shouldReturn` Left (RequestInWrongState (Submitted s))

  describe "unknown ids" $ do
    it "submitting for an unknown patient is PatientNotFound, and nothing is stored" $ do
      unknown <- PatientId <$> nextRandom
      S.submitIntakeRequest pool unknown "needs care" t0 `shouldReturn` Left (PatientNotFound unknown)
      S.fetchSubmittedIntakeRequests pool `shouldReturn` Right []

    it "accepting with an unknown service is HealthcareServiceNotFound, and it stays submitted" $ do
      fx      <- fixture pool
      s       <- submit pool fx
      unknown <- HealthcareServiceId <$> nextRandom
      S.acceptSubmittedIntakeRequest pool s.id unknown (Routine RoutineAnytime) AnyDoctor t0
        `shouldReturn` Left (HealthcareServiceNotFound unknown)
      stateOf pool s.id `shouldReturn` "submitted"

    it "accepting with an unknown required doctor is DoctorNotFound, and it stays submitted" $ do
      fx      <- fixture pool
      s       <- submit pool fx
      unknown <- DoctorId <$> nextRandom
      S.acceptSubmittedIntakeRequest pool s.id fx.service.id (Routine RoutineAnytime) (SpecificDoctor unknown) t0
        `shouldReturn` Left (DoctorNotFound unknown)
      stateOf pool s.id `shouldReturn` "submitted"

    it "creating a slot for an unknown doctor is DoctorNotFound" $ do
      fx      <- fixture pool
      unknown <- DoctorId <$> nextRandom
      S.createAvailableSlot pool unknown fx.service.id t0 `shouldReturn` Left (DoctorNotFound unknown)

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
