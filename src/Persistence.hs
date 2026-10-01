{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

-- Derived from src/Domain.hs by triage-db-codegen. Schema:
-- migrations/0001_init.sql. Every function takes a plain Connection; IDs
-- are minted in Service, never here.
module Persistence
  ( -- * Connections
    ConnectionPool

    -- * Decoding
  , DecodeError (..)

    -- * Write outcomes
  , ClaimOutcome (..)
  , AppointedClaimOutcome (..)
  , AvailableSlotInsertOutcome (..)

    -- * Rows
  , DoctorRow (..)
  , PatientRow (..)
  , HealthcareServiceRow (..)
  , AvailableSlotRow (..)
  , IntakeRequestRow (..)

    -- * Row decoding / encoding
  , toDomainDoctor
  , toDomainPatient
  , toDomainHealthcareService
  , toDomainAvailableSlot
  , toDomainIntakeRequest
  , fromDomainDoctor
  , fromDomainPatient
  , fromDomainHealthcareService
  , fromDomainAvailableSlot
  , fromDomainSubmittedIntakeRequest
  , fromDomainRejectedIntakeRequest
  , fromDomainTriagedIntakeRequest
  , fromDomainAppointedIntakeRequest
  , fromDomainWithdrawnIntakeRequest
  , fromDomainStaleIntakeRequest
  , fromDomainClosedIntakeRequest

    -- * Inserts
  , insertDoctor
  , insertPatient
  , insertHealthcareService
  , insertAvailableSlot
  , insertSubmittedIntakeRequest

    -- * Transitions
  , persistRejectedIntakeRequest
  , persistTriagedIntakeRequest
  , persistAppointedIntakeRequest
  , persistWithdrawnIntakeRequest
  , persistStaleIntakeRequest
  , persistClosedIntakeRequest

    -- * Reads by id
  , fetchDoctor
  , fetchPatient
  , fetchHealthcareService
  , fetchAvailableSlot
  , fetchIntakeRequest

    -- * Reads of all
  , fetchDoctors
  , fetchPatients
  , fetchHealthcareServices

    -- * Reads by case
  , fetchSubmittedIntakeRequests
  , fetchAcceptedIntakeRequests
  , fetchAppointedIntakeRequests
  , fetchRejectedIntakeRequestsByRejectedAt
  , fetchWithdrawnIntakeRequestsByWithdrawnAt
  , fetchStaleIntakeRequestsByStaleAt
  , fetchClosedIntakeRequestsByStart

    -- * Doctor calendar
  , fetchDoctorCalendarOverlapping
  , fetchDoctorCalendarEntriesOverlapping
  ) where

import Control.Exception                     (Exception, throwIO, try)
import Control.Monad                         (when)
import Data.Char                             (isUpper, toLower)
import Data.Int                              (Int64)
import Data.List                             (sortOn)
import Data.Pool                             (Pool)
import Data.Text                             (Text)
import Data.Time                             (UTCTime)
import Data.UUID                             (UUID)
import Database.PostgreSQL.Simple
  ( Connection, Only (..), Query, SqlError (..), execute, query, withTransaction )
import Database.PostgreSQL.Simple.FromRow    (FromRow (..), field)
import Database.PostgreSQL.Simple.Transaction (IsolationLevel (RepeatableRead), withTransactionLevel)

import qualified Data.Text as T

import Domain hiding (routineNotAfter, routineNotBefore)
import qualified Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- CONNECTIONS
-- ═══════════════════════════════════════════════════════════════════════════

type ConnectionPool = Pool Connection

-- ═══════════════════════════════════════════════════════════════════════════
-- DECODE ERRORS
-- ═══════════════════════════════════════════════════════════════════════════

-- One constructor per kind of failure. Shapes the CHECKs make impossible
-- are checked anyway.
data DecodeError
  = UnknownState Text                  -- ^ intake_requests.state
  | UnknownPriority Text               -- ^ intake_requests.priority
  | UnknownDuration Int                -- ^ a duration column, in minutes
  | UnknownAppointmentParty Text       -- ^ cancelled_by / absent_party
  | MissingValue Text                  -- ^ column required by the row's shape is NULL
  | UnexpectedValue Text               -- ^ column NULL in the row's shape is set
  | InvalidRoutineWindow UTCTime UTCTime -- ^ mkRoutineWindow refused
  | UnexpectedState Text               -- ^ a by-case read found another case
  | OverlappingDoctorCalendar          -- ^ mkDoctorCalendar refused
  deriving (Show, Eq)

instance Exception DecodeError

-- ═══════════════════════════════════════════════════════════════════════════
-- WRITE OUTCOMES
-- ═══════════════════════════════════════════════════════════════════════════

-- A write with a single guard.
data ClaimOutcome
  = Claimed
  | AlreadyClaimed
  deriving (Show, Eq)

-- Matching: two guarded rows, each can lose a race.
data AppointedClaimOutcome
  = AppointedClaimed
  | AvailableSlotAlreadyClaimed    -- ^ the slot's delete affected no row
  | IntakeRequestAlreadyClaimed    -- ^ the request's update affected no row
  deriving (Show, Eq)

-- A new element of DoctorCalendar: the EXCLUDE constraint can reject it.
data AvailableSlotInsertOutcome
  = AvailableSlotInserted
  | AvailableSlotOverlapsDoctorCalendar
  deriving (Show, Eq)

-- Internal: the request's update lost its race after the slot was deleted;
-- rolls the matching transaction back.
data IntakeRequestClaimLost = IntakeRequestClaimLost
  deriving (Show)

instance Exception IntakeRequestClaimLost

claim :: Int64 -> ClaimOutcome
claim 0 = AlreadyClaimed
claim _ = Claimed

-- ═══════════════════════════════════════════════════════════════════════════
-- ENUMERATIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Duration: whole minutes of durationToNominalDiffTime.
durationMinutes :: Duration -> Int
durationMinutes d = round (durationToNominalDiffTime d / 60)

toDomainDuration :: Int -> Either DecodeError Duration
toDomainDuration minutes =
  maybe (Left (UnknownDuration minutes)) Right
    (lookup minutes [ (durationMinutes d, d) | d <- [minBound .. maxBound] ])

-- Stored enumeration values are constructor names in snake_case.
snakeCase :: String -> Text
snakeCase = T.pack . go
  where
    go []       = []
    go (c : cs) = toLower c : concatMap (\x -> if isUpper x then ['_', toLower x] else [x]) cs

appointmentPartyText :: AppointmentParty -> Text
appointmentPartyText = snakeCase . show

toDomainAppointmentParty :: Text -> Either DecodeError AppointmentParty
toDomainAppointmentParty t =
  maybe (Left (UnknownAppointmentParty t)) Right
    (lookup t [ (appointmentPartyText p, p) | p <- [minBound .. maxBound] ])

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
  , duration :: Int
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
  , duration            :: Int
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
  , duration            :: Maybe Int
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

intakeRequestColumns :: Query
intakeRequestColumns =
  "id, state, patient_id, narrative, created_at, \
  \rejected_at, rejection_reason, \
  \healthcare_service_id, priority, must_be_seen_by, routine_not_before, \
  \routine_not_after, specific_doctor_id, triaged_at, \
  \doctor_id, start, duration, \
  \withdrawn_at, withdrawal_note, \
  \stale_at, \
  \cancelled_by, cancelled_at, cancellation_note, absent_party"

availableSlotColumns :: Query
availableSlotColumns = "id, doctor_id, healthcare_service_id, start, duration"

-- ═══════════════════════════════════════════════════════════════════════════
-- DECODING (row -> Domain)
-- ═══════════════════════════════════════════════════════════════════════════

toDomainDoctor :: DoctorRow -> Doctor
toDomainDoctor r = Doctor { id = DoctorId r.id, name = r.name }

toDomainPatient :: PatientRow -> Patient
toDomainPatient r = Patient { id = PatientId r.id, name = r.name }

toDomainHealthcareService :: HealthcareServiceRow -> Either DecodeError HealthcareService
toDomainHealthcareService r =
  (\d -> HealthcareService { id = HealthcareServiceId r.id, name = r.name, duration = d })
    <$> toDomainDuration r.duration

toDomainAvailableSlot :: AvailableSlotRow -> Either DecodeError AvailableSlot
toDomainAvailableSlot r =
  (\d -> AvailableSlot
      { id                  = SlotId r.id
      , doctorId            = DoctorId r.doctorId
      , healthcareServiceId = HealthcareServiceId r.healthcareServiceId
      , start               = r.start
      , duration            = d
      })
    <$> toDomainDuration r.duration

-- A column the row's shape requires.
required :: Text -> Maybe a -> Either DecodeError a
required column = maybe (Left (MissingValue column)) Right

-- A column the row's shape leaves NULL.
absent :: Text -> Maybe a -> Either DecodeError ()
absent _      Nothing  = Right ()
absent column (Just _) = Left (UnexpectedValue column)

-- One function, branching on the discriminator.
toDomainIntakeRequest :: IntakeRequestRow -> Either DecodeError IntakeRequest
toDomainIntakeRequest r = case r.state of
  "submitted" -> do
    absentRejected r; absentTriaged r; absentAppointed r
    absentWithdrawn r; absentStale r; absentCloseReason r
    pure (Submitted (submittedStage r))
  "rejected" -> do
    absentTriaged r; absentAppointed r; absentWithdrawn r; absentStale r; absentCloseReason r
    rejectedAt      <- required "rejected_at" r.rejectedAt
    rejectionReason <- required "rejection_reason" r.rejectionReason
    pure (Rejected RejectedIntakeRequest { submitted = submittedStage r, rejectedAt, rejectionReason })
  "accepted" -> do
    absentRejected r; absentAppointed r; absentWithdrawn r; absentStale r; absentCloseReason r
    Accepted <$> triagedStage r
  "appointed" -> do
    absentRejected r; absentWithdrawn r; absentStale r; absentCloseReason r
    Appointed <$> appointedStage r
  "withdrawn" -> do
    absentRejected r; absentAppointed r; absentStale r; absentCloseReason r
    withdrawnFrom <- withdrawnFromStage r
    withdrawnAt   <- required "withdrawn_at" r.withdrawnAt
    pure (Withdrawn WithdrawnIntakeRequest { withdrawnFrom, withdrawnAt, withdrawalNote = r.withdrawalNote })
  "stale" -> do
    absentRejected r; absentAppointed r; absentWithdrawn r; absentCloseReason r
    triaged <- triagedStage r
    staleAt <- required "stale_at" r.staleAt
    pure (Stale StaleIntakeRequest { triaged, staleAt })
  "closed" -> do
    absentRejected r; absentWithdrawn r; absentStale r
    appointed   <- appointedStage r
    closeReason <- closeReasonOf r
    pure (Closed ClosedIntakeRequest { appointed, closeReason })
  other -> Left (UnknownState other)

submittedStage :: IntakeRequestRow -> SubmittedIntakeRequest
submittedStage r = SubmittedIntakeRequest
  { id        = IntakeRequestId r.id
  , patientId = PatientId r.patientId
  , narrative = r.narrative
  , createdAt = r.createdAt
  }

triagedStage :: IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
triagedStage r = do
  serviceUuid       <- required "healthcare_service_id" r.healthcareServiceId
  priority          <- priorityOf r
  triagedAt         <- required "triaged_at" r.triagedAt
  pure TriagedIntakeRequest
    { submitted           = submittedStage r
    , healthcareServiceId = HealthcareServiceId serviceUuid
    , priority
    , doctorRequirement   = doctorRequirementOf r
    , triagedAt
    }

appointedStage :: IntakeRequestRow -> Either DecodeError AppointedIntakeRequest
appointedStage r = do
  triaged     <- triagedStage r
  doctorUuid  <- required "doctor_id" r.doctorId
  start       <- required "start" r.start
  minutes     <- required "duration" r.duration
  duration    <- toDomainDuration minutes
  pure AppointedIntakeRequest { triaged, doctorId = DoctorId doctorUuid, start, duration }

-- FromSubmitted is identified by none of FromAccepted's columns being set,
-- the same combination as the CHECKs.
withdrawnFromStage :: IntakeRequestRow -> Either DecodeError WithdrawnFrom
withdrawnFromStage r =
  case (r.healthcareServiceId, r.priority, r.triagedAt) of
    (Nothing, Nothing, Nothing) -> do
      absentTriaged r
      pure (FromSubmitted (submittedStage r))
    _ -> FromAccepted <$> triagedStage r

priorityOf :: IntakeRequestRow -> Either DecodeError IntakeRequestPriority
priorityOf r = do
  discriminator <- required "priority" r.priority
  case discriminator of
    "emergency" -> do
      absentRoutineDue
      Emergency . MustBeSeenBy <$> required "must_be_seen_by" r.mustBeSeenBy
    "urgent" -> do
      absentRoutineDue
      Urgent . MustBeSeenBy <$> required "must_be_seen_by" r.mustBeSeenBy
    "routine" -> do
      absent "must_be_seen_by" r.mustBeSeenBy
      Routine <$> routineDueOf r
    other -> Left (UnknownPriority other)
  where
    absentRoutineDue = do
      absent "routine_not_before" r.routineNotBefore
      absent "routine_not_after" r.routineNotAfter

-- Told apart by which columns are set.
routineDueOf :: IntakeRequestRow -> Either DecodeError RoutineDue
routineDueOf r = case (r.routineNotBefore, r.routineNotAfter) of
  (Nothing, Nothing) -> Right RoutineAnytime
  (Just nb, Nothing) -> Right (RoutineNotBefore nb)
  (Nothing, Just na) -> Right (RoutineNotAfter na)
  (Just nb, Just na) ->
    maybe (Left (InvalidRoutineWindow nb na)) (Right . RoutineWithin) (mkRoutineWindow nb na)

doctorRequirementOf :: IntakeRequestRow -> DoctorRequirement
doctorRequirementOf r = maybe AnyDoctor (SpecificDoctor . DoctorId) r.specificDoctorId

-- Told apart by which columns are set.
closeReasonOf :: IntakeRequestRow -> Either DecodeError CloseReason
closeReasonOf r = case (r.cancelledBy, r.cancelledAt, r.absentParty) of
  (Nothing, Nothing, Nothing) -> do
    absent "cancellation_note" r.cancellationNote
    pure Completed
  (Nothing, Nothing, Just party) -> do
    absent "cancellation_note" r.cancellationNote
    absentParty <- toDomainAppointmentParty party
    pure (NoShow Absence { absentParty })
  (_, _, Just _) -> Left (UnexpectedValue "absent_party")
  (by, at, Nothing) -> do
    byText      <- required "cancelled_by" by
    cancelledAt <- required "cancelled_at" at
    cancelledBy <- toDomainAppointmentParty byText
    pure (Cancelled Cancellation { cancelledBy, cancelledAt, cancellationNote = r.cancellationNote })

absentRejected, absentTriaged, absentAppointed, absentWithdrawn, absentStale, absentCloseReason
  :: IntakeRequestRow -> Either DecodeError ()
absentRejected r = do
  absent "rejected_at" r.rejectedAt
  absent "rejection_reason" r.rejectionReason
absentTriaged r = do
  absent "healthcare_service_id" r.healthcareServiceId
  absent "priority" r.priority
  absent "must_be_seen_by" r.mustBeSeenBy
  absent "routine_not_before" r.routineNotBefore
  absent "routine_not_after" r.routineNotAfter
  absent "specific_doctor_id" r.specificDoctorId
  absent "triaged_at" r.triagedAt
absentAppointed r = do
  absent "doctor_id" r.doctorId
  absent "start" r.start
  absent "duration" r.duration
absentWithdrawn r = do
  absent "withdrawn_at" r.withdrawnAt
  absent "withdrawal_note" r.withdrawalNote
absentStale r =
  absent "stale_at" r.staleAt
absentCloseReason r = do
  absent "cancelled_by" r.cancelledBy
  absent "cancelled_at" r.cancelledAt
  absent "cancellation_note" r.cancellationNote
  absent "absent_party" r.absentParty

-- Decodes a row and keeps it only in the expected case.
decodeCase :: (IntakeRequest -> Maybe a) -> IntakeRequestRow -> Either DecodeError a
decodeCase select r = do
  request <- toDomainIntakeRequest r
  maybe (Left (UnexpectedState r.state)) Right (select request)

submittedCase :: IntakeRequest -> Maybe SubmittedIntakeRequest
submittedCase (Submitted s) = Just s
submittedCase _             = Nothing

rejectedCase :: IntakeRequest -> Maybe RejectedIntakeRequest
rejectedCase (Rejected s) = Just s
rejectedCase _            = Nothing

acceptedCase :: IntakeRequest -> Maybe TriagedIntakeRequest
acceptedCase (Accepted s) = Just s
acceptedCase _            = Nothing

appointedCase :: IntakeRequest -> Maybe AppointedIntakeRequest
appointedCase (Appointed s) = Just s
appointedCase _             = Nothing

withdrawnCase :: IntakeRequest -> Maybe WithdrawnIntakeRequest
withdrawnCase (Withdrawn s) = Just s
withdrawnCase _             = Nothing

staleCase :: IntakeRequest -> Maybe StaleIntakeRequest
staleCase (Stale s) = Just s
staleCase _         = Nothing

closedCase :: IntakeRequest -> Maybe ClosedIntakeRequest
closedCase (Closed s) = Just s
closedCase _          = Nothing

-- ═══════════════════════════════════════════════════════════════════════════
-- ENCODING (Domain -> row)
-- ═══════════════════════════════════════════════════════════════════════════

fromDomainDoctor :: Doctor -> DoctorRow
fromDomainDoctor d =
  let DoctorId uuid = d.id
  in DoctorRow { id = uuid, name = d.name }

fromDomainPatient :: Patient -> PatientRow
fromDomainPatient p =
  let PatientId uuid = p.id
  in PatientRow { id = uuid, name = p.name }

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceRow
fromDomainHealthcareService s =
  let HealthcareServiceId uuid = s.id
  in HealthcareServiceRow { id = uuid, name = s.name, duration = durationMinutes s.duration }

fromDomainAvailableSlot :: AvailableSlot -> AvailableSlotRow
fromDomainAvailableSlot s =
  let SlotId slotUuid                = s.id
      DoctorId doctorUuid            = s.doctorId
      HealthcareServiceId serviceUuid = s.healthcareServiceId
  in AvailableSlotRow
       { id                  = slotUuid
       , doctorId            = doctorUuid
       , healthcareServiceId = serviceUuid
       , start               = s.start
       , duration            = durationMinutes s.duration
       }

-- The intake request's encoding is split per case. Each builds the whole
-- row of its case from the stage it embeds plus its own columns.

-- intakeRequestRow state submitted rejected triaged appointed withdrawn
-- stale closed: a stage's columns are NULL unless the case contains it.
intakeRequestRow
  :: Text
  -> SubmittedIntakeRequest
  -> Maybe RejectedIntakeRequest
  -> Maybe TriagedIntakeRequest
  -> Maybe AppointedIntakeRequest
  -> Maybe WithdrawnIntakeRequest
  -> Maybe StaleIntakeRequest
  -> Maybe ClosedIntakeRequest
  -> IntakeRequestRow
intakeRequestRow stateText s mRejected mTriaged mAppointed mWithdrawn mStale mClosed =
  let IntakeRequestId requestUuid = s.id
      PatientId patientUuid       = s.patientId
      (priorityText, mustBeSeenByAt, notBefore, notAfter) =
        maybe (Nothing, Nothing, Nothing, Nothing) (\t -> priorityColumns t.priority) mTriaged
      (byText, atTime, noteText, partyText) =
        maybe (Nothing, Nothing, Nothing, Nothing) (\c -> closeReasonColumns c.closeReason) mClosed
  in IntakeRequestRow
       { id                  = requestUuid
       , state               = stateText
       , patientId           = patientUuid
       , narrative           = s.narrative
       , createdAt           = s.createdAt
       , rejectedAt          = (\x -> x.rejectedAt) <$> mRejected
       , rejectionReason     = (\x -> x.rejectionReason) <$> mRejected
       , healthcareServiceId = (\t -> let HealthcareServiceId u = t.healthcareServiceId in u) <$> mTriaged
       , priority            = priorityText
       , mustBeSeenBy        = mustBeSeenByAt
       , routineNotBefore    = notBefore
       , routineNotAfter     = notAfter
       , specificDoctorId    = mTriaged >>= \t -> doctorRequirementColumn t.doctorRequirement
       , triagedAt           = (\t -> t.triagedAt) <$> mTriaged
       , doctorId            = (\a -> let DoctorId u = a.doctorId in u) <$> mAppointed
       , start               = (\a -> a.start) <$> mAppointed
       , duration            = (\a -> durationMinutes a.duration) <$> mAppointed
       , withdrawnAt         = (\w -> w.withdrawnAt) <$> mWithdrawn
       , withdrawalNote      = mWithdrawn >>= \w -> w.withdrawalNote
       , staleAt             = (\x -> x.staleAt) <$> mStale
       , cancelledBy         = byText
       , cancelledAt         = atTime
       , cancellationNote    = noteText
       , absentParty         = partyText
       }

fromDomainSubmittedIntakeRequest :: SubmittedIntakeRequest -> IntakeRequestRow
fromDomainSubmittedIntakeRequest s =
  intakeRequestRow "submitted" s Nothing Nothing Nothing Nothing Nothing Nothing

fromDomainRejectedIntakeRequest :: RejectedIntakeRequest -> IntakeRequestRow
fromDomainRejectedIntakeRequest r =
  intakeRequestRow "rejected" r.submitted (Just r) Nothing Nothing Nothing Nothing Nothing

fromDomainTriagedIntakeRequest :: TriagedIntakeRequest -> IntakeRequestRow
fromDomainTriagedIntakeRequest t =
  intakeRequestRow "accepted" t.submitted Nothing (Just t) Nothing Nothing Nothing Nothing

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> IntakeRequestRow
fromDomainAppointedIntakeRequest a =
  intakeRequestRow "appointed" a.triaged.submitted
    Nothing (Just a.triaged) (Just a) Nothing Nothing Nothing

fromDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequest -> IntakeRequestRow
fromDomainWithdrawnIntakeRequest w = case w.withdrawnFrom of
  FromSubmitted s ->
    intakeRequestRow "withdrawn" s Nothing Nothing Nothing (Just w) Nothing Nothing
  FromAccepted t ->
    intakeRequestRow "withdrawn" t.submitted Nothing (Just t) Nothing (Just w) Nothing Nothing

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> IntakeRequestRow
fromDomainStaleIntakeRequest s =
  intakeRequestRow "stale" s.triaged.submitted Nothing (Just s.triaged) Nothing Nothing (Just s) Nothing

fromDomainClosedIntakeRequest :: ClosedIntakeRequest -> IntakeRequestRow
fromDomainClosedIntakeRequest c =
  intakeRequestRow "closed" c.appointed.triaged.submitted
    Nothing (Just c.appointed.triaged) (Just c.appointed) Nothing Nothing (Just c)

-- (priority, must_be_seen_by, routine_not_before, routine_not_after).
-- A total case, so a new constructor is flagged by -Wall.
priorityColumns
  :: IntakeRequestPriority -> (Maybe Text, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime)
priorityColumns p = case p of
  Emergency (MustBeSeenBy t) -> (Just "emergency", Just t, Nothing, Nothing)
  Urgent    (MustBeSeenBy t) -> (Just "urgent", Just t, Nothing, Nothing)
  Routine due -> case due of
    RoutineAnytime     -> (Just "routine", Nothing, Nothing, Nothing)
    RoutineNotBefore t -> (Just "routine", Nothing, Just t, Nothing)
    RoutineNotAfter  t -> (Just "routine", Nothing, Nothing, Just t)
    RoutineWithin    w ->
      (Just "routine", Nothing, Just (Domain.routineNotBefore w), Just (Domain.routineNotAfter w))

-- specific_doctor_id.
doctorRequirementColumn :: DoctorRequirement -> Maybe UUID
doctorRequirementColumn AnyDoctor                      = Nothing
doctorRequirementColumn (SpecificDoctor (DoctorId u)) = Just u

-- (cancelled_by, cancelled_at, cancellation_note, absent_party).
closeReasonColumns :: CloseReason -> (Maybe Text, Maybe UTCTime, Maybe Text, Maybe Text)
closeReasonColumns reason = case reason of
  Completed -> (Nothing, Nothing, Nothing, Nothing)
  Cancelled c ->
    (Just (appointmentPartyText c.cancelledBy), Just c.cancelledAt, c.cancellationNote, Nothing)
  NoShow a -> (Nothing, Nothing, Nothing, Just (appointmentPartyText a.absentParty))

-- ═══════════════════════════════════════════════════════════════════════════
-- INSERTS
-- ═══════════════════════════════════════════════════════════════════════════

insertDoctor :: Connection -> Doctor -> IO ()
insertDoctor conn d = do
  let r = fromDomainDoctor d
  _ <- execute conn "INSERT INTO doctors (id, name) VALUES (?, ?)" (r.id, r.name)
  pure ()

insertPatient :: Connection -> Patient -> IO ()
insertPatient conn p = do
  let r = fromDomainPatient p
  _ <- execute conn "INSERT INTO patients (id, name) VALUES (?, ?)" (r.id, r.name)
  pure ()

insertHealthcareService :: Connection -> HealthcareService -> IO ()
insertHealthcareService conn s = do
  let r = fromDomainHealthcareService s
  _ <- execute conn
    "INSERT INTO healthcare_services (id, name, duration) VALUES (?, ?, ?)"
    (r.id, r.name, r.duration)
  pure ()

-- A new element of DoctorCalendar: catches exactly the EXCLUDE violation
-- (23P01) and rethrows anything else.
insertAvailableSlot :: Connection -> AvailableSlot -> IO AvailableSlotInsertOutcome
insertAvailableSlot conn s = do
  let r = fromDomainAvailableSlot s
  result <- try $ execute conn
    "INSERT INTO available_slots (id, doctor_id, healthcare_service_id, start, duration) \
    \VALUES (?, ?, ?, ?, ?)"
    (r.id, r.doctorId, r.healthcareServiceId, r.start, r.duration)
  case result of
    Right _ -> pure AvailableSlotInserted
    Left e
      | sqlState e == "23P01" -> pure AvailableSlotOverlapsDoctorCalendar
      | otherwise             -> throwIO e

-- The entry case of IntakeRequest.
insertSubmittedIntakeRequest :: Connection -> SubmittedIntakeRequest -> IO ()
insertSubmittedIntakeRequest conn s = do
  let r = fromDomainSubmittedIntakeRequest s
  _ <- execute conn
    "INSERT INTO intake_requests (id, state, patient_id, narrative, created_at) \
    \VALUES (?, 'submitted', ?, ?, ?)"
    (r.id, r.patientId, r.narrative, r.createdAt)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════════
-- TRANSITIONS
-- Each UPDATE follows a transition Domain.hs defines, guarded by its one
-- source case. Each sets only the columns the target stage adds.
--   Submitted -> Rejected   (RejectedIntakeRequest)
--   Submitted -> Accepted   (acceptIntakeRequest)
--   Accepted  -> Appointed  (matchIntakeRequestToSlot)
--   Submitted -> Withdrawn  (WithdrawnIntakeRequest, FromSubmitted)
--   Accepted  -> Withdrawn  (WithdrawnIntakeRequest, FromAccepted)
--   Accepted  -> Stale      (StaleIntakeRequest)
--   Appointed -> Closed     (ClosedIntakeRequest)
-- ═══════════════════════════════════════════════════════════════════════════

persistRejectedIntakeRequest :: Connection -> RejectedIntakeRequest -> IO ClaimOutcome
persistRejectedIntakeRequest conn rejected = do
  let r = fromDomainRejectedIntakeRequest rejected
  claim <$> execute conn
    "UPDATE intake_requests SET state = 'rejected', rejected_at = ?, rejection_reason = ? \
    \WHERE id = ? AND state = 'submitted'"
    (r.rejectedAt, r.rejectionReason, r.id)

persistTriagedIntakeRequest :: Connection -> TriagedIntakeRequest -> IO ClaimOutcome
persistTriagedIntakeRequest conn triaged = do
  let r = fromDomainTriagedIntakeRequest triaged
  claim <$> execute conn
    "UPDATE intake_requests SET state = 'accepted', healthcare_service_id = ?, priority = ?, \
    \must_be_seen_by = ?, routine_not_before = ?, routine_not_after = ?, \
    \specific_doctor_id = ?, triaged_at = ? \
    \WHERE id = ? AND state = 'submitted'"
    ( r.healthcareServiceId, r.priority, r.mustBeSeenBy, r.routineNotBefore
    , r.routineNotAfter, r.specificDoctorId, r.triagedAt, r.id )

-- Matching: deletes the consumed slot, then moves the request from
-- accepted to appointed over the slot's interval, in one transaction. If
-- the request's update loses its race, the slot's delete is rolled back.
persistAppointedIntakeRequest
  :: Connection -> AvailableSlot -> AppointedIntakeRequest -> IO AppointedClaimOutcome
persistAppointedIntakeRequest conn slot appointed = do
  let SlotId slotUuid = slot.id
      r               = fromDomainAppointedIntakeRequest appointed
  result <- try $ withTransaction conn $ do
    deleted <- execute conn "DELETE FROM available_slots WHERE id = ?" (Only slotUuid)
    if deleted == 0
      then pure AvailableSlotAlreadyClaimed
      else do
        updated <- execute conn
          "UPDATE intake_requests SET state = 'appointed', doctor_id = ?, start = ?, duration = ? \
          \WHERE id = ? AND state = 'accepted'"
          (r.doctorId, r.start, r.duration, r.id)
        when (updated == 0) (throwIO IntakeRequestClaimLost)
        pure AppointedClaimed
  case result of
    Left IntakeRequestClaimLost -> pure IntakeRequestAlreadyClaimed
    Right outcome               -> pure outcome

-- The source case's guard comes from the value's withdrawnFrom.
persistWithdrawnIntakeRequest :: Connection -> WithdrawnIntakeRequest -> IO ClaimOutcome
persistWithdrawnIntakeRequest conn withdrawn = do
  let r = fromDomainWithdrawnIntakeRequest withdrawn
  claim <$> case withdrawn.withdrawnFrom of
    FromSubmitted _ -> execute conn
      "UPDATE intake_requests SET state = 'withdrawn', withdrawn_at = ?, withdrawal_note = ? \
      \WHERE id = ? AND state = 'submitted'"
      (r.withdrawnAt, r.withdrawalNote, r.id)
    FromAccepted _ -> execute conn
      "UPDATE intake_requests SET state = 'withdrawn', withdrawn_at = ?, withdrawal_note = ? \
      \WHERE id = ? AND state = 'accepted'"
      (r.withdrawnAt, r.withdrawalNote, r.id)

persistStaleIntakeRequest :: Connection -> StaleIntakeRequest -> IO ClaimOutcome
persistStaleIntakeRequest conn stale = do
  let r = fromDomainStaleIntakeRequest stale
  claim <$> execute conn
    "UPDATE intake_requests SET state = 'stale', stale_at = ? \
    \WHERE id = ? AND state = 'accepted'"
    (r.staleAt, r.id)

persistClosedIntakeRequest :: Connection -> ClosedIntakeRequest -> IO ClaimOutcome
persistClosedIntakeRequest conn closed = do
  let r = fromDomainClosedIntakeRequest closed
  claim <$> execute conn
    "UPDATE intake_requests SET state = 'closed', cancelled_by = ?, cancelled_at = ?, \
    \cancellation_note = ?, absent_party = ? \
    \WHERE id = ? AND state = 'appointed'"
    (r.cancelledBy, r.cancelledAt, r.cancellationNote, r.absentParty, r.id)

-- ═══════════════════════════════════════════════════════════════════════════
-- READS BY ID
-- ═══════════════════════════════════════════════════════════════════════════

single :: [a] -> Maybe a
single (x : _) = Just x
single []      = Nothing

fetchDoctor :: Connection -> DoctorId -> IO (Maybe Doctor)
fetchDoctor conn (DoctorId uuid) =
  fmap toDomainDoctor . single
    <$> query conn "SELECT id, name FROM doctors WHERE id = ?" (Only uuid)

fetchPatient :: Connection -> PatientId -> IO (Maybe Patient)
fetchPatient conn (PatientId uuid) =
  fmap toDomainPatient . single
    <$> query conn "SELECT id, name FROM patients WHERE id = ?" (Only uuid)

fetchHealthcareService
  :: Connection -> HealthcareServiceId -> IO (Either DecodeError (Maybe HealthcareService))
fetchHealthcareService conn (HealthcareServiceId uuid) =
  traverse toDomainHealthcareService . single
    <$> query conn "SELECT id, name, duration FROM healthcare_services WHERE id = ?" (Only uuid)

fetchAvailableSlot :: Connection -> SlotId -> IO (Either DecodeError (Maybe AvailableSlot))
fetchAvailableSlot conn (SlotId uuid) =
  traverse toDomainAvailableSlot . single
    <$> query conn ("SELECT " <> availableSlotColumns <> " FROM available_slots WHERE id = ?")
          (Only uuid)

fetchIntakeRequest
  :: Connection -> IntakeRequestId -> IO (Either DecodeError (Maybe IntakeRequest))
fetchIntakeRequest conn (IntakeRequestId uuid) =
  traverse toDomainIntakeRequest . single
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests WHERE id = ?")
          (Only uuid)

-- ═══════════════════════════════════════════════════════════════════════════
-- READS OF ALL (ordered by non-ID fields, in declaration order)
-- ═══════════════════════════════════════════════════════════════════════════

fetchDoctors :: Connection -> IO [Doctor]
fetchDoctors conn =
  map toDomainDoctor <$> query conn "SELECT id, name FROM doctors ORDER BY name" ()

fetchPatients :: Connection -> IO [Patient]
fetchPatients conn =
  map toDomainPatient <$> query conn "SELECT id, name FROM patients ORDER BY name" ()

fetchHealthcareServices :: Connection -> IO (Either DecodeError [HealthcareService])
fetchHealthcareServices conn =
  traverse toDomainHealthcareService
    <$> query conn "SELECT id, name, duration FROM healthcare_services ORDER BY name, duration" ()

-- ═══════════════════════════════════════════════════════════════════════════
-- READS BY CASE
-- ═══════════════════════════════════════════════════════════════════════════

-- Non-terminal cases, ordered by the timestamp their stage adds.

fetchSubmittedIntakeRequests :: Connection -> IO (Either DecodeError [SubmittedIntakeRequest])
fetchSubmittedIntakeRequests conn =
  traverse (decodeCase submittedCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'submitted' ORDER BY created_at") ()

fetchAcceptedIntakeRequests :: Connection -> IO (Either DecodeError [TriagedIntakeRequest])
fetchAcceptedIntakeRequests conn =
  traverse (decodeCase acceptedCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'accepted' ORDER BY triaged_at") ()

fetchAppointedIntakeRequests :: Connection -> IO (Either DecodeError [AppointedIntakeRequest])
fetchAppointedIntakeRequests conn =
  traverse (decodeCase appointedCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'appointed' ORDER BY start") ()

-- Terminal cases, by a half-open time range [from, to).

fetchRejectedIntakeRequestsByRejectedAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [RejectedIntakeRequest])
fetchRejectedIntakeRequestsByRejectedAt conn from to =
  traverse (decodeCase rejectedCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'rejected' AND rejected_at >= ? AND rejected_at < ? \
                    \ORDER BY rejected_at") (from, to)

fetchWithdrawnIntakeRequestsByWithdrawnAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [WithdrawnIntakeRequest])
fetchWithdrawnIntakeRequestsByWithdrawnAt conn from to =
  traverse (decodeCase withdrawnCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'withdrawn' AND withdrawn_at >= ? AND withdrawn_at < ? \
                    \ORDER BY withdrawn_at") (from, to)

fetchStaleIntakeRequestsByStaleAt
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [StaleIntakeRequest])
fetchStaleIntakeRequestsByStaleAt conn from to =
  traverse (decodeCase staleCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'stale' AND stale_at >= ? AND stale_at < ? \
                    \ORDER BY stale_at") (from, to)

-- ClosedIntakeRequest adds no timestamp to every row; the nearest stage it
-- embeds (AppointedIntakeRequest) adds start.
fetchClosedIntakeRequestsByStart
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [ClosedIntakeRequest])
fetchClosedIntakeRequestsByStart conn from to =
  traverse (decodeCase closedCase)
    <$> query conn ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
                    \WHERE state = 'closed' AND start >= ? AND start < ? \
                    \ORDER BY start") (from, to)

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR CALENDAR
-- Read from the source tables (available_slots, intake_requests in
-- 'appointed'), in one REPEATABLE READ snapshot. The doctor_calendar
-- shadow table only enforces the invariant.
-- ═══════════════════════════════════════════════════════════════════════════

-- The part of DoctorCalendar needed to judge a new element: the doctor's
-- entries overlapping [from, to). Rebuilt through mkDoctorCalendar.
fetchDoctorCalendarOverlapping
  :: Connection -> DoctorId -> UTCTime -> UTCTime -> IO (Either DecodeError DoctorCalendar)
fetchDoctorCalendarOverlapping conn (DoctorId doctorUuid) from to =
  withTransactionLevel RepeatableRead conn $ do
    slotRows <- query conn
      ("SELECT " <> availableSlotColumns <> " FROM available_slots \
       \WHERE doctor_id = ? AND start < ? AND start + duration * INTERVAL '1 minute' > ? \
       \ORDER BY start")
      (doctorUuid, to, from)
    appointedRows <- query conn
      ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
       \WHERE state = 'appointed' AND doctor_id = ? \
       \AND start < ? AND start + duration * INTERVAL '1 minute' > ? \
       \ORDER BY start")
      (doctorUuid, to, from)
    pure $ do
      entries <- calendarEntries slotRows appointedRows
      maybe (Left OverlappingDoctorCalendar) Right (mkDoctorCalendar entries)

-- DoctorCalendar's elements, every doctor's, overlapping [from, to),
-- sorted by start.
fetchDoctorCalendarEntriesOverlapping
  :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError [DoctorCalendarEntry])
fetchDoctorCalendarEntriesOverlapping conn from to =
  withTransactionLevel RepeatableRead conn $ do
    slotRows <- query conn
      ("SELECT " <> availableSlotColumns <> " FROM available_slots \
       \WHERE start < ? AND start + duration * INTERVAL '1 minute' > ? \
       \ORDER BY start")
      (to, from)
    appointedRows <- query conn
      ("SELECT " <> intakeRequestColumns <> " FROM intake_requests \
       \WHERE state = 'appointed' \
       \AND start < ? AND start + duration * INTERVAL '1 minute' > ? \
       \ORDER BY start")
      (to, from)
    pure (sortOn doctorCalendarEntryStart <$> calendarEntries slotRows appointedRows)

calendarEntries
  :: [AvailableSlotRow] -> [IntakeRequestRow] -> Either DecodeError [DoctorCalendarEntry]
calendarEntries slotRows appointedRows = do
  slots        <- traverse toDomainAvailableSlot slotRows
  appointments <- traverse (decodeCase appointedCase) appointedRows
  pure (map Slot slots ++ map Appointment appointments)
