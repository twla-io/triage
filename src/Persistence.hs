{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

-- Derived from src/Domain.hs (triage-db-codegen). Schema:
-- migrations/0001_init.sql.
module Persistence
  ( -- ── Connections ──────────────────────────────────────────────────────
    ConnectionPool

    -- ── Errors and outcomes ──────────────────────────────────────────────
  , DecodeError (..)
  , ClaimOutcome (..)
  , AppointedClaimOutcome (..)
  , AvailableSlotInsertOutcome (..)

    -- ── Rows ─────────────────────────────────────────────────────────────
  , DoctorRow (..)
  , PatientRow (..)
  , HealthcareServiceRow (..)
  , AvailableSlotRow (..)
  , IntakeRequestRow (..)

    -- ── Decoding ─────────────────────────────────────────────────────────
  , toDomainDoctor
  , toDomainPatient
  , toDomainHealthcareService
  , toDomainAvailableSlot
  , toDomainDuration
  , toDomainAppointmentParty
  , toDomainSubmittedIntakeRequest
  , toDomainRejectedIntakeRequest
  , toDomainTriagedIntakeRequest
  , toDomainAppointedIntakeRequest
  , toDomainWithdrawnIntakeRequest
  , toDomainStaleIntakeRequest
  , toDomainClosedIntakeRequest
  , toDomainIntakeRequest

    -- ── Encoding ─────────────────────────────────────────────────────────
  , fromDomainDuration
  , fromDomainAppointmentParty

    -- ── Inserts ──────────────────────────────────────────────────────────
  , insertDoctor
  , insertPatient
  , insertHealthcareService
  , insertAvailableSlot
  , insertSubmittedIntakeRequest

    -- ── Transitions ──────────────────────────────────────────────────────
  , persistTriagedIntakeRequest
  , persistRejectedIntakeRequest
  , persistAppointedIntakeRequest
  , persistWithdrawnIntakeRequest
  , persistStaleIntakeRequest
  , persistClosedIntakeRequest

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
  ) where

import Control.Exception                     (Exception, catchJust, handle, throwIO)
import Control.Monad                         (unless, when)
import Data.Char                             (isUpper, toLower)
import Data.Foldable                         (traverse_)
import Data.Int                              (Int16, Int64)
import Data.Maybe                            (isJust)
import Data.Pool                             (Pool)
import Data.Text                             (Text)
import Data.Time                             (UTCTime)
import Data.UUID                             (UUID)
import Database.PostgreSQL.Simple
  ( Connection, Only (..), Query, SqlError (..), execute, query, query_, withTransaction, (:.) (..) )
import Database.PostgreSQL.Simple.FromRow    (FromRow (..), field)
import Database.PostgreSQL.Simple.Transaction
  ( IsolationLevel (RepeatableRead), withTransactionLevel )

import qualified Data.Text as T

import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- CONNECTIONS
-- ═══════════════════════════════════════════════════════════════════════════

type ConnectionPool = Pool Connection

-- ═══════════════════════════════════════════════════════════════════════════
-- ERRORS AND OUTCOMES
-- ═══════════════════════════════════════════════════════════════════════════

-- One constructor per kind of decoding failure.
data DecodeError
  = UnknownStoredValue Text Text      -- ^ column, stored value
  | MissingValue Text                 -- ^ column required by the row's case is NULL
  | UnexpectedValue Text              -- ^ column the row's case leaves NULL is set
  | RoutineWindowRefused UTCTime UTCTime  -- ^ mkRoutineWindow refused (not before, not after)
  | DoctorCalendarRefused             -- ^ mkDoctorCalendar refused the stored entries
  deriving (Show, Eq)

instance Exception DecodeError

-- A write with a single guarded row.
data ClaimOutcome
  = Claimed
  | AlreadyClaimed
  deriving (Show, Eq)

-- Matching: guards the slot (still exists) and the request (still Accepted).
data AppointedClaimOutcome
  = AppointedClaimed
  | AvailableSlotAlreadyClaimed
  | IntakeRequestAlreadyClaimed
  deriving (Show, Eq)

-- An insert into the DoctorCalendar collection (guarded by doctor_calendar).
data AvailableSlotInsertOutcome
  = AvailableSlotInserted
  | AvailableSlotOverlapsDoctorCalendar
  deriving (Show, Eq)

-- Internal: the request lost its race after the slot was deleted; rolls the
-- matching transaction back.
data IntakeRequestLostRace = IntakeRequestLostRace
  deriving Show

instance Exception IntakeRequestLostRace

-- ═══════════════════════════════════════════════════════════════════════════
-- ROWS
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorRow = DoctorRow
  { id   :: UUID
  , name :: Text
  }
  deriving (Show, Eq)

instance FromRow DoctorRow where
  fromRow = DoctorRow
    <$> field -- id
    <*> field -- name

data PatientRow = PatientRow
  { id   :: UUID
  , name :: Text
  }
  deriving (Show, Eq)

instance FromRow PatientRow where
  fromRow = PatientRow
    <$> field -- id
    <*> field -- name

data HealthcareServiceRow = HealthcareServiceRow
  { id       :: UUID
  , name     :: Text
  , duration :: Int16
  }
  deriving (Show, Eq)

instance FromRow HealthcareServiceRow where
  fromRow = HealthcareServiceRow
    <$> field -- id
    <*> field -- name
    <*> field -- duration

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
    <$> field -- id
    <*> field -- doctor_id
    <*> field -- healthcare_service_id
    <*> field -- start
    <*> field -- duration

data IntakeRequestRow = IntakeRequestRow
  { id                  :: UUID
  , state               :: Text
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
    <$> field -- id
    <*> field -- state
    <*> field -- patient_id
    <*> field -- narrative
    <*> field -- created_at
    <*> field -- rejected_at
    <*> field -- rejection_reason
    <*> field -- healthcare_service_id
    <*> field -- priority
    <*> field -- must_be_seen_by
    <*> field -- routine_not_before
    <*> field -- routine_not_after
    <*> field -- specific_doctor_id
    <*> field -- triaged_at
    <*> field -- doctor_id
    <*> field -- start
    <*> field -- duration
    <*> field -- withdrawn_at
    <*> field -- withdrawal_note
    <*> field -- stale_at
    <*> field -- cancelled_by
    <*> field -- cancelled_at
    <*> field -- cancellation_note
    <*> field -- absent_party

doctorColumns, patientColumns, healthcareServiceColumns, availableSlotColumns, intakeRequestColumns :: Query
doctorColumns            = "id, name"
patientColumns           = "id, name"
healthcareServiceColumns = "id, name, duration"
availableSlotColumns     = "id, doctor_id, healthcare_service_id, start, duration"
intakeRequestColumns     =
  "id, state, patient_id, narrative, created_at, \
  \rejected_at, rejection_reason, \
  \healthcare_service_id, priority, must_be_seen_by, routine_not_before, routine_not_after, \
  \specific_doctor_id, triaged_at, \
  \doctor_id, start, duration, \
  \withdrawn_at, withdrawal_note, \
  \stale_at, \
  \cancelled_by, cancelled_at, cancellation_note, absent_party"

-- ═══════════════════════════════════════════════════════════════════════════
-- ENUMERATIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Whole minutes.
fromDomainDuration :: Duration -> Int16
fromDomainDuration d = round (durationToNominalDiffTime d / 60)

toDomainDuration :: Int16 -> Either DecodeError Duration
toDomainDuration minutes =
  maybe (Left (UnknownStoredValue "duration" (T.pack (show minutes)))) Right $
    lookup minutes [ (fromDomainDuration d, d) | d <- [minBound .. maxBound] ]

-- Constructor name in snake_case.
fromDomainAppointmentParty :: AppointmentParty -> Text
fromDomainAppointmentParty = snakeCase . show

-- Takes the column the value was read from, for the error.
toDomainAppointmentParty :: Text -> Text -> Either DecodeError AppointmentParty
toDomainAppointmentParty column stored =
  maybe (Left (UnknownStoredValue column stored)) Right $
    lookup stored [ (fromDomainAppointmentParty p, p) | p <- [minBound .. maxBound] ]

snakeCase :: String -> Text
snakeCase = T.pack . go
  where
    go (c : cs) = toLower c : concatMap (\x -> if isUpper x then ['_', toLower x] else [x]) cs
    go []       = []

-- The `state` discriminator: IntakeRequest's constructor names in snake_case,
-- listed by hand (a sum type with fields).
stateOf :: IntakeRequest -> Text
stateOf = \case
  Submitted _ -> "submitted"
  Rejected _  -> "rejected"
  Accepted _  -> "accepted"
  Appointed _ -> "appointed"
  Withdrawn _ -> "withdrawn"
  Stale _     -> "stale"
  Closed _    -> "closed"

-- ═══════════════════════════════════════════════════════════════════════════
-- DECODING
-- ═══════════════════════════════════════════════════════════════════════════

toDomainDoctor :: DoctorRow -> Doctor
toDomainDoctor row = Doctor { id = DoctorId row.id, name = row.name }

toDomainPatient :: PatientRow -> Patient
toDomainPatient row = Patient { id = PatientId row.id, name = row.name }

toDomainHealthcareService :: HealthcareServiceRow -> Either DecodeError HealthcareService
toDomainHealthcareService row = do
  serviceDuration <- toDomainDuration row.duration
  pure HealthcareService
    { id = HealthcareServiceId row.id, name = row.name, duration = serviceDuration }

toDomainAvailableSlot :: AvailableSlotRow -> Either DecodeError AvailableSlot
toDomainAvailableSlot row = do
  slotDuration <- toDomainDuration row.duration
  pure AvailableSlot
    { id                  = SlotId row.id
    , doctorId            = DoctorId row.doctorId
    , healthcareServiceId = HealthcareServiceId row.healthcareServiceId
    , start               = row.start
    , duration            = slotDuration
    }

-- ── IntakeRequest helpers ──────────────────────────────────────────────────

required :: Text -> Maybe a -> Either DecodeError a
required column = maybe (Left (MissingValue column)) Right

-- Every listed column must be NULL.
absent :: [(Text, Bool)] -> Either DecodeError ()
absent = traverse_ (\(column, set) -> when set (Left (UnexpectedValue column)))

-- Columns per stage, with whether each is set.
rejectedColumns, triagedColumns, appointedColumns, withdrawnColumns, staleColumns, closeReasonColumns
  :: IntakeRequestRow -> [(Text, Bool)]
rejectedColumns row =
  [ ("rejected_at",      isJust row.rejectedAt)
  , ("rejection_reason", isJust row.rejectionReason)
  ]
triagedColumns row =
  [ ("healthcare_service_id", isJust row.healthcareServiceId)
  , ("priority",              isJust row.priority)
  , ("must_be_seen_by",       isJust row.mustBeSeenBy)
  , ("routine_not_before",    isJust row.routineNotBefore)
  , ("routine_not_after",     isJust row.routineNotAfter)
  , ("specific_doctor_id",    isJust row.specificDoctorId)
  , ("triaged_at",            isJust row.triagedAt)
  ]
appointedColumns row =
  [ ("doctor_id", isJust row.doctorId)
  , ("start",     isJust row.start)
  , ("duration",  isJust row.duration)
  ]
withdrawnColumns row =
  [ ("withdrawn_at",    isJust row.withdrawnAt)
  , ("withdrawal_note", isJust row.withdrawalNote)
  ]
staleColumns row =
  [ ("stale_at", isJust row.staleAt)
  ]
closeReasonColumns row =
  [ ("cancelled_by",      isJust row.cancelledBy)
  , ("cancelled_at",      isJust row.cancelledAt)
  , ("cancellation_note", isJust row.cancellationNote)
  , ("absent_party",      isJust row.absentParty)
  ]

-- The columns a TriagedIntakeRequest always sets: they identify
-- WithdrawnFrom's FromAccepted case.
triagedIdentifyingColumns :: IntakeRequestRow -> [(Text, Bool)]
triagedIdentifyingColumns row =
  [ ("healthcare_service_id", isJust row.healthcareServiceId)
  , ("priority",              isJust row.priority)
  , ("triaged_at",            isJust row.triagedAt)
  ]

-- ── Stages ─────────────────────────────────────────────────────────────────

toDomainSubmittedIntakeRequest :: IntakeRequestRow -> SubmittedIntakeRequest
toDomainSubmittedIntakeRequest row = SubmittedIntakeRequest
  { id        = IntakeRequestId row.id
  , patientId = PatientId row.patientId
  , narrative = row.narrative
  , createdAt = row.createdAt
  }

toDomainRejectedIntakeRequest :: IntakeRequestRow -> Either DecodeError RejectedIntakeRequest
toDomainRejectedIntakeRequest row = do
  at     <- required "rejected_at" row.rejectedAt
  reason <- required "rejection_reason" row.rejectionReason
  pure RejectedIntakeRequest
    { submitted = toDomainSubmittedIntakeRequest row, rejectedAt = at, rejectionReason = reason }

toDomainTriagedIntakeRequest :: IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
toDomainTriagedIntakeRequest row = do
  service <- required "healthcare_service_id" row.healthcareServiceId
  tier    <- toDomainIntakeRequestPriority row
  at      <- required "triaged_at" row.triagedAt
  pure TriagedIntakeRequest
    { submitted           = toDomainSubmittedIntakeRequest row
    , healthcareServiceId = HealthcareServiceId service
    , priority            = tier
    , doctorRequirement   = toDomainDoctorRequirement row
    , triagedAt           = at
    }

-- Discriminated by `priority`.
toDomainIntakeRequestPriority :: IntakeRequestRow -> Either DecodeError IntakeRequestPriority
toDomainIntakeRequestPriority row = case row.priority of
  Nothing          -> Left (MissingValue "priority")
  Just "emergency" -> Emergency <$> deadline
  Just "urgent"    -> Urgent <$> deadline
  Just "routine"   -> do
    absent [("must_be_seen_by", isJust row.mustBeSeenBy)]
    Routine <$> toDomainRoutineDue row
  Just other       -> Left (UnknownStoredValue "priority" other)
  where
    deadline = do
      absent [ ("routine_not_before", isJust row.routineNotBefore)
             , ("routine_not_after",  isJust row.routineNotAfter) ]
      MustBeSeenBy <$> required "must_be_seen_by" row.mustBeSeenBy

-- Told apart by which columns are set.
toDomainRoutineDue :: IntakeRequestRow -> Either DecodeError RoutineDue
toDomainRoutineDue row = case (row.routineNotBefore, row.routineNotAfter) of
  (Nothing,        Nothing)       -> Right RoutineAnytime
  (Just notBefore, Nothing)       -> Right (RoutineNotBefore notBefore)
  (Nothing,        Just notAfter) -> Right (RoutineNotAfter notAfter)
  (Just notBefore, Just notAfter) ->
    maybe (Left (RoutineWindowRefused notBefore notAfter)) (Right . RoutineWithin)
      (mkRoutineWindow notBefore notAfter)

toDomainDoctorRequirement :: IntakeRequestRow -> DoctorRequirement
toDomainDoctorRequirement row = maybe AnyDoctor (SpecificDoctor . DoctorId) row.specificDoctorId

toDomainAppointedIntakeRequest :: IntakeRequestRow -> Either DecodeError AppointedIntakeRequest
toDomainAppointedIntakeRequest row = do
  request  <- toDomainTriagedIntakeRequest row
  doctor   <- required "doctor_id" row.doctorId
  at       <- required "start" row.start
  minutes  <- required "duration" row.duration
  lasting  <- toDomainDuration minutes
  pure AppointedIntakeRequest
    { triaged = request, doctorId = DoctorId doctor, start = at, duration = lasting }

toDomainWithdrawnIntakeRequest :: IntakeRequestRow -> Either DecodeError WithdrawnIntakeRequest
toDomainWithdrawnIntakeRequest row = do
  from <- toDomainWithdrawnFrom row
  at   <- required "withdrawn_at" row.withdrawnAt
  pure WithdrawnIntakeRequest
    { withdrawnFrom = from, withdrawnAt = at, withdrawalNote = row.withdrawalNote }

-- FromAccepted sets the TriagedIntakeRequest columns; FromSubmitted sets none.
toDomainWithdrawnFrom :: IntakeRequestRow -> Either DecodeError WithdrawnFrom
toDomainWithdrawnFrom row
  | any snd (triagedIdentifyingColumns row) = FromAccepted <$> toDomainTriagedIntakeRequest row
  | otherwise = FromSubmitted (toDomainSubmittedIntakeRequest row) <$ absent (triagedColumns row)

toDomainStaleIntakeRequest :: IntakeRequestRow -> Either DecodeError StaleIntakeRequest
toDomainStaleIntakeRequest row = do
  request <- toDomainTriagedIntakeRequest row
  at      <- required "stale_at" row.staleAt
  pure StaleIntakeRequest { triaged = request, staleAt = at }

-- Completed sets none; Cancelled sets cancelled_by and cancelled_at; NoShow
-- sets absent_party.
toDomainCloseReason :: IntakeRequestRow -> Either DecodeError CloseReason
toDomainCloseReason row
  | Just party <- row.absentParty = do
      absent [ ("cancelled_by",      isJust row.cancelledBy)
             , ("cancelled_at",      isJust row.cancelledAt)
             , ("cancellation_note", isJust row.cancellationNote) ]
      NoShow . Absence <$> toDomainAppointmentParty "absent_party" party
  | isJust row.cancelledBy || isJust row.cancelledAt || isJust row.cancellationNote = do
      by    <- required "cancelled_by" row.cancelledBy
      at    <- required "cancelled_at" row.cancelledAt
      party <- toDomainAppointmentParty "cancelled_by" by
      pure (Cancelled Cancellation
        { cancelledBy = party, cancelledAt = at, cancellationNote = row.cancellationNote })
  | otherwise = Right Completed

toDomainClosedIntakeRequest :: IntakeRequestRow -> Either DecodeError ClosedIntakeRequest
toDomainClosedIntakeRequest row = do
  request <- toDomainAppointedIntakeRequest row
  reason  <- toDomainCloseReason row
  pure ClosedIntakeRequest { appointed = request, closeReason = reason }

-- ── Cases (stage decoder plus the columns the case leaves NULL) ────────────

decodeSubmitted :: IntakeRequestRow -> Either DecodeError SubmittedIntakeRequest
decodeSubmitted row = do
  absent (concatMap ($ row)
    [rejectedColumns, triagedColumns, appointedColumns, withdrawnColumns, staleColumns, closeReasonColumns])
  pure (toDomainSubmittedIntakeRequest row)

decodeRejected :: IntakeRequestRow -> Either DecodeError RejectedIntakeRequest
decodeRejected row = do
  absent (concatMap ($ row)
    [triagedColumns, appointedColumns, withdrawnColumns, staleColumns, closeReasonColumns])
  toDomainRejectedIntakeRequest row

decodeAccepted :: IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
decodeAccepted row = do
  absent (concatMap ($ row)
    [rejectedColumns, appointedColumns, withdrawnColumns, staleColumns, closeReasonColumns])
  toDomainTriagedIntakeRequest row

decodeAppointed :: IntakeRequestRow -> Either DecodeError AppointedIntakeRequest
decodeAppointed row = do
  absent (concatMap ($ row)
    [rejectedColumns, withdrawnColumns, staleColumns, closeReasonColumns])
  toDomainAppointedIntakeRequest row

decodeWithdrawn :: IntakeRequestRow -> Either DecodeError WithdrawnIntakeRequest
decodeWithdrawn row = do
  absent (concatMap ($ row)
    [rejectedColumns, appointedColumns, staleColumns, closeReasonColumns])
  toDomainWithdrawnIntakeRequest row

decodeStale :: IntakeRequestRow -> Either DecodeError StaleIntakeRequest
decodeStale row = do
  absent (concatMap ($ row)
    [rejectedColumns, appointedColumns, withdrawnColumns, closeReasonColumns])
  toDomainStaleIntakeRequest row

decodeClosed :: IntakeRequestRow -> Either DecodeError ClosedIntakeRequest
decodeClosed row = do
  absent (concatMap ($ row)
    [rejectedColumns, withdrawnColumns, staleColumns])
  toDomainClosedIntakeRequest row

-- Branches on the `state` discriminator.
toDomainIntakeRequest :: IntakeRequestRow -> Either DecodeError IntakeRequest
toDomainIntakeRequest row = case row.state of
  "submitted" -> Submitted <$> decodeSubmitted row
  "rejected"  -> Rejected  <$> decodeRejected row
  "accepted"  -> Accepted  <$> decodeAccepted row
  "appointed" -> Appointed <$> decodeAppointed row
  "withdrawn" -> Withdrawn <$> decodeWithdrawn row
  "stale"     -> Stale     <$> decodeStale row
  "closed"    -> Closed    <$> decodeClosed row
  other       -> Left (UnknownStoredValue "state" other)

-- ═══════════════════════════════════════════════════════════════════════════
-- ENCODING (per stage: the columns that stage contributes)
-- ═══════════════════════════════════════════════════════════════════════════

fromDomainDoctor :: Doctor -> (UUID, Text)
fromDomainDoctor doctor = let DoctorId uuid = doctor.id in (uuid, doctor.name)

fromDomainPatient :: Patient -> (UUID, Text)
fromDomainPatient patient = let PatientId uuid = patient.id in (uuid, patient.name)

fromDomainHealthcareService :: HealthcareService -> (UUID, Text, Int16)
fromDomainHealthcareService service =
  let HealthcareServiceId uuid = service.id
  in (uuid, service.name, fromDomainDuration service.duration)

fromDomainAvailableSlot :: AvailableSlot -> (UUID, UUID, UUID, UTCTime, Int16)
fromDomainAvailableSlot slot =
  let SlotId uuid                     = slot.id
      DoctorId doctor                 = slot.doctorId
      HealthcareServiceId service     = slot.healthcareServiceId
  in (uuid, doctor, service, slot.start, fromDomainDuration slot.duration)

fromDomainSubmittedIntakeRequest :: SubmittedIntakeRequest -> (UUID, Text, UUID, Text, UTCTime)
fromDomainSubmittedIntakeRequest request =
  let IntakeRequestId uuid = request.id
      PatientId patient    = request.patientId
  in (uuid, stateOf (Submitted request), patient, request.narrative, request.createdAt)

fromDomainRejectedIntakeRequest :: RejectedIntakeRequest -> (UTCTime, Text)
fromDomainRejectedIntakeRequest request = (request.rejectedAt, request.rejectionReason)

fromDomainTriagedIntakeRequest
  :: TriagedIntakeRequest
  -> (UUID, Text, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime, Maybe UUID, UTCTime)
fromDomainTriagedIntakeRequest request =
  let HealthcareServiceId service         = request.healthcareServiceId
      (tier, deadline, notBefore, notAfter) = fromDomainIntakeRequestPriority request.priority
  in ( service, tier, deadline, notBefore, notAfter
     , fromDomainDoctorRequirement request.doctorRequirement, request.triagedAt )

fromDomainIntakeRequestPriority
  :: IntakeRequestPriority -> (Text, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime)
fromDomainIntakeRequestPriority = \case
  Emergency (MustBeSeenBy deadline) -> ("emergency", Just deadline, Nothing, Nothing)
  Urgent    (MustBeSeenBy deadline) -> ("urgent",    Just deadline, Nothing, Nothing)
  Routine   due                     ->
    let (notBefore, notAfter) = fromDomainRoutineDue due in ("routine", Nothing, notBefore, notAfter)

fromDomainRoutineDue :: RoutineDue -> (Maybe UTCTime, Maybe UTCTime)
fromDomainRoutineDue = \case
  RoutineAnytime             -> (Nothing, Nothing)
  RoutineNotBefore notBefore -> (Just notBefore, Nothing)
  RoutineNotAfter  notAfter  -> (Nothing, Just notAfter)
  RoutineWithin    window    ->
    (Just (Domain.routineNotBefore window), Just (Domain.routineNotAfter window))

fromDomainDoctorRequirement :: DoctorRequirement -> Maybe UUID
fromDomainDoctorRequirement = \case
  AnyDoctor                      -> Nothing
  SpecificDoctor (DoctorId uuid) -> Just uuid

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> (UUID, UTCTime, Int16)
fromDomainAppointedIntakeRequest request =
  let DoctorId doctor = request.doctorId
  in (doctor, request.start, fromDomainDuration request.duration)

fromDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequest -> (UTCTime, Maybe Text)
fromDomainWithdrawnIntakeRequest request = (request.withdrawnAt, request.withdrawalNote)

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> Only UTCTime
fromDomainStaleIntakeRequest request = Only request.staleAt

fromDomainClosedIntakeRequest
  :: ClosedIntakeRequest -> (Maybe Text, Maybe UTCTime, Maybe Text, Maybe Text)
fromDomainClosedIntakeRequest request = fromDomainCloseReason request.closeReason

fromDomainCloseReason :: CloseReason -> (Maybe Text, Maybe UTCTime, Maybe Text, Maybe Text)
fromDomainCloseReason = \case
  Completed            -> (Nothing, Nothing, Nothing, Nothing)
  Cancelled cancellation ->
    ( Just (fromDomainAppointmentParty cancellation.cancelledBy)
    , Just cancellation.cancelledAt
    , cancellation.cancellationNote
    , Nothing )
  NoShow absence ->
    (Nothing, Nothing, Nothing, Just (fromDomainAppointmentParty absence.absentParty))

-- ═══════════════════════════════════════════════════════════════════════════
-- INSERTS
-- ═══════════════════════════════════════════════════════════════════════════

insertDoctor :: Connection -> Doctor -> IO ()
insertDoctor conn doctor = () <$
  execute conn "INSERT INTO doctors (id, name) VALUES (?, ?)" (fromDomainDoctor doctor)

insertPatient :: Connection -> Patient -> IO ()
insertPatient conn patient = () <$
  execute conn "INSERT INTO patients (id, name) VALUES (?, ?)" (fromDomainPatient patient)

insertHealthcareService :: Connection -> HealthcareService -> IO ()
insertHealthcareService conn service = () <$
  execute conn "INSERT INTO healthcare_services (id, name, duration) VALUES (?, ?, ?)"
    (fromDomainHealthcareService service)

-- A new element of DoctorCalendar: an overlap with the doctor's stored
-- entries (doctor_calendar's EXCLUDE, 23P01) is an outcome.
insertAvailableSlot :: Connection -> AvailableSlot -> IO AvailableSlotInsertOutcome
insertAvailableSlot conn slot =
  catchJust exclusionViolation
    (AvailableSlotInserted <$
      execute conn
        "INSERT INTO available_slots (id, doctor_id, healthcare_service_id, start, duration) \
        \VALUES (?, ?, ?, ?, ?)"
        (fromDomainAvailableSlot slot))
    (\() -> pure AvailableSlotOverlapsDoctorCalendar)
  where
    exclusionViolation e = if sqlState e == "23P01" then Just () else Nothing

-- IntakeRequest is inserted only in its entry case, Submitted.
insertSubmittedIntakeRequest :: Connection -> SubmittedIntakeRequest -> IO ()
insertSubmittedIntakeRequest conn request = () <$
  execute conn
    "INSERT INTO intake_requests (id, state, patient_id, narrative, created_at) \
    \VALUES (?, ?, ?, ?, ?)"
    (fromDomainSubmittedIntakeRequest request)

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSITIONS — UPDATE guarded by id and the one source case
-- ═══════════════════════════════════════════════════════════════════════════

claim :: Int64 -> ClaimOutcome
claim affected = if affected == 1 then Claimed else AlreadyClaimed

-- Submitted → Accepted (acceptIntakeRequest).
persistTriagedIntakeRequest :: Connection -> TriagedIntakeRequest -> IO ClaimOutcome
persistTriagedIntakeRequest conn request = do
  let IntakeRequestId uuid = request.submitted.id
  claim <$> execute conn
    "UPDATE intake_requests SET state = ?, \
    \healthcare_service_id = ?, priority = ?, must_be_seen_by = ?, \
    \routine_not_before = ?, routine_not_after = ?, specific_doctor_id = ?, triaged_at = ? \
    \WHERE id = ? AND state = ?"
    ( Only (stateOf (Accepted request))
      :. fromDomainTriagedIntakeRequest request
      :. (uuid, stateOf (Submitted request.submitted)) )

-- Submitted → Rejected.
persistRejectedIntakeRequest :: Connection -> RejectedIntakeRequest -> IO ClaimOutcome
persistRejectedIntakeRequest conn request = do
  let IntakeRequestId uuid = request.submitted.id
  claim <$> execute conn
    "UPDATE intake_requests SET state = ?, rejected_at = ?, rejection_reason = ? \
    \WHERE id = ? AND state = ?"
    ( Only (stateOf (Rejected request))
      :. fromDomainRejectedIntakeRequest request
      :. (uuid, stateOf (Submitted request.submitted)) )

-- Accepted → Appointed (matchIntakeRequestToSlot). Consumes the slot: it is
-- deleted first, then the request takes over its interval. One transaction.
persistAppointedIntakeRequest
  :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO AppointedClaimOutcome
persistAppointedIntakeRequest conn slot request = do
  let SlotId slotUuid           = slot.id
      IntakeRequestId uuid      = request.triaged.submitted.id
  handle (\IntakeRequestLostRace -> pure IntakeRequestAlreadyClaimed) $
    withTransaction conn $ do
      deleted <- execute conn "DELETE FROM available_slots WHERE id = ?" (Only slotUuid)
      if deleted /= 1
        then pure AvailableSlotAlreadyClaimed
        else do
          updated <- execute conn
            "UPDATE intake_requests SET state = ?, doctor_id = ?, start = ?, duration = ? \
            \WHERE id = ? AND state = ?"
            ( Only (stateOf (Appointed request))
              :. fromDomainAppointedIntakeRequest request
              :. (uuid, stateOf (Accepted request.triaged)) )
          unless (updated == 1) (throwIO IntakeRequestLostRace)
          pure AppointedClaimed

-- Submitted → Withdrawn or Accepted → Withdrawn: the source case comes from
-- withdrawnFrom.
persistWithdrawnIntakeRequest :: Connection -> WithdrawnIntakeRequest -> IO ClaimOutcome
persistWithdrawnIntakeRequest conn request = case request.withdrawnFrom of
  FromSubmitted source -> withdraw source.id (Submitted source)
  FromAccepted  source -> withdraw source.submitted.id (Accepted source)
  where
    withdraw (IntakeRequestId uuid) source =
      claim <$> execute conn
        "UPDATE intake_requests SET state = ?, withdrawn_at = ?, withdrawal_note = ? \
        \WHERE id = ? AND state = ?"
        ( Only (stateOf (Withdrawn request))
          :. fromDomainWithdrawnIntakeRequest request
          :. (uuid, stateOf source) )

-- Accepted → Stale.
persistStaleIntakeRequest :: Connection -> StaleIntakeRequest -> IO ClaimOutcome
persistStaleIntakeRequest conn request = do
  let IntakeRequestId uuid = request.triaged.submitted.id
  claim <$> execute conn
    "UPDATE intake_requests SET state = ?, stale_at = ? WHERE id = ? AND state = ?"
    ( Only (stateOf (Stale request))
      :. fromDomainStaleIntakeRequest request
      :. (uuid, stateOf (Accepted request.triaged)) )

-- Appointed → Closed.
persistClosedIntakeRequest :: Connection -> ClosedIntakeRequest -> IO ClaimOutcome
persistClosedIntakeRequest conn request = do
  let IntakeRequestId uuid = request.appointed.triaged.submitted.id
  claim <$> execute conn
    "UPDATE intake_requests SET state = ?, \
    \cancelled_by = ?, cancelled_at = ?, cancellation_note = ?, absent_party = ? \
    \WHERE id = ? AND state = ?"
    ( Only (stateOf (Closed request))
      :. fromDomainClosedIntakeRequest request
      :. (uuid, stateOf (Appointed request.appointed)) )

-- ═══════════════════════════════════════════════════════════════════════════
-- READS
-- ═══════════════════════════════════════════════════════════════════════════

-- ── By id ──────────────────────────────────────────────────────────────────

fetchDoctor :: Connection -> DoctorId -> IO (Maybe Doctor)
fetchDoctor conn (DoctorId uuid) =
  fmap toDomainDoctor . single <$>
    query conn ("SELECT " <> doctorColumns <> " FROM doctors WHERE id = ?") (Only uuid)

fetchPatient :: Connection -> PatientId -> IO (Maybe Patient)
fetchPatient conn (PatientId uuid) =
  fmap toDomainPatient . single <$>
    query conn ("SELECT " <> patientColumns <> " FROM patients WHERE id = ?") (Only uuid)

fetchHealthcareService
  :: Connection -> HealthcareServiceId -> IO (Either DecodeError (Maybe HealthcareService))
fetchHealthcareService conn (HealthcareServiceId uuid) =
  traverse toDomainHealthcareService . single <$>
    query conn
      ("SELECT " <> healthcareServiceColumns <> " FROM healthcare_services WHERE id = ?")
      (Only uuid)

fetchAvailableSlot :: Connection -> SlotId -> IO (Either DecodeError (Maybe AvailableSlot))
fetchAvailableSlot conn (SlotId uuid) =
  traverse toDomainAvailableSlot . single <$>
    query conn ("SELECT " <> availableSlotColumns <> " FROM available_slots WHERE id = ?")
      (Only uuid)

fetchIntakeRequest
  :: Connection -> IntakeRequestId -> IO (Either DecodeError (Maybe IntakeRequest))
fetchIntakeRequest conn (IntakeRequestId uuid) =
  traverse toDomainIntakeRequest . single <$>
    query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests WHERE id = ?")
      (Only uuid)

single :: [a] -> Maybe a
single = \case
  [x] -> Just x
  _   -> Nothing

-- ── All (entities that are neither sum types nor sealed-collection elements)

fetchDoctors :: Connection -> IO [Doctor]
fetchDoctors conn =
  map toDomainDoctor <$>
    query_ conn ("SELECT " <> doctorColumns <> " FROM doctors ORDER BY name")

fetchPatients :: Connection -> IO [Patient]
fetchPatients conn =
  map toDomainPatient <$>
    query_ conn ("SELECT " <> patientColumns <> " FROM patients ORDER BY name")

fetchHealthcareServices :: Connection -> IO (Either DecodeError [HealthcareService])
fetchHealthcareServices conn =
  traverse toDomainHealthcareService <$>
    query_ conn
      ("SELECT " <> healthcareServiceColumns <> " FROM healthcare_services ORDER BY name, duration")



-- ── By case ────────────────────────────────────────────────────────────────

fetchSubmittedIntakeRequests :: Connection -> IO (Either DecodeError [SubmittedIntakeRequest])
fetchSubmittedIntakeRequests conn =
  traverse decodeSubmitted <$>
    query_ conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'submitted' ORDER BY created_at")

fetchAcceptedIntakeRequests :: Connection -> IO (Either DecodeError [TriagedIntakeRequest])
fetchAcceptedIntakeRequests conn =
  traverse decodeAccepted <$>
    query_ conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'accepted' ORDER BY triaged_at")

fetchAppointedIntakeRequests :: Connection -> IO (Either DecodeError [AppointedIntakeRequest])
fetchAppointedIntakeRequests conn =
  traverse decodeAppointed <$>
    query_ conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'appointed' ORDER BY start")

-- ── Terminal cases, by time range [from, to) ───────────────────────────────

fetchRejectedIntakeRequestsByRejectedAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [RejectedIntakeRequest])
fetchRejectedIntakeRequestsByRejectedAt conn from to =
  traverse decodeRejected <$>
    query conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'rejected' \
           \AND rejected_at >= ? AND rejected_at < ? ORDER BY rejected_at")
      (from, to)

fetchWithdrawnIntakeRequestsByWithdrawnAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [WithdrawnIntakeRequest])
fetchWithdrawnIntakeRequestsByWithdrawnAt conn from to =
  traverse decodeWithdrawn <$>
    query conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'withdrawn' \
           \AND withdrawn_at >= ? AND withdrawn_at < ? ORDER BY withdrawn_at")
      (from, to)

fetchStaleIntakeRequestsByStaleAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [StaleIntakeRequest])
fetchStaleIntakeRequestsByStaleAt conn from to =
  traverse decodeStale <$>
    query conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'stale' \
           \AND stale_at >= ? AND stale_at < ? ORDER BY stale_at")
      (from, to)

