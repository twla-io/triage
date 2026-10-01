{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

-- Derived from src/Domain.hs by the triage-db-codegen skill; schema in
-- migrations/0001_init.sql.
module Persistence
  ( -- ── Connections ──────────────────────────────────────────────────────
    ConnectionPool

    -- ── Outcomes / errors ────────────────────────────────────────────────
  , DecodeError (..)
  , ClaimOutcome (..)
  , MatchClaimOutcome (..)
  , SlotInsertOutcome (..)

    -- ── Rows ─────────────────────────────────────────────────────────────
  , DoctorRow (..)
  , PatientRow (..)
  , HealthcareServiceRow (..)
  , IntakeRequestRow (..)
  , AvailableSlotRow (..)

    -- ── Decoding / encoding ──────────────────────────────────────────────
  , toDomainDoctor
  , fromDomainDoctor
  , toDomainPatient
  , fromDomainPatient
  , toDomainHealthcareService
  , fromDomainHealthcareService
  , toDomainAvailableSlot
  , fromDomainAvailableSlot
  , toDomainIntakeRequest
  , toDomainSubmittedIntakeRequest
  , toDomainRejectedIntakeRequest
  , toDomainTriagedIntakeRequest
  , toDomainAppointedIntakeRequest
  , toDomainWithdrawnIntakeRequest
  , toDomainStaleIntakeRequest
  , toDomainClosedIntakeRequest
  , fromDomainSubmittedIntakeRequest
  , fromDomainRejectedIntakeRequest
  , fromDomainTriagedIntakeRequest
  , fromDomainAppointedIntakeRequest
  , fromDomainWithdrawnIntakeRequest
  , fromDomainStaleIntakeRequest
  , fromDomainClosedIntakeRequest

    -- ── Reads ────────────────────────────────────────────────────────────
  , fetchDoctor
  , fetchDoctors
  , fetchPatient
  , fetchPatients
  , fetchHealthcareService
  , fetchHealthcareServices
  , fetchAvailableSlot
  , fetchIntakeRequest
  , fetchSubmittedIntakeRequests
  , fetchAcceptedIntakeRequests
  , fetchAppointedIntakeRequests
  , fetchRejectedIntakeRequestsByRejectedAt
  , fetchWithdrawnIntakeRequestsByWithdrawnAt
  , fetchStaleIntakeRequestsByStaleAt
  , fetchClosedIntakeRequestsByStart
  , fetchDoctorCalendarOverlapping
  , fetchDoctorCalendarEntriesOverlapping

    -- ── Writes ───────────────────────────────────────────────────────────
  , insertDoctor
  , insertPatient
  , insertHealthcareService
  , insertSubmittedIntakeRequest
  , insertAvailableSlot
  , persistTriagedIntakeRequest
  , persistRejectedIntakeRequest
  , persistAppointedIntakeRequest
  , persistWithdrawnIntakeRequest
  , persistStaleIntakeRequest
  , persistClosedIntakeRequest
  ) where

import Control.Exception                    (Exception, handle, throwIO, try)
import Data.Char                            (isUpper, toLower)
import Data.Int                             (Int16, Int64)
import Data.List                            (sortOn)
import Data.Maybe                           (isJust)
import Data.Pool                            (Pool)
import Data.Text                            (Text)
import Data.Time                            (UTCTime, addUTCTime)
import Data.UUID                            (UUID)
import Database.PostgreSQL.Simple
  ( Connection, Only (..), Query, SqlError (..), execute, query, query_, withTransaction )
import Database.PostgreSQL.Simple.FromRow   (FromRow (..), field)
import Database.PostgreSQL.Simple.Transaction (IsolationLevel (..), withTransactionLevel)

import qualified Data.Text as Text

import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- CONNECTIONS
-- ═══════════════════════════════════════════════════════════════════════════

type ConnectionPool = Pool Connection

-- ═══════════════════════════════════════════════════════════════════════════
-- OUTCOMES / ERRORS
-- ═══════════════════════════════════════════════════════════════════════════

-- A stored row that no Domain value can be built from. The first Text of
-- most constructors is the row's state (or table), the second a column.
data DecodeError
  = UnknownState            Text
  | UnexpectedState         Text Text         -- expected, found
  | UnknownPriority         Text
  | UnknownDuration         Int16
  | UnknownAppointmentParty Text
  | MissingColumn           Text Text
  | UnexpectedColumn        Text Text
  | NoCloseReasonMatches    Text
  | InvalidRoutineWindow    UTCTime UTCTime
  | OverlappingDoctorCalendar DoctorId
  deriving (Show, Eq)

-- A single guarded write: the row was still in the case the caller saw.
data ClaimOutcome
  = Claimed
  | AlreadyClaimed
  deriving (Show, Eq)

-- Matching: deleting the consumed slot and moving the request to Appointed.
data MatchClaimOutcome
  = MatchClaimed
  | SlotAlreadyClaimed           -- the slot row was already gone
  | IntakeRequestAlreadyClaimed  -- the request had left Accepted
  deriving (Show, Eq)

-- A new calendar element: the only write that can violate
-- doctor_calendar_no_overlap legitimately.
data SlotInsertOutcome
  = SlotInserted
  | SlotOverlapsDoctorCalendar
  deriving (Show, Eq)

claimOutcome :: Int64 -> ClaimOutcome
claimOutcome 1 = Claimed
claimOutcome _ = AlreadyClaimed

-- Rolls the match transaction back when its second step loses its race.
data IntakeRequestLost = IntakeRequestLost
  deriving Show

instance Exception IntakeRequestLost

-- ═══════════════════════════════════════════════════════════════════════════
-- ENUMERATIONS
-- ═══════════════════════════════════════════════════════════════════════════

snakeCase :: String -> Text
snakeCase = Text.pack . go
  where
    go (c : cs) = toLower c : concatMap step cs
    go []       = []
    step c | isUpper c = ['_', toLower c]
           | otherwise = [c]

-- Duration: whole minutes.
durationMinutes :: Duration -> Int16
durationMinutes d = round (durationToNominalDiffTime d / 60)

decodeDuration :: Int16 -> Either DecodeError Duration
decodeDuration m =
  maybe (Left (UnknownDuration m)) Right
    (lookup m [ (durationMinutes d, d) | d <- [minBound .. maxBound] ])

appointmentPartyValue :: AppointmentParty -> Text
appointmentPartyValue = snakeCase . show

decodeAppointmentParty :: Text -> Either DecodeError AppointmentParty
decodeAppointmentParty t =
  maybe (Left (UnknownAppointmentParty t)) Right
    (lookup t [ (appointmentPartyValue p, p) | p <- [minBound .. maxBound] ])

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorRow = DoctorRow
  { id   :: UUID
  , name :: Text
  }
  deriving (Show, Eq)

instance FromRow DoctorRow where
  fromRow = DoctorRow
    <$> field  -- id
    <*> field  -- name

toDomainDoctor :: DoctorRow -> Doctor
toDomainDoctor row = Doctor { id = DoctorId row.id, name = row.name }

fromDomainDoctor :: Doctor -> DoctorRow
fromDomainDoctor Doctor { id = DoctorId uuid, name } = DoctorRow { id = uuid, name }

data PatientRow = PatientRow
  { id   :: UUID
  , name :: Text
  }
  deriving (Show, Eq)

instance FromRow PatientRow where
  fromRow = PatientRow
    <$> field  -- id
    <*> field  -- name

toDomainPatient :: PatientRow -> Patient
toDomainPatient row = Patient { id = PatientId row.id, name = row.name }

fromDomainPatient :: Patient -> PatientRow
fromDomainPatient Patient { id = PatientId uuid, name } = PatientRow { id = uuid, name }

fetchDoctor :: Connection -> DoctorId -> IO (Maybe Doctor)
fetchDoctor conn (DoctorId uuid) = do
  rows <- query conn "SELECT id, name FROM doctors WHERE id = ?" (Only uuid)
  pure $ case rows of
    [row] -> Just (toDomainDoctor row)
    _     -> Nothing

fetchDoctors :: Connection -> IO [Doctor]
fetchDoctors conn =
  map toDomainDoctor <$> query_ conn "SELECT id, name FROM doctors ORDER BY name"

fetchPatient :: Connection -> PatientId -> IO (Maybe Patient)
fetchPatient conn (PatientId uuid) = do
  rows <- query conn "SELECT id, name FROM patients WHERE id = ?" (Only uuid)
  pure $ case rows of
    [row] -> Just (toDomainPatient row)
    _     -> Nothing

fetchPatients :: Connection -> IO [Patient]
fetchPatients conn =
  map toDomainPatient <$> query_ conn "SELECT id, name FROM patients ORDER BY name"

insertDoctor :: Connection -> Doctor -> IO ()
insertDoctor conn doctor = do
  let row = fromDomainDoctor doctor
  _ <- execute conn "INSERT INTO doctors (id, name) VALUES (?, ?)" (row.id, row.name)
  pure ()

insertPatient :: Connection -> Patient -> IO ()
insertPatient conn patient = do
  let row = fromDomainPatient patient
  _ <- execute conn "INSERT INTO patients (id, name) VALUES (?, ?)" (row.id, row.name)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICE
-- ═══════════════════════════════════════════════════════════════════════════

data HealthcareServiceRow = HealthcareServiceRow
  { id       :: UUID
  , name     :: Text
  , duration :: Int16
  }
  deriving (Show, Eq)

instance FromRow HealthcareServiceRow where
  fromRow = HealthcareServiceRow
    <$> field  -- id
    <*> field  -- name
    <*> field  -- duration

toDomainHealthcareService :: HealthcareServiceRow -> Either DecodeError HealthcareService
toDomainHealthcareService row =
  (\duration -> HealthcareService { id = HealthcareServiceId row.id, name = row.name, duration })
    <$> decodeDuration row.duration

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceRow
fromDomainHealthcareService HealthcareService { id = HealthcareServiceId uuid, name, duration } =
  HealthcareServiceRow { id = uuid, name, duration = durationMinutes duration }

fetchHealthcareService
  :: Connection -> HealthcareServiceId -> IO (Either DecodeError (Maybe HealthcareService))
fetchHealthcareService conn (HealthcareServiceId uuid) = do
  rows <- query conn
    "SELECT id, name, duration FROM healthcare_services WHERE id = ?" (Only uuid)
  pure $ case rows of
    [row] -> Just <$> toDomainHealthcareService row
    _     -> Right Nothing

fetchHealthcareServices :: Connection -> IO (Either DecodeError [HealthcareService])
fetchHealthcareServices conn =
  traverse toDomainHealthcareService
    <$> query_ conn "SELECT id, name, duration FROM healthcare_services ORDER BY name, duration"

insertHealthcareService :: Connection -> HealthcareService -> IO ()
insertHealthcareService conn service = do
  let row = fromDomainHealthcareService service
  _ <- execute conn
    "INSERT INTO healthcare_services (id, name, duration) VALUES (?, ?, ?)"
    (row.id, row.name, row.duration)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT
-- ═══════════════════════════════════════════════════════════════════════════

data AvailableSlotRow = AvailableSlotRow
  { id                  :: UUID
  , doctorId            :: UUID
  , healthcareServiceId :: UUID
  , start               :: UTCTime
  , duration            :: Int16
  }
  deriving (Show, Eq)

instance FromRow AvailableSlotRow where
  fromRow = AvailableSlotRow
    <$> field  -- id
    <*> field  -- doctor_id
    <*> field  -- healthcare_service_id
    <*> field  -- start
    <*> field  -- duration

slotColumns :: Query
slotColumns = "id, doctor_id, healthcare_service_id, start, duration"

toDomainAvailableSlot :: AvailableSlotRow -> Either DecodeError AvailableSlot
toDomainAvailableSlot row =
  (\duration -> AvailableSlot
     { id                  = SlotId row.id
     , doctorId            = DoctorId row.doctorId
     , healthcareServiceId = HealthcareServiceId row.healthcareServiceId
     , start               = row.start
     , duration
     })
    <$> decodeDuration row.duration

fromDomainAvailableSlot :: AvailableSlot -> AvailableSlotRow
fromDomainAvailableSlot
  AvailableSlot { id = SlotId uuid, doctorId = DoctorId doctor
                , healthcareServiceId = HealthcareServiceId service, start, duration } =
  AvailableSlotRow
    { id = uuid, doctorId = doctor, healthcareServiceId = service
    , start, duration = durationMinutes duration }

fetchAvailableSlot :: Connection -> SlotId -> IO (Either DecodeError (Maybe AvailableSlot))
fetchAvailableSlot conn (SlotId uuid) = do
  rows <- query conn ("SELECT " <> slotColumns <> " FROM available_slots WHERE id = ?") (Only uuid)
  pure $ case rows of
    [row] -> Just <$> toDomainAvailableSlot row
    _     -> Right Nothing

-- A new element of the doctor calendar: an overlap is an outcome.
insertAvailableSlot :: Connection -> AvailableSlot -> IO SlotInsertOutcome
insertAvailableSlot conn slot = do
  let row = fromDomainAvailableSlot slot
  result <- try $ execute conn
    "INSERT INTO available_slots (id, doctor_id, healthcare_service_id, start, duration) \
    \VALUES (?, ?, ?, ?, ?)"
    (row.id, row.doctorId, row.healthcareServiceId, row.start, row.duration)
  case result of
    Right _ -> pure SlotInserted
    Left e
      | sqlState e == "23P01" -> pure SlotOverlapsDoctorCalendar
      | otherwise             -> throwIO e

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST
-- ═══════════════════════════════════════════════════════════════════════════

data IntakeRequestRow = IntakeRequestRow
  { state               :: Text
  , id                  :: UUID
  , patientId           :: UUID
  , narrative           :: Text
  , createdAt           :: UTCTime
  , rejectedAt          :: Maybe UTCTime
  , rejectionReason     :: Maybe Text
  , healthcareServiceId :: Maybe UUID
  , priority            :: Maybe Text
  , mustBeSeenBy        :: Maybe UTCTime
  , routineNotBefore    :: Maybe UTCTime
  , routineNotAfter     :: Maybe UTCTime
  , specificDoctorId    :: Maybe UUID
  , triagedAt           :: Maybe UTCTime
  , doctorId            :: Maybe UUID
  , start               :: Maybe UTCTime
  , duration            :: Maybe Int16
  , withdrawnAt         :: Maybe UTCTime
  , withdrawalNote      :: Maybe Text
  , staleAt             :: Maybe UTCTime
  , cancelledBy         :: Maybe Text
  , cancelledAt         :: Maybe UTCTime
  , cancellationNote    :: Maybe Text
  , absentParty         :: Maybe Text
  }
  deriving (Show, Eq)

instance FromRow IntakeRequestRow where
  fromRow = IntakeRequestRow
    <$> field  -- state
    <*> field  -- id
    <*> field  -- patient_id
    <*> field  -- narrative
    <*> field  -- created_at
    <*> field  -- rejected_at
    <*> field  -- rejection_reason
    <*> field  -- healthcare_service_id
    <*> field  -- priority
    <*> field  -- must_be_seen_by
    <*> field  -- routine_not_before
    <*> field  -- routine_not_after
    <*> field  -- specific_doctor_id
    <*> field  -- triaged_at
    <*> field  -- doctor_id
    <*> field  -- start
    <*> field  -- duration
    <*> field  -- withdrawn_at
    <*> field  -- withdrawal_note
    <*> field  -- stale_at
    <*> field  -- cancelled_by
    <*> field  -- cancelled_at
    <*> field  -- cancellation_note
    <*> field  -- absent_party

intakeRequestColumns :: Query
intakeRequestColumns =
  "state, id, patient_id, narrative, created_at, rejected_at, rejection_reason, \
  \healthcare_service_id, priority, must_be_seen_by, routine_not_before, \
  \routine_not_after, specific_doctor_id, triaged_at, doctor_id, start, duration, \
  \withdrawn_at, withdrawal_note, stale_at, cancelled_by, cancelled_at, \
  \cancellation_note, absent_party"

-- ── Column groups, one per stage (and CloseReason) ─────────────────────────

rejectedColumns, triagedColumns, appointedColumns, withdrawnColumns,
  staleColumns, closeReasonColumns :: IntakeRequestRow -> [(Text, Bool)]
rejectedColumns r =
  [ ("rejected_at", isJust r.rejectedAt), ("rejection_reason", isJust r.rejectionReason) ]
triagedColumns r =
  [ ("healthcare_service_id", isJust r.healthcareServiceId)
  , ("priority",              isJust r.priority)
  , ("must_be_seen_by",       isJust r.mustBeSeenBy)
  , ("routine_not_before",    isJust r.routineNotBefore)
  , ("routine_not_after",     isJust r.routineNotAfter)
  , ("specific_doctor_id",    isJust r.specificDoctorId)
  , ("triaged_at",            isJust r.triagedAt)
  ]
appointedColumns r =
  [ ("doctor_id", isJust r.doctorId), ("start", isJust r.start), ("duration", isJust r.duration) ]
withdrawnColumns r =
  [ ("withdrawn_at", isJust r.withdrawnAt), ("withdrawal_note", isJust r.withdrawalNote) ]
staleColumns r = [ ("stale_at", isJust r.staleAt) ]
closeReasonColumns r =
  [ ("cancelled_by",      isJust r.cancelledBy)
  , ("cancelled_at",      isJust r.cancelledAt)
  , ("cancellation_note", isJust r.cancellationNote)
  , ("absent_party",      isJust r.absentParty)
  ]

expectNull :: Text -> [(Text, Bool)] -> Either DecodeError ()
expectNull st columns = case [ c | (c, True) <- columns ] of
  []      -> Right ()
  (c : _) -> Left (UnexpectedColumn st c)

required :: Text -> Text -> Maybe a -> Either DecodeError a
required st column = maybe (Left (MissingColumn st column)) Right

expectState :: Text -> IntakeRequestRow -> Either DecodeError ()
expectState st row
  | row.state == st = Right ()
  | otherwise       = Left (UnexpectedState st row.state)

-- ── Read direction: one function branching on the discriminator ────────────

toDomainIntakeRequest :: IntakeRequestRow -> Either DecodeError IntakeRequest
toDomainIntakeRequest row = case row.state of
  "submitted" -> Submitted <$> toDomainSubmittedIntakeRequest row
  "rejected"  -> Rejected  <$> toDomainRejectedIntakeRequest row
  "accepted"  -> Accepted  <$> toDomainTriagedIntakeRequest row
  "appointed" -> Appointed <$> toDomainAppointedIntakeRequest row
  "withdrawn" -> Withdrawn <$> toDomainWithdrawnIntakeRequest row
  "stale"     -> Stale     <$> toDomainStaleIntakeRequest row
  "closed"    -> Closed    <$> toDomainClosedIntakeRequest row
  other       -> Left (UnknownState other)

-- Case decoders: each checks the row's state and that every column outside
-- the case's stages is NULL.

toDomainSubmittedIntakeRequest :: IntakeRequestRow -> Either DecodeError SubmittedIntakeRequest
toDomainSubmittedIntakeRequest row = do
  expectState "submitted" row
  expectNull "submitted" $
    rejectedColumns row <> triagedColumns row <> appointedColumns row
      <> withdrawnColumns row <> staleColumns row <> closeReasonColumns row
  pure (submittedStage row)

toDomainRejectedIntakeRequest :: IntakeRequestRow -> Either DecodeError RejectedIntakeRequest
toDomainRejectedIntakeRequest row = do
  expectState "rejected" row
  expectNull "rejected" $
    triagedColumns row <> appointedColumns row <> withdrawnColumns row
      <> staleColumns row <> closeReasonColumns row
  rejectedAt      <- required "rejected" "rejected_at" row.rejectedAt
  rejectionReason <- required "rejected" "rejection_reason" row.rejectionReason
  pure RejectedIntakeRequest { submitted = submittedStage row, rejectedAt, rejectionReason }

toDomainTriagedIntakeRequest :: IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
toDomainTriagedIntakeRequest row = do
  expectState "accepted" row
  expectNull "accepted" $
    rejectedColumns row <> appointedColumns row <> withdrawnColumns row
      <> staleColumns row <> closeReasonColumns row
  triagedStage "accepted" row

toDomainAppointedIntakeRequest :: IntakeRequestRow -> Either DecodeError AppointedIntakeRequest
toDomainAppointedIntakeRequest row = do
  expectState "appointed" row
  expectNull "appointed" $
    rejectedColumns row <> withdrawnColumns row <> staleColumns row <> closeReasonColumns row
  appointedStage "appointed" row

toDomainWithdrawnIntakeRequest :: IntakeRequestRow -> Either DecodeError WithdrawnIntakeRequest
toDomainWithdrawnIntakeRequest row = do
  expectState "withdrawn" row
  expectNull "withdrawn" $
    rejectedColumns row <> appointedColumns row <> staleColumns row <> closeReasonColumns row
  -- FromSubmitted: none of FromAccepted's columns set (as in the CHECKs).
  withdrawnFrom <-
    if any snd (triagedColumns row)
      then FromAccepted <$> triagedStage "withdrawn" row
      else pure (FromSubmitted (submittedStage row))
  withdrawnAt <- required "withdrawn" "withdrawn_at" row.withdrawnAt
  pure WithdrawnIntakeRequest { withdrawnFrom, withdrawnAt, withdrawalNote = row.withdrawalNote }

toDomainStaleIntakeRequest :: IntakeRequestRow -> Either DecodeError StaleIntakeRequest
toDomainStaleIntakeRequest row = do
  expectState "stale" row
  expectNull "stale" $
    rejectedColumns row <> appointedColumns row <> withdrawnColumns row <> closeReasonColumns row
  triaged <- triagedStage "stale" row
  staleAt <- required "stale" "stale_at" row.staleAt
  pure StaleIntakeRequest { triaged, staleAt }

toDomainClosedIntakeRequest :: IntakeRequestRow -> Either DecodeError ClosedIntakeRequest
toDomainClosedIntakeRequest row = do
  expectState "closed" row
  expectNull "closed" $ rejectedColumns row <> withdrawnColumns row <> staleColumns row
  appointed   <- appointedStage "closed" row
  closeReason <- decodeCloseReason row
  pure ClosedIntakeRequest { appointed, closeReason }

-- ── Stage parts (no state or NULL checks; the case decoders do those) ──────

submittedStage :: IntakeRequestRow -> SubmittedIntakeRequest
submittedStage row = SubmittedIntakeRequest
  { id        = IntakeRequestId row.id
  , patientId = PatientId row.patientId
  , narrative = row.narrative
  , createdAt = row.createdAt
  }

triagedStage :: Text -> IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
triagedStage st row = do
  service       <- required st "healthcare_service_id" row.healthcareServiceId
  priorityValue <- required st "priority" row.priority
  priority      <- decodePriority st priorityValue row
  triagedAt     <- required st "triaged_at" row.triagedAt
  pure TriagedIntakeRequest
    { submitted           = submittedStage row
    , healthcareServiceId = HealthcareServiceId service
    , priority
    , doctorRequirement   = maybe AnyDoctor (SpecificDoctor . DoctorId) row.specificDoctorId
    , triagedAt
    }

appointedStage :: Text -> IntakeRequestRow -> Either DecodeError AppointedIntakeRequest
appointedStage st row = do
  triaged  <- triagedStage st row
  doctor   <- required st "doctor_id" row.doctorId
  start    <- required st "start" row.start
  minutes  <- required st "duration" row.duration
  duration <- decodeDuration minutes
  pure AppointedIntakeRequest { triaged, doctorId = DoctorId doctor, start, duration }

-- IntakeRequestPriority: stored values listed by hand (it has fields).
decodePriority :: Text -> Text -> IntakeRequestRow -> Either DecodeError IntakeRequestPriority
decodePriority st value row = case value of
  "emergency" -> Emergency <$> mustBeSeenBy
  "urgent"    -> Urgent    <$> mustBeSeenBy
  "routine"   -> do
    expectNull st [ ("must_be_seen_by", isJust row.mustBeSeenBy) ]
    Routine <$> decodeRoutineDue
  other       -> Left (UnknownPriority other)
  where
    mustBeSeenBy = do
      expectNull st [ ("routine_not_before", isJust row.routineNotBefore)
                    , ("routine_not_after",  isJust row.routineNotAfter) ]
      MustBeSeenBy <$> required st "must_be_seen_by" row.mustBeSeenBy
    -- Which bounds are set tells the case.
    decodeRoutineDue = case (row.routineNotBefore, row.routineNotAfter) of
      (Nothing,     Nothing)    -> Right RoutineAnytime
      (Just before, Nothing)    -> Right (RoutineNotBefore before)
      (Nothing,     Just after) -> Right (RoutineNotAfter after)
      (Just before, Just after) ->
        maybe (Left (InvalidRoutineWindow before after)) (Right . RoutineWithin)
          (mkRoutineWindow before after)

-- CloseReason: which columns are set tells the case (as in its CHECK).
decodeCloseReason :: IntakeRequestRow -> Either DecodeError CloseReason
decodeCloseReason row =
  case (row.cancelledBy, row.cancelledAt, row.cancellationNote, row.absentParty) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Completed
    (Just by, Just at, note, Nothing)    -> do
      cancelledBy <- decodeAppointmentParty by
      pure (Cancelled Cancellation { cancelledBy, cancelledAt = at, cancellationNote = note })
    (Nothing, Nothing, Nothing, Just party) ->
      NoShow . Absence <$> decodeAppointmentParty party
    _ -> Left (NoCloseReasonMatches row.state)

-- ── Write direction: one function per case ─────────────────────────────────

-- (discriminator, must_be_seen_by, routine_not_before, routine_not_after)
encodePriority
  :: IntakeRequestPriority -> (Text, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime)
encodePriority p = case p of
  Emergency (MustBeSeenBy t) -> ("emergency", Just t, Nothing, Nothing)
  Urgent    (MustBeSeenBy t) -> ("urgent",    Just t, Nothing, Nothing)
  Routine due                -> case due of
    RoutineAnytime          -> ("routine", Nothing, Nothing,     Nothing)
    RoutineNotBefore before -> ("routine", Nothing, Just before, Nothing)
    RoutineNotAfter  after  -> ("routine", Nothing, Nothing,     Just after)
    RoutineWithin window    ->
      ("routine", Nothing, Just (Domain.routineNotBefore window), Just (Domain.routineNotAfter window))

encodeDoctorRequirement :: DoctorRequirement -> Maybe UUID
encodeDoctorRequirement AnyDoctor                       = Nothing
encodeDoctorRequirement (SpecificDoctor (DoctorId uuid)) = Just uuid

fromDomainSubmittedIntakeRequest :: SubmittedIntakeRequest -> IntakeRequestRow
fromDomainSubmittedIntakeRequest
  SubmittedIntakeRequest { id = IntakeRequestId uuid, patientId = PatientId patient
                         , narrative, createdAt } =
  IntakeRequestRow
    { state = "submitted", id = uuid, patientId = patient, narrative, createdAt
    , rejectedAt = Nothing, rejectionReason = Nothing
    , healthcareServiceId = Nothing, priority = Nothing, mustBeSeenBy = Nothing
    , routineNotBefore = Nothing, routineNotAfter = Nothing
    , specificDoctorId = Nothing, triagedAt = Nothing
    , doctorId = Nothing, start = Nothing, duration = Nothing
    , withdrawnAt = Nothing, withdrawalNote = Nothing
    , staleAt = Nothing
    , cancelledBy = Nothing, cancelledAt = Nothing, cancellationNote = Nothing
    , absentParty = Nothing
    }

fromDomainRejectedIntakeRequest :: RejectedIntakeRequest -> IntakeRequestRow
fromDomainRejectedIntakeRequest RejectedIntakeRequest { submitted, rejectedAt, rejectionReason } =
  (fromDomainSubmittedIntakeRequest submitted)
    { state = "rejected", rejectedAt = Just rejectedAt, rejectionReason = Just rejectionReason }

fromDomainTriagedIntakeRequest :: TriagedIntakeRequest -> IntakeRequestRow
fromDomainTriagedIntakeRequest
  TriagedIntakeRequest { submitted, healthcareServiceId = HealthcareServiceId service
                       , priority, doctorRequirement, triagedAt } =
  let (tier, mustBeSeenBy, notBefore, notAfter) = encodePriority priority
  in (fromDomainSubmittedIntakeRequest submitted)
       { state               = "accepted"
       , healthcareServiceId = Just service
       , priority            = Just tier
       , mustBeSeenBy
       , routineNotBefore    = notBefore
       , routineNotAfter     = notAfter
       , specificDoctorId    = encodeDoctorRequirement doctorRequirement
       , triagedAt           = Just triagedAt
       }

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> IntakeRequestRow
fromDomainAppointedIntakeRequest
  AppointedIntakeRequest { triaged, doctorId = DoctorId doctor, start, duration } =
  (fromDomainTriagedIntakeRequest triaged)
    { state    = "appointed"
    , doctorId = Just doctor
    , start    = Just start
    , duration = Just (durationMinutes duration)
    }

fromDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequest -> IntakeRequestRow
fromDomainWithdrawnIntakeRequest
  WithdrawnIntakeRequest { withdrawnFrom, withdrawnAt, withdrawalNote } =
  let from = case withdrawnFrom of
        FromSubmitted submitted -> fromDomainSubmittedIntakeRequest submitted
        FromAccepted  triaged   -> fromDomainTriagedIntakeRequest triaged
  in from { state = "withdrawn", withdrawnAt = Just withdrawnAt, withdrawalNote }

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> IntakeRequestRow
fromDomainStaleIntakeRequest StaleIntakeRequest { triaged, staleAt } =
  (fromDomainTriagedIntakeRequest triaged) { state = "stale", staleAt = Just staleAt }

fromDomainClosedIntakeRequest :: ClosedIntakeRequest -> IntakeRequestRow
fromDomainClosedIntakeRequest ClosedIntakeRequest { appointed, closeReason } =
  -- `state` in each update also names IntakeRequestRow as the record updated.
  let base = fromDomainAppointedIntakeRequest appointed
  in case closeReason of
       Completed -> base { state = "closed" }
       Cancelled Cancellation { cancelledBy, cancelledAt, cancellationNote } ->
         base { state            = "closed"
              , cancelledBy      = Just (appointmentPartyValue cancelledBy)
              , cancelledAt      = Just cancelledAt
              , cancellationNote
              }
       NoShow Absence { absentParty } ->
         base { state = "closed", absentParty = Just (appointmentPartyValue absentParty) }

-- ── Reads ───────────────────────────────────────────────────────────────────

fetchIntakeRequest
  :: Connection -> IntakeRequestId -> IO (Either DecodeError (Maybe IntakeRequest))
fetchIntakeRequest conn (IntakeRequestId uuid) = do
  rows <- query conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests WHERE id = ?") (Only uuid)
  pure $ case rows of
    [row] -> Just <$> toDomainIntakeRequest row
    _     -> Right Nothing

fetchSubmittedIntakeRequests :: Connection -> IO (Either DecodeError [SubmittedIntakeRequest])
fetchSubmittedIntakeRequests conn =
  traverse toDomainSubmittedIntakeRequest <$> query_ conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests WHERE state = 'submitted' \
     \ORDER BY created_at")

fetchAcceptedIntakeRequests :: Connection -> IO (Either DecodeError [TriagedIntakeRequest])
fetchAcceptedIntakeRequests conn =
  traverse toDomainTriagedIntakeRequest <$> query_ conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests WHERE state = 'accepted' \
     \ORDER BY triaged_at")

fetchAppointedIntakeRequests :: Connection -> IO (Either DecodeError [AppointedIntakeRequest])
fetchAppointedIntakeRequests conn =
  traverse toDomainAppointedIntakeRequest <$> query_ conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests WHERE state = 'appointed' \
     \ORDER BY start")

-- Terminal cases: by a timestamp over [from, to).

fetchRejectedIntakeRequestsByRejectedAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [RejectedIntakeRequest])
fetchRejectedIntakeRequestsByRejectedAt conn from to =
  traverse toDomainRejectedIntakeRequest <$> query conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
     \WHERE state = 'rejected' AND rejected_at >= ? AND rejected_at < ? ORDER BY rejected_at")
    (from, to)

