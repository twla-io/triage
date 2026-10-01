{-# LANGUAGE OverloadedStrings #-}

-- Schema tests: the CHECK constraints on intake_requests, in raw SQL against
-- a real PostgreSQL. No dependency on the triage library — the threat these
-- constraints exist for is a write that bypasses Persistence.hs, so the
-- tests write around it too.
--
-- The classification table below is written from Domain.hs, not from the
-- migration: for each IntakeRequest case, each column is required, NULL, or
-- optional (a Maybe field, or governed by a nested type's own CHECK). The
-- tests check the migration against it; either one being wrong fails here.
--
-- Creates a throwaway database, applies TRIAGE_SCHEMA_FILE (default
-- migrations/0001_init.sql), drops it at the end. TRIAGE_TEST_PG holds extra
-- libpq keywords, as for triage-db-test.

module Main (main) where

import Control.Exception          (bracket, try)
import Data.ByteString            (ByteString)
import Data.List                  (sort, (\\))
import Data.Maybe                 (fromMaybe)
import Data.String                (fromString)
import Database.PostgreSQL.Simple (Connection, Only (..), SqlError (..), begin, close,
                                   connectPostgreSQL, execute_, query_, rollback)
import System.Environment         (lookupEnv)
import Test.Hspec

import qualified Data.UUID    as UUID
import qualified Data.UUID.V4 as UUID

-- ═══════════════════════════════════════════════════════════════════════════
-- CLASSIFICATION (from Domain.hs)
-- ═══════════════════════════════════════════════════════════════════════════

-- R: required · N: must be NULL · O: optional
data Cell = R | N | O
  deriving (Eq, Show)

-- The IntakeRequest cases, WithdrawnFrom split in two.
cases :: [String]
cases =
  [ "submitted", "rejected", "accepted", "appointed"
  , "withdrawn_from_submitted", "withdrawn_from_accepted", "stale", "closed" ]

-- NOT NULL in the table itself: present in every case.
baseColumns :: [String]
baseColumns = ["id", "state", "patient_id", "narrative", "created_at"]

--                                        sub rej acc app wfs wfa sta clo
classification :: [(String, [Cell])]
classification =
  [ ("rejected_at",           [N,  R,  N,  N,  N,  N,  N,  N])
  , ("rejection_reason",      [N,  R,  N,  N,  N,  N,  N,  N])
  , ("healthcare_service_id", [N,  N,  R,  R,  N,  R,  R,  R])
  , ("priority",              [N,  N,  R,  R,  N,  R,  R,  R])
  , ("triaged_at",            [N,  N,  R,  R,  N,  R,  R,  R])
  , ("must_be_seen_by",       [N,  N,  O,  O,  N,  O,  O,  O])
  , ("routine_not_before",    [N,  N,  O,  O,  N,  O,  O,  O])
  , ("routine_not_after",     [N,  N,  O,  O,  N,  O,  O,  O])
  , ("specific_doctor_id",    [N,  N,  O,  O,  N,  O,  O,  O])
  , ("doctor_id",             [N,  N,  N,  R,  N,  N,  N,  R])
  , ("start",                 [N,  N,  N,  R,  N,  N,  N,  R])
  , ("duration",              [N,  N,  N,  R,  N,  N,  N,  R])
  , ("withdrawn_at",          [N,  N,  N,  N,  R,  R,  N,  N])
  , ("withdrawal_note",       [N,  N,  N,  N,  O,  O,  N,  N])
  , ("stale_at",              [N,  N,  N,  N,  N,  N,  R,  N])
  , ("cancelled_by",          [N,  N,  N,  N,  N,  N,  N,  O])
  , ("cancelled_at",          [N,  N,  N,  N,  N,  N,  N,  O])
  , ("cancellation_note",     [N,  N,  N,  N,  N,  N,  N,  O])
  , ("absent_party",          [N,  N,  N,  N,  N,  N,  N,  O])
  ]

cellFor :: String -> String -> Cell
cellFor column caseName =
  case (lookup column classification, lookup caseName (zip cases [0 :: Int ..])) of
    (Just cells, Just i) -> cells !! i
    _                    -> error ("unclassified: " ++ column ++ " / " ++ caseName)

-- ═══════════════════════════════════════════════════════════════════════════
-- FIXTURE
-- ═══════════════════════════════════════════════════════════════════════════

lit :: String -> String
lit s = "'" ++ s ++ "'"

doctorId, patientId, serviceId, requestId :: String
doctorId  = "00000000-0000-0000-0000-0000000000d1"
patientId = "00000000-0000-0000-0000-0000000000b1"
serviceId = "00000000-0000-0000-0000-0000000000a1"
requestId = "00000000-0000-0000-0000-0000000000e1"

-- A value valid on its own for each column, so a rejection can only come
-- from the row's shape.
sampleValue :: String -> String
sampleValue column = fromMaybe (error ("no sample value: " ++ column)) (lookup column samples)
  where
    samples =
      [ ("rejected_at", "now()"), ("rejection_reason", "'x'")
      , ("healthcare_service_id", lit serviceId), ("priority", "'routine'")
      , ("triaged_at", "now()"), ("must_be_seen_by", "now()")
      , ("routine_not_before", "now()"), ("routine_not_after", "now()")
      , ("specific_doctor_id", lit doctorId), ("doctor_id", lit doctorId)
      , ("start", "'2026-10-01 09:00+00'"), ("duration", "30")
      , ("withdrawn_at", "now()"), ("withdrawal_note", "'x'"), ("stale_at", "now()")
      , ("cancelled_by", "'patient_party'"), ("cancelled_at", "now()")
      , ("cancellation_note", "'x'"), ("absent_party", "'patient_party'") ]

-- One valid row per case: the base, plus exactly the required columns.
validRow :: String -> [(String, String)]
validRow caseName =
  [ ("id", lit requestId), ("state", lit stateValue), ("patient_id", lit patientId)
  , ("narrative", "'needs care'"), ("created_at", "now()") ]
  ++ [ (column, sampleValue column) | (column, _) <- classification, cellFor column caseName == R ]
  where
    stateValue = case caseName of
      "withdrawn_from_submitted" -> "withdrawn"
      "withdrawn_from_accepted"  -> "withdrawn"
      other                      -> other

insertRow :: Connection -> [(String, String)] -> IO ()
insertRow conn row = () <$ execute_ conn (fromString sql)
  where
    sql = "INSERT INTO intake_requests (" ++ commaSep (map fst row) ++ ") VALUES ("
          ++ commaSep (map snd row) ++ ")"
    commaSep = foldr1 (\a b -> a ++ ", " ++ b)

-- Runs one change inside a transaction that is always rolled back.
-- Nothing = the database accepted it; Just code = rejected with that SQLSTATE.
attempt :: Connection -> String -> IO (Maybe ByteString)
attempt conn sql = do
  begin conn
  result <- try (execute_ conn (fromString sql))
  rollback conn
  pure $ case result of
    Right _ -> Nothing
    Left e  -> Just (sqlState e)

setOnRow :: String -> String
setOnRow assignments =
  "UPDATE intake_requests SET " ++ assignments ++ " WHERE id = " ++ lit requestId

checkViolation :: ByteString
checkViolation = "23514"

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEC
-- ═══════════════════════════════════════════════════════════════════════════

spec :: Connection -> Spec
spec conn = do
  describe "intake_requests columns" $ do
    it "every column is classified, and every classified column exists" $ do
      actual <- map fromOnly <$> query_ conn
        "SELECT column_name::text FROM information_schema.columns \
        \WHERE table_name = 'intake_requests'"
      let expected = baseColumns ++ map fst classification
      (sort actual \\ expected, sort expected \\ actual) `shouldBe` ([], [])

    it "the base columns are NOT NULL in the table itself" $ do
      nullable <- map fromOnly <$> query_ conn
        "SELECT column_name::text FROM information_schema.columns \
        \WHERE table_name = 'intake_requests' AND is_nullable = 'YES'"
      filter (`elem` nullable) baseColumns `shouldBe` []

  describe "each case's shape" $
    mapM_ caseShape cases

  describe "priority (nested sum)" $ do
    let onAccepted = before_ (insertRow conn (validRow "accepted"))
    onAccepted $ do
      it "emergency without must_be_seen_by is rejected" $
        attempt conn (setOnRow "priority = 'emergency'") `shouldReturn` Just checkViolation
      it "urgent with a routine bound is rejected" $
        attempt conn (setOnRow "priority = 'urgent', must_be_seen_by = now(), routine_not_after = now()")
          `shouldReturn` Just checkViolation
      it "routine with must_be_seen_by is rejected" $
        attempt conn (setOnRow "must_be_seen_by = now()") `shouldReturn` Just checkViolation
      it "a routine window ending before it starts is rejected" $
        attempt conn (setOnRow "routine_not_before = '2026-10-02', routine_not_after = '2026-10-01'")
          `shouldReturn` Just checkViolation
      it "valid priorities are accepted" $ do
        attempt conn (setOnRow "priority = 'emergency', must_be_seen_by = now()") `shouldReturn` Nothing
        attempt conn (setOnRow "routine_not_before = '2026-10-01', routine_not_after = '2026-10-02'")
          `shouldReturn` Nothing
        attempt conn (setOnRow ("specific_doctor_id = " ++ lit doctorId)) `shouldReturn` Nothing

  describe "close reason (nested sum)" $ do
    let onClosed = before_ (insertRow conn (validRow "closed"))
    onClosed $ do
      it "a note without a cancellation is rejected" $
        attempt conn (setOnRow "cancellation_note = 'x'") `shouldReturn` Just checkViolation
      it "cancelled_by without cancelled_at is rejected" $
        attempt conn (setOnRow "cancelled_by = 'doctor_party'") `shouldReturn` Just checkViolation
      it "cancelled_at without cancelled_by is rejected" $
        attempt conn (setOnRow "cancelled_at = now()") `shouldReturn` Just checkViolation
      it "an absence together with a cancellation is rejected" $
        attempt conn (setOnRow "cancelled_by = 'doctor_party', cancelled_at = now(), absent_party = 'patient_party'")
          `shouldReturn` Just checkViolation
      it "completed, cancelled (with or without a note) and no-show are accepted" $ do
        attempt conn (setOnRow "cancelled_by = 'doctor_party', cancelled_at = now()") `shouldReturn` Nothing
        attempt conn (setOnRow "cancelled_by = 'doctor_party', cancelled_at = now(), cancellation_note = 'x'")
          `shouldReturn` Nothing
        attempt conn (setOnRow "absent_party = 'patient_party'") `shouldReturn` Nothing
  where
    caseShape caseName =
      it (caseName ++ ": a valid row is accepted; a stray or missing value is rejected") $ do
        insertRow conn (validRow caseName)
        wrong <- concat <$> mapM (probe caseName) classification
        wrong `shouldBe` []

    -- The columns whose change the database got wrong, labelled.
    probe caseName (column, _) =
      case cellFor column caseName of
        N -> expectRejected ("stray " ++ column)   (column ++ " = " ++ sampleValue column)
        R -> expectRejected ("missing " ++ column) (column ++ " = NULL")
        O -> pure []

    expectRejected label assignment = do
      outcome <- attempt conn (setOnRow assignment)
      pure [label ++ " was " ++ describeOutcome outcome | outcome /= Just checkViolation]

    describeOutcome Nothing     = "accepted"
    describeOutcome (Just code) = "rejected with " ++ show code ++ ", not a CHECK"

-- ═══════════════════════════════════════════════════════════════════════════
-- THROWAWAY DATABASE
-- ═══════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
  base       <- fromMaybe "" <$> lookupEnv "TRIAGE_TEST_PG"
  schemaFile <- fromMaybe "migrations/0001_init.sql" <$> lookupEnv "TRIAGE_SCHEMA_FILE"
  dbName     <- ("triage_schema_" ++) . take 12 . filter (/= '-') . UUID.toString <$> UUID.nextRandom
  let admin  = base ++ " dbname=postgres"
      testDb = base ++ " dbname=" ++ dbName
  bracket (createDatabase admin dbName testDb schemaFile) (dropDatabase admin dbName) $ \conn ->
    hspec (before_ (resetTables conn) (spec conn))

createDatabase :: String -> String -> String -> FilePath -> IO Connection
createDatabase admin dbName testDb schemaFile = do
  _ <- withConnection admin $ \c -> execute_ c (fromString ("CREATE DATABASE " ++ dbName))
  schema <- readFile schemaFile
  conn   <- connectPostgreSQL (fromString testDb)
  _ <- execute_ conn (fromString schema)
  pure conn

dropDatabase :: String -> String -> Connection -> IO ()
dropDatabase admin dbName conn = do
  close conn
  _ <- withConnection admin $ \c -> execute_ c (fromString ("DROP DATABASE " ++ dbName ++ " WITH (FORCE)"))
  pure ()

withConnection :: String -> (Connection -> IO a) -> IO a
withConnection conninfo = bracket (connectPostgreSQL (fromString conninfo)) close

-- Every test starts from one doctor, patient and service, and no requests.
resetTables :: Connection -> IO ()
resetTables conn = do
  _ <- execute_ conn "TRUNCATE doctor_calendar, available_slots, intake_requests, healthcare_services, patients, doctors CASCADE"
  _ <- execute_ conn (fromString ("INSERT INTO doctors VALUES (" ++ lit doctorId ++ ", 'Dr D')"))
  _ <- execute_ conn (fromString ("INSERT INTO patients VALUES (" ++ lit patientId ++ ", 'Patient P')"))
  _ <- execute_ conn (fromString ("INSERT INTO healthcare_services VALUES (" ++ lit serviceId ++ ", 'Consultation', 30)"))
  pure ()