-- ClosedIntakeRequest adds no timestamp on every row; the nearest embedded
-- stage, AppointedIntakeRequest, adds start.
fetchClosedIntakeRequestsByStart
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [ClosedIntakeRequest])
fetchClosedIntakeRequestsByStart conn from to =
  traverse decodeClosed <$>
    query conn
      ("SELECT " <> intakeRequestColumns
        <> " FROM intake_requests WHERE state = 'closed' \
           \AND start >= ? AND start < ? ORDER BY start")
      (from, to)

-- ── DoctorCalendar ─────────────────────────────────────────────────────────

-- Every doctor's entries overlapping [from, to), in one snapshot, rebuilt
-- through mkDoctorCalendar. The one read of the calendar: callers pass their
-- range, slot creation the new slot's interval.
fetchDoctorCalendarOverlapping
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError DoctorCalendar)
fetchDoctorCalendarOverlapping conn from to = do
  (slotRows, appointmentRows) <- withTransactionLevel RepeatableRead conn $ do
    slotRows <- query conn
      ("SELECT " <> availableSlotColumns <> " FROM available_slots \
       \WHERE tstzrange(start, start + make_interval(mins => duration)) && tstzrange(?, ?) \
       \ORDER BY start")
      (from, to)
    appointmentRows <- query conn
      ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
       \WHERE state = 'appointed' \
       \AND tstzrange(start, start + make_interval(mins => duration)) && tstzrange(?, ?) \
       \ORDER BY start")
      (from, to)
    pure (slotRows, appointmentRows)
  pure $ do
    entries <- calendarEntries slotRows appointmentRows
    maybe (Left DoctorCalendarRefused) Right (mkDoctorCalendar entries)

calendarEntries
  :: [AvailableSlotRow] -> [IntakeRequestRow] -> Either DecodeError [DoctorCalendarEntry]
calendarEntries slotRows appointmentRows = do
  slots        <- traverse toDomainAvailableSlot slotRows
  appointments <- traverse decodeAppointed appointmentRows
  pure (map Slot slots ++ map Appointment appointments)