fetchWithdrawnIntakeRequestsByWithdrawnAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [WithdrawnIntakeRequest])
fetchWithdrawnIntakeRequestsByWithdrawnAt conn from to =
  traverse toDomainWithdrawnIntakeRequest <$> query conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
     \WHERE state = 'withdrawn' AND withdrawn_at >= ? AND withdrawn_at < ? ORDER BY withdrawn_at")
    (from, to)

fetchStaleIntakeRequestsByStaleAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [StaleIntakeRequest])
fetchStaleIntakeRequestsByStaleAt conn from to =
  traverse toDomainStaleIntakeRequest <$> query conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
     \WHERE state = 'stale' AND stale_at >= ? AND stale_at < ? ORDER BY stale_at")
    (from, to)

-- Closed adds no timestamp to every row: by its embedded Appointed's start.
fetchClosedIntakeRequestsByStart
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [ClosedIntakeRequest])
fetchClosedIntakeRequestsByStart conn from to =
  traverse toDomainClosedIntakeRequest <$> query conn
    ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
     \WHERE state = 'closed' AND start >= ? AND start < ? ORDER BY start")
    (from, to)

-- ── Writes ──────────────────────────────────────────────────────────────────

-- Entry case only.
insertSubmittedIntakeRequest :: Connection -> SubmittedIntakeRequest -> IO ()
insertSubmittedIntakeRequest conn submitted = do
  let row = fromDomainSubmittedIntakeRequest submitted
  _ <- execute conn
    "INSERT INTO intake_requests (state, id, patient_id, narrative, created_at) \
    \VALUES ('submitted', ?, ?, ?, ?)"
    (row.id, row.patientId, row.narrative, row.createdAt)
  pure ()

