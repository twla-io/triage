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

import Control.Concurrent         (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception          (bracket, try)
import Control.Monad              (forM_)
import Data.Maybe                 (fromMaybe)
import Data.Pool                  (defaultPoolConfig, destroyAllResources, newPool, withResource)
import Data.String                (fromString)
import Data.Text                  (Text)
import Data.Time                  (UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID.V4               (nextRandom)
import Database.PostgreSQL.Simple (Connection, Only (..), SqlError (..), begin, close,
                                   connectPostgreSQL, execute, execute_, query_)
import System.Environment         (lookupEnv)
import System.Timeout             (timeout)
import Test.Hspec

import qualified Data.UUID  as UUID
import qualified Persistence as P
import qualified Service    as S

import Domain
import Persistence (ClaimOutcome (..), ConnectionPool)
import Service     (MatchIntakeRequestToSlotOutcome (..), MatchByPriorityOutcome (..),
                    AddAvailableSlotOutcome (..), TransitionOutcome (..))

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
    "TRUNCATE doctor_calendar, available_slots, intake_requests, healthcare_services, patients, doctors CASCADE"
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
  Fixture <$> S.createDoctor pool (named "Dr A")
          <*> S.createPatient pool (named "Patient P")
          <*> S.createHealthcareService pool (named "Consultation") HalfAnHour

-- A fixture's name: mkName on a literal that isn't blank.
named :: Text -> Name
named t = fromMaybe (error ("mkName refused " ++ show t)) (mkName t)

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
  Right (AvailableSlotAdded slot) <- S.createAvailableSlot pool fx.doctor.id fx.service.id at
  pure slot

appoint :: ConnectionPool -> Fixture -> UTCTime -> IO (TriagedIntakeRequest, AvailableSlot, AppointedIntakeRequest)
appoint pool fx at = do
  t    <- accept pool fx AnyDoctor
  slot <- slotAt pool fx at
  Right (IntakeRequestMatchedToSlot a) <- S.matchAcceptedIntakeRequestToSlot pool t.submitted.id slot.id
  pure (t, slot, a)

-- Waits until a session is queued for a lock on intake_requests. pg_locks is
-- live, unlike pg_stat_activity, which is fixed for the rest of a transaction.
waitForBlockedRead :: Connection -> IO ()
waitForBlockedRead c = go (50 :: Int)
  where
    go 0 = expectationFailure "the calendar read never blocked on intake_requests"
    go n = do
      [Only blocked] <- query_ c
        "SELECT EXISTS (SELECT 1 FROM pg_locks \
        \WHERE relation = 'intake_requests'::regclass AND NOT granted)"
      if blocked then pure () else threadDelay 100000 >> go (n - 1)

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
      let rejected = RejectedIntakeRequest { submitted = t.submitted, rejectedAt = t0, rejectionReason = "no" }
      withResource pool (\c -> P.persistRejectedIntakeRequest c rejected) `shouldReturn` AlreadyClaimed
      stateOf pool t.submitted.id `shouldReturn` "accepted"

  describe "withdraw" $ do
    it "withdraws a submitted request" $ do
      fx <- fixture pool
      s  <- submit pool fx
      S.withdrawIntakeRequest pool s.id t0 Nothing
        `shouldReturn` Right (Transitioned (WithdrawnIntakeRequest (FromSubmitted s) t0 Nothing))
      stateOf pool s.id `shouldReturn` "withdrawn"

    it "withdraws an accepted request from where it is, with its triage" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.withdrawIntakeRequest pool t.submitted.id t0 (Just "feeling better")
        `shouldReturn` Right (Transitioned (WithdrawnIntakeRequest (FromAccepted t) t0 (Just "feeling better")))
      stored pool t.submitted.id
        `shouldReturn` Withdrawn (WithdrawnIntakeRequest (FromAccepted t) t0 (Just "feeling better"))

    it "withdrawing an appointed request reports it moved on" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      S.withdrawIntakeRequest pool a.triaged.submitted.id t0 Nothing
        `shouldReturn` Right (MovedOn (Appointed a))

  describe "slots" $ do
    it "an overlapping slot is a conflict; a touching one is fine" $ do
      fx <- fixture pool
      _  <- slotAt pool fx t0
      S.createAvailableSlot pool fx.doctor.id fx.service.id (minutes 15 t0)
        `shouldReturn` Right AvailableSlotOverlapsDoctorCalendar
      Right (AvailableSlotAdded _) <- S.createAvailableSlot pool fx.doctor.id fx.service.id (minutes 30 t0)
      pure ()

    it "the database rejects an overlap even when the Domain check is bypassed" $ do
      fx      <- fixture pool
      _       <- slotAt pool fx t0
      otherId <- SlotId <$> nextRandom
      let overlapping = AvailableSlot
            { id = otherId, doctorId = fx.doctor.id, healthcareServiceId = fx.service.id
            , start = minutes 15 t0, duration = HalfAnHour }
      withResource pool (\c -> P.insertAvailableSlot c overlapping)
        `shouldReturn` P.AvailableSlotOverlapsDoctorCalendar

    it "the new slot takes its duration from the service" $ do
      fx   <- fixture pool
      slot <- slotAt pool fx t0
      slot.duration `shouldBe` fx.service.duration

    it "a slot overlapping another doctor's entry is still created" $ do
      fx      <- fixture pool
      _       <- slotAt pool fx t0
      doctorB <- S.createDoctor pool (named "Dr B")
      Right (AvailableSlotAdded _) <- S.createAvailableSlot pool doctorB.id fx.service.id (minutes 15 t0)
      pure ()

  describe "doctor calendar" $ do
    it "holds every entry overlapping the range, in order of start; touching ones are left out" $ do
      fx        <- fixture pool
      _         <- slotAt pool fx (minutes (-30) t0)
      (_, _, a) <- appoint pool fx t0
      slot      <- slotAt pool fx (minutes 60 t0)
      _         <- slotAt pool fx (minutes 120 t0)
      calendar  <- S.fetchDoctorCalendarOverlapping pool t0 (minutes 120 t0)
      doctorCalendarEntries calendar `shouldBe` [Appointment a, Slot slot]

    it "the calendar read sees one moment while a match commits between its queries" $ do
      fx             <- fixture pool
      t              <- accept pool fx AnyDoctor
      slot           <- slotAt pool fx t0
      Just appointed <- pure (matchIntakeRequestToSlot slot t)
      result         <- newEmptyMVar
      withResource pool $ \gate -> do
        -- Holds the read's second query (intake_requests) after its first
        -- (available_slots) has seen the slot.
        begin gate
        _ <- execute_ gate "LOCK TABLE intake_requests IN ACCESS EXCLUSIVE MODE"
        _ <- forkIO $
          withResource pool (\c -> P.fetchDoctorCalendarOverlapping c t0 (minutes 30 t0))
            >>= putMVar result
        waitForBlockedRead gate
        -- Inside the open transaction, the write's own BEGIN only warns; its
        -- COMMIT commits the match and releases the lock at once.
        P.persistAppointedIntakeRequest gate slot appointed `shouldReturn` P.AppointedClaimed
      Just calendar <- timeout 5000000 (takeMVar result)
      fmap doctorCalendarEntries calendar `shouldBe` Right [Slot slot]

  describe "match" $ do
    it "books the request and consumes the slot" $ do
      fx           <- fixture pool
      (_, slot, a) <- appoint pool fx t0
      stateOf pool a.triaged.submitted.id `shouldReturn` "appointed"
      S.fetchAvailableSlot pool slot.id `shouldReturn` Nothing

    it "matching an already booked request reports the booking" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      later     <- slotAt pool fx (minutes 60 t0)
      S.matchAcceptedIntakeRequestToSlot pool a.triaged.submitted.id later.id
        `shouldReturn` Right (IntakeRequestMovedOn (Appointed a))

    it "the same slot can't be matched twice" $ do
      fx           <- fixture pool
      (_, slot, _) <- appoint pool fx t0
      other        <- accept pool fx AnyDoctor
      S.matchAcceptedIntakeRequestToSlot pool other.submitted.id slot.id
        `shouldReturn` Right (AvailableSlotConsumed slot.id)
      stateOf pool other.submitted.id `shouldReturn` "accepted"

    it "rolls the slot delete back when the request claim loses" $ do
      fx   <- fixture pool
      t    <- accept pool fx AnyDoctor
      slot <- slotAt pool fx t0
      -- Meanwhile: marked stale.
      Right (Transitioned _) <- S.markAcceptedIntakeRequestStale pool t.submitted.id t0
      Just appointment <- pure (matchIntakeRequestToSlot slot t)
      withResource pool (\c -> P.persistAppointedIntakeRequest c slot appointment)
        `shouldReturn` P.IntakeRequestAlreadyClaimed
      S.fetchAvailableSlot pool slot.id `shouldReturn` (Just slot)
      stateOf pool t.submitted.id `shouldReturn` "stale"

    it "a request and slot that don't fit are the caller's mistake" $ do
      fx    <- fixture pool
      other <- S.createHealthcareService pool (named "Other service") HalfAnHour
      s     <- submit pool fx
      Right (Transitioned t) <-
        S.acceptSubmittedIntakeRequest pool s.id other.id (Routine RoutineAnytime) AnyDoctor t0
      slot  <- slotAt pool fx t0
      S.matchAcceptedIntakeRequestToSlot pool t.submitted.id slot.id
        `shouldReturn` Left (S.MatchAcceptedIntakeRequestToSlotIntakeRequestDoesNotMatchSlot S.IntakeRequestDoesNotMatchSlot)

  describe "match by priority" $ do
    it "gives the slot to the waiting request that fits" $ do
      fx   <- fixture pool
      t    <- accept pool fx AnyDoctor
      slot <- slotAt pool fx t0
      (MatchIntakeRequestToSlotOutcome (IntakeRequestMatchedToSlot a)) <- S.matchAvailableSlotByPriority pool slot.id
      a.triaged `shouldBe` t
      stateOf pool t.submitted.id `shouldReturn` "appointed"

    it "with nothing waiting, the slot stays available" $ do
      fx   <- fixture pool
      slot <- slotAt pool fx t0
      S.matchAvailableSlotByPriority pool slot.id `shouldReturn` NoIntakeRequestMatched
      S.fetchAvailableSlot pool slot.id `shouldReturn` (Just slot)

  describe "close / stale" $ do
    it "cancelling an appointment frees its time" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      let rid       = a.triaged.submitted.id
          cancelled = Cancelled (Cancellation DoctorParty t0 Nothing)
      S.closeAppointedIntakeRequest pool rid cancelled
        `shouldReturn` Right (Transitioned (ClosedIntakeRequest a cancelled))
      stateOf pool rid `shouldReturn` "closed"
      Right (AvailableSlotAdded _) <- S.createAvailableSlot pool fx.doctor.id fx.service.id t0
      pure ()

    it "closing twice: the second close reports the first one's reason" $ do
      fx        <- fixture pool
      (_, _, a) <- appoint pool fx t0
      let rid       = a.triaged.submitted.id
          cancelled = Cancelled (Cancellation PatientParty t0 Nothing)
      S.closeAppointedIntakeRequest pool rid cancelled
        `shouldReturn` Right (Transitioned (ClosedIntakeRequest a cancelled))
      S.closeAppointedIntakeRequest pool rid Completed
        `shouldReturn` Right (MovedOn (Closed (ClosedIntakeRequest a cancelled)))

    it "closing a request that is still accepted is the wrong state" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.closeAppointedIntakeRequest pool t.submitted.id Completed
        `shouldReturn` Left (S.CloseAppointedIntakeRequestIntakeRequestInWrongState (S.IntakeRequestInWrongState (Accepted t)))

    it "mark stale works from accepted; from submitted it is the wrong state" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      S.markAcceptedIntakeRequestStale pool t.submitted.id t0
        `shouldReturn` Right (Transitioned (StaleIntakeRequest t t0))
      s  <- submit pool fx
      S.markAcceptedIntakeRequestStale pool s.id t0
        `shouldReturn` Left (S.MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState (S.IntakeRequestInWrongState (Submitted s)))

    it "a request withdrawn before triage was never accepted: marking it stale is the wrong state" $ do
      fx <- fixture pool
      s  <- submit pool fx
      Right (Transitioned w) <- S.withdrawIntakeRequest pool s.id t0 Nothing
      S.markAcceptedIntakeRequestStale pool s.id t0
        `shouldReturn` Left (S.MarkAcceptedIntakeRequestStaleIntakeRequestInWrongState (S.IntakeRequestInWrongState (Withdrawn w)))

  describe "unknown ids" $ do
    it "submitting for an unknown patient is PatientNotFound, and nothing is stored" $ do
      unknown <- PatientId <$> nextRandom
      S.submitIntakeRequest pool unknown "needs care" t0 `shouldReturn` Left (S.PatientNotFound unknown)
      S.fetchSubmittedIntakeRequests pool `shouldReturn` []

    it "accepting with an unknown service is HealthcareServiceNotFound, and it stays submitted" $ do
      fx      <- fixture pool
      s       <- submit pool fx
      unknown <- HealthcareServiceId <$> nextRandom
      S.acceptSubmittedIntakeRequest pool s.id unknown (Routine RoutineAnytime) AnyDoctor t0
        `shouldReturn` Left (S.AcceptSubmittedIntakeRequestHealthcareServiceNotFound (S.HealthcareServiceNotFound unknown))
      stateOf pool s.id `shouldReturn` "submitted"

    it "accepting with an unknown required doctor is DoctorNotFound, and it stays submitted" $ do
      fx      <- fixture pool
      s       <- submit pool fx
      unknown <- DoctorId <$> nextRandom
      S.acceptSubmittedIntakeRequest pool s.id fx.service.id (Routine RoutineAnytime) (SpecificDoctor unknown) t0
        `shouldReturn` Left (S.AcceptSubmittedIntakeRequestDoctorNotFound (S.DoctorNotFound unknown))
      stateOf pool s.id `shouldReturn` "submitted"

    it "creating a slot for an unknown doctor is DoctorNotFound" $ do
      fx      <- fixture pool
      unknown <- DoctorId <$> nextRandom
      S.createAvailableSlot pool unknown fx.service.id t0 `shouldReturn` Left (S.CreateAvailableSlotDoctorNotFound (S.DoctorNotFound unknown))

    it "reading an unknown request is IntakeRequestNotFound" $ do
      unknown <- IntakeRequestId <$> nextRandom
      S.fetchIntakeRequest pool unknown `shouldReturn` Left (S.IntakeRequestNotFound unknown)

  describe "constraints" $ do
    it "a submitted request can't carry a decided doctor requirement" $ do
      fx <- fixture pool
      s  <- submit pool fx
      let IntakeRequestId rid = s.id
          DoctorId did        = fx.doctor.id
      result <- try (withResource pool (\c ->
        execute c "UPDATE intake_requests SET specific_doctor_id = ? WHERE id = ?" (did, rid)))
      case result of
        Left e  -> sqlState e `shouldBe` "23514"   -- check_violation
        Right n -> expectationFailure ("the update was accepted (" ++ show n ++ " row)")

    it "a routine window can't end before it starts" $ do
      fx <- fixture pool
      t  <- accept pool fx AnyDoctor
      let IntakeRequestId rid = t.submitted.id
      result <- try (withResource pool (\c ->
        execute c "UPDATE intake_requests SET routine_not_before = ?, routine_not_after = ? WHERE id = ?"
          (minutes 60 t0, t0, rid)))
      case result of
        Left e  -> sqlState e `shouldBe` "23514"   -- check_violation
        Right n -> expectationFailure ("the update was accepted (" ++ show n ++ " row)")

    it "a name can't be empty or only whitespace" $ do
      _ <- fixture pool
      forM_ ["doctors", "patients", "healthcare_services"] $ \table ->
        forM_ ["", " \t\n"] $ \blank -> do
          result <- try (withResource pool (\c ->
            execute c (fromString ("UPDATE " ++ table ++ " SET name = ?")) (Only (blank :: String))))
          case result of
            Left e  -> sqlState e `shouldBe` "23514"   -- check_violation
            Right n -> expectationFailure (table ++ ": the update was accepted (" ++ show n ++ " row)")