-- Submitted → Accepted (acceptIntakeRequest).
persistTriagedIntakeRequest :: Connection -> TriagedIntakeRequest -> IO ClaimOutcome
persistTriagedIntakeRequest conn triaged = do
  let row = fromDomainTriagedIntakeRequest triaged
  claimOutcome <$> execute conn
    "UPDATE intake_requests SET state = 'accepted', healthcare_service_id = ?, \
    \priority = ?, must_be_seen_by = ?, routine_not_before = ?, routine_not_after = ?, \
    \specific_doctor_id = ?, triaged_at = ? \
    \WHERE id = ? AND state = 'submitted'"
    ( row.healthcareServiceId, row.priority, row.mustBeSeenBy, row.routineNotBefore
    , row.routineNotAfter, row.specificDoctorId, row.triagedAt, row.id )

-- Submitted → Rejected (RejectedIntakeRequest).
persistRejectedIntakeRequest :: Connection -> RejectedIntakeRequest -> IO ClaimOutcome
persistRejectedIntakeRequest conn rejected = do
  let row = fromDomainRejectedIntakeRequest rejected
  claimOutcome <$> execute conn
    "UPDATE intake_requests SET state = 'rejected', rejected_at = ?, rejection_reason = ? \
    \WHERE id = ? AND state = 'submitted'"
    (row.rejectedAt, row.rejectionReason, row.id)

-- Accepted → Appointed (matchIntakeRequestToSlot): consumes the slot, which
-- is deleted first; the appointment takes over its extent.
persistAppointedIntakeRequest
  :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO MatchClaimOutcome
persistAppointedIntakeRequest conn slot appointed =
  handle (\IntakeRequestLost -> pure IntakeRequestAlreadyClaimed) $
    withTransaction conn $ do
      let SlotId slotUuid = slot.id
          row             = fromDomainAppointedIntakeRequest appointed
      deleted <- execute conn "DELETE FROM available_slots WHERE id = ?" (Only slotUuid)
      if deleted /= 1
        then pure SlotAlreadyClaimed
        else do
          updated <- execute conn
            "UPDATE intake_requests SET state = 'appointed', doctor_id = ?, start = ?, \
            \duration = ? WHERE id = ? AND state = 'accepted'"
            (row.doctorId, row.start, row.duration, row.id)
          if updated /= 1
            then throwIO IntakeRequestLost
            else pure MatchClaimed

-- Submitted → Withdrawn (FromSubmitted) or Accepted → Withdrawn
-- (FromAccepted): the guard comes from the recorded source case.
persistWithdrawnIntakeRequest :: Connection -> WithdrawnIntakeRequest -> IO ClaimOutcome
persistWithdrawnIntakeRequest conn withdrawn = do
  let row = fromDomainWithdrawnIntakeRequest withdrawn
      statement = case withdrawn.withdrawnFrom of
        FromSubmitted _ ->
          "UPDATE intake_requests SET state = 'withdrawn', withdrawn_at = ?, \
          \withdrawal_note = ? WHERE id = ? AND state = 'submitted'"
        FromAccepted _ ->
          "UPDATE intake_requests SET state = 'withdrawn', withdrawn_at = ?, \
          \withdrawal_note = ? WHERE id = ? AND state = 'accepted'"
  claimOutcome <$> execute conn statement (row.withdrawnAt, row.withdrawalNote, row.id)

-- Accepted → Stale (StaleIntakeRequest).
persistStaleIntakeRequest :: Connection -> StaleIntakeRequest -> IO ClaimOutcome
persistStaleIntakeRequest conn stale = do
  let row = fromDomainStaleIntakeRequest stale
  claimOutcome <$> execute conn
    "UPDATE intake_requests SET state = 'stale', stale_at = ? \
    \WHERE id = ? AND state = 'accepted'"
    (row.staleAt, row.id)

-- Appointed → Closed (ClosedIntakeRequest).
persistClosedIntakeRequest :: Connection -> ClosedIntakeRequest -> IO ClaimOutcome
persistClosedIntakeRequest conn closed = do
  let row = fromDomainClosedIntakeRequest closed
  claimOutcome <$> execute conn
    "UPDATE intake_requests SET state = 'closed', cancelled_by = ?, cancelled_at = ?, \
    \cancellation_note = ?, absent_party = ? WHERE id = ? AND state = 'appointed'"
    (row.cancelledBy, row.cancelledAt, row.cancellationNote, row.absentParty, row.id)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR CALENDAR
-- ═══════════════════════════════════════════════════════════════════════════

-- The slice for judging a new slot: the doctor's entries overlapping
-- [start, start + duration), from the source tables in one snapshot, rebuilt
-- through mkDoctorCalendar.
fetchDoctorCalendarOverlapping
  :: Connection -> DoctorId -> UTCTime -> Duration -> IO (Either DecodeError DoctorCalendar)
fetchDoctorCalendarOverlapping conn doctor@(DoctorId doctorUuid) start duration = do
  let end = addUTCTime (durationToNominalDiffTime duration) start
  (slotRows, appointedRows) <- withTransactionLevel RepeatableRead conn $ do
    slotRows <- query conn
      ("SELECT " <> slotColumns <> " FROM available_slots \
       \WHERE doctor_id = ? AND start < ? AND start + duration * INTERVAL '1 minute' > ?")
      (doctorUuid, end, start)
    appointedRows <- query conn
      ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
       \WHERE state = 'appointed' AND doctor_id = ? \
       \AND start < ? AND start + duration * INTERVAL '1 minute' > ?")
      (doctorUuid, end, start)
    pure (slotRows, appointedRows)
  pure $ do
    entries <- calendarEntries slotRows appointedRows
    maybe (Left (OverlappingDoctorCalendar doctor)) Right (mkDoctorCalendar entries)

-- The calendar's elements overlapping [from, to), every doctor, from the
-- source tables in one snapshot, sorted by start.
fetchDoctorCalendarEntriesOverlapping
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [DoctorCalendarEntry])
fetchDoctorCalendarEntriesOverlapping conn from to = do
  (slotRows, appointedRows) <- withTransactionLevel RepeatableRead conn $ do
    slotRows <- query conn
      ("SELECT " <> slotColumns <> " FROM available_slots \
       \WHERE start < ? AND start + duration * INTERVAL '1 minute' > ?")
      (to, from)
    appointedRows <- query conn
      ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
       \WHERE state = 'appointed' \
       \AND start < ? AND start + duration * INTERVAL '1 minute' > ?")
      (to, from)
    pure (slotRows, appointedRows)
  pure (sortOn doctorCalendarEntryStart <$> calendarEntries slotRows appointedRows)

calendarEntries
  :: [AvailableSlotRow] -> [IntakeRequestRow] -> Either DecodeError [DoctorCalendarEntry]
calendarEntries slotRows appointedRows = do
  slots        <- traverse toDomainAvailableSlot slotRows
  appointments <- traverse toDomainAppointedIntakeRequest appointedRows
  pure (map Slot slots <> map Appointment appointments)
