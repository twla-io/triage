{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

-- Persistence layer for the triage domain model. Row types and
-- toDomainX/fromDomainX boundary functions, generated from src/Domain.hs
-- per .claude/skills/triage-db-codegen/SKILL.md. Re-derive from Domain.hs
-- on any domain change rather than hand-patching this file out of sync
-- with it.

module Persistence
  ( -- ── Connection pooling ───────────────────────────────────────────────
    ConnectionPool

    -- ── Decode errors ────────────────────────────────────────────────────
  , DecodeError (..)

    -- ── Doctor / Patient ─────────────────────────────────────────────────
  , DoctorRow (..)
  , toDomainDoctor
  , fromDomainDoctor
  , fetchDoctor
  , insertDoctor
  , PatientRow (..)
  , toDomainPatient
  , fromDomainPatient
  , fetchPatient
  , insertPatient

    -- ── Healthcare Service ───────────────────────────────────────────────
  , HealthcareServiceRow (..)
  , decodeDuration
  , encodeDuration
  , toDomainHealthcareService
  , fromDomainHealthcareService
  , fetchHealthcareService
  , insertHealthcareService

    -- ── Slot ─────────────────────────────────────────────────────────────
  , SlotRow (..)
  , toDomainSlot
  , fromDomainSlot
  , fetchSlot
  , insertAvailableSlot
  , SlotOverlap (..)
  , ClaimOutcome (..)

    -- ── Intake Request ───────────────────────────────────────────────────
  , IntakeRequestRow (..)
  , toDomainIntakeRequest
  , decodeSubmitted
  , decodeTriaged
  , decodeAppointed
  , fromDomainSubmitted
  , fromDomainRejected
  , fromDomainTriaged
  , fromDomainAppointed
  , fromDomainWithdrawn
  , fromDomainClosed
  , fetchIntakeRequest
  , fetchIntakeWaitlist
  , insertSubmittedIntakeRequest
  , persistTriagedIntakeRequest
  , persistRejectedIntakeRequest
  , persistReassignedIntakeRequest
  , persistClosedIntakeRequestIfAppointed
  , MatchPersistOutcome (..)
  , claimAcceptedIntakeRequest
  , persistMatchedIntakeRequest
  ) where

import Control.Exception                  (Exception, handle, throwIO, try)
import Data.Pool                          (Pool)
import Data.Text                          (Text)
import Data.Time                          (UTCTime)
import Data.UUID                          (UUID)
import Database.PostgreSQL.Simple         (Connection, Only (..), SqlError (..), execute, query,
                                            query_, withTransaction)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)

import Domain
  ( AppointedIntakeRequest (..)
  , AppointmentParty (..)
  , AvailableSlot (..)
  , CloseReason (..)
  , Doctor (..)
  , DoctorId (..)
  , DoctorRequirement (..)
  , Duration (..)
  , EmergencyDue (..)
  , HealthcareService (..)
  , HealthcareServiceId (..)
  , IntakeRequest (..)
  , IntakeRequestId (..)
  , IntakeRequestPriority (..)
  , Patient (..)
  , PatientId (..)
  , RoutineDue (RoutineAnytime, RoutineNotAfter, RoutineNotBefore)
  , SlotId (..)
  , SubmittedIntakeRequest (..)
  , TriagedIntakeRequest (..)
  , UrgentDue (..)
  , WithdrawnIntakeRequest (..)
  , mkRoutineWithin
  , routineWithinBounds
  )

-- ═══════════════════════════════════════════════════════════════════════
-- CONNECTION POOLING
-- Every function in this module takes a plain Connection, never
-- ConnectionPool, with no exceptions. ConnectionPool exists only for
-- whatever calls into this module from outside (Service.hs, not yet
-- written) to check out a Connection via withResource — including holding
-- one connection across a whole withTransaction block spanning multiple
-- calls into this module.
-- ═══════════════════════════════════════════════════════════════════════

type ConnectionPool = Pool Connection

-- ═══════════════════════════════════════════════════════════════════════
-- DECODE ERRORS
-- fail-loudly-on-decode: every toDomainX below returns Either DecodeError,
-- never clamps or coerces silently. InvalidPriorityShape/
-- InvalidTriagedRowShape/InvalidAppointedRowShape are all defensive, not
-- expected to ever fire — the corresponding CHECK constraints should
-- already make them impossible; checked anyway as the last line of
-- defense.
-- ═══════════════════════════════════════════════════════════════════════

data DecodeError
  = InvalidDuration Int
  | InvalidTier Text
  | InvalidState Text
  | InvalidCloseReason Text
  | InvalidWithin UTCTime UTCTime
  | InvalidPriorityShape Text
  | InvalidTriagedRowShape Text
  | InvalidAppointedRowShape Text
    -- ^ a row claiming state = 'appointed' but missing one of
    -- appointed_doctor_id/start_time/duration_minutes — distinct from
    -- InvalidTriagedRowShape, which is a different malformed-row shape.
  deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTORS / PATIENTS
-- minimal-types-minimal-tables: id/name only. No sum type, no invariant
-- beyond field types already enforced — no decode failure is possible, so
-- these have no Either in their toDomainX direction.
-- ═══════════════════════════════════════════════════════════════════════

data DoctorRow = DoctorRow
  { id   :: UUID
  , name :: Text
  }

instance FromRow DoctorRow where
  fromRow =
    DoctorRow
      <$> field  -- id
      <*> field  -- name

toDomainDoctor :: DoctorRow -> Doctor
toDomainDoctor row = Doctor { id = DoctorId row.id, name = row.name }

fromDomainDoctor :: Doctor -> DoctorRow
fromDomainDoctor d =
  let DoctorId did = d.id
  in DoctorRow { id = did, name = d.name }

fetchDoctor :: Connection -> DoctorId -> IO (Maybe Doctor)
fetchDoctor conn (DoctorId did) = do
  rows <- query conn "SELECT id, name FROM doctors WHERE id = ?" (Only did)
  pure $ case rows of
    []        -> Nothing
    (row : _) -> Just (toDomainDoctor row)

insertDoctor :: Connection -> Doctor -> IO ()
insertDoctor conn d = do
  let row = fromDomainDoctor d
  _ <- execute conn "INSERT INTO doctors (id, name) VALUES (?, ?)" (row.id, row.name)
  pure ()

data PatientRow = PatientRow
  { id   :: UUID
  , name :: Text
  }

instance FromRow PatientRow where
  fromRow =
    PatientRow
      <$> field  -- id
      <*> field  -- name

toDomainPatient :: PatientRow -> Patient
toDomainPatient row = Patient { id = PatientId row.id, name = row.name }

fromDomainPatient :: Patient -> PatientRow
fromDomainPatient p =
  let PatientId pid = p.id
  in PatientRow { id = pid, name = p.name }

fetchPatient :: Connection -> PatientId -> IO (Maybe Patient)
fetchPatient conn (PatientId pid) = do
  rows <- query conn "SELECT id, name FROM patients WHERE id = ?" (Only pid)
  pure $ case rows of
    []        -> Nothing
    (row : _) -> Just (toDomainPatient row)

insertPatient :: Connection -> Patient -> IO ()
insertPatient conn p = do
  let row = fromDomainPatient p
  _ <- execute conn "INSERT INTO patients (id, name) VALUES (?, ?)" (row.id, row.name)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICE
-- Duration stored as minutes; decodeDuration/encodeDuration shared by
-- every table with a duration_minutes column (also slots, intake_requests).
-- ═══════════════════════════════════════════════════════════════════════

data HealthcareServiceRow = HealthcareServiceRow
  { id              :: UUID
  , name            :: Text
  , durationMinutes :: Int
  }

instance FromRow HealthcareServiceRow where
  fromRow =
    HealthcareServiceRow
      <$> field  -- id
      <*> field  -- name
      <*> field  -- duration_minutes

decodeDuration :: Int -> Either DecodeError Duration
decodeDuration 15 = Right QuarterOfAnHour
decodeDuration 30 = Right HalfAnHour
decodeDuration 60 = Right OneHour
decodeDuration n  = Left (InvalidDuration n)

encodeDuration :: Duration -> Int
encodeDuration QuarterOfAnHour = 15
encodeDuration HalfAnHour      = 30
encodeDuration OneHour         = 60

toDomainHealthcareService :: HealthcareServiceRow -> Either DecodeError HealthcareService
toDomainHealthcareService row =
  (\d -> HealthcareService { id = HealthcareServiceId row.id, name = row.name, duration = d })
    <$> decodeDuration row.durationMinutes

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceRow
fromDomainHealthcareService s =
  let HealthcareServiceId hsid = s.id
  in HealthcareServiceRow { id = hsid, name = s.name, durationMinutes = encodeDuration s.duration }

fetchHealthcareService :: Connection -> HealthcareServiceId -> IO (Either DecodeError (Maybe HealthcareService))
fetchHealthcareService conn (HealthcareServiceId hsid) = do
  rows <- query conn
    "SELECT id, name, duration_minutes FROM healthcare_services WHERE id = ?"
    (Only hsid)
  pure $ case rows of
    []        -> Right Nothing
    (row : _) -> Just <$> toDomainHealthcareService row

insertHealthcareService :: Connection -> HealthcareService -> IO ()
insertHealthcareService conn s = do
  let row = fromDomainHealthcareService s
  _ <- execute conn
    "INSERT INTO healthcare_services (id, name, duration_minutes) VALUES (?, ?, ?)"
    (row.id, row.name, row.durationMinutes)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════
-- SLOT
-- deleted-on-match: AvailableSlot is the only slot type, open, no
-- invariant to protect. A slots row's unusual property is its lifetime,
-- not its shape — see deleteSlot's note below and atomic-multi-table-write
-- in the Intake Request section.
-- ═══════════════════════════════════════════════════════════════════════

data SlotRow = SlotRow
  { id                  :: UUID
  , doctorId            :: UUID
  , healthcareServiceId :: UUID
  , startTime           :: UTCTime
  , durationMinutes     :: Int
  }

instance FromRow SlotRow where
  fromRow =
    SlotRow
      <$> field  -- id
      <*> field  -- doctor_id
      <*> field  -- healthcare_service_id
      <*> field  -- start_time
      <*> field  -- duration_minutes

toDomainSlot :: SlotRow -> Either DecodeError AvailableSlot
toDomainSlot row =
  (\d -> AvailableSlot
    { id                  = SlotId row.id
    , doctorId            = DoctorId row.doctorId
    , healthcareServiceId = HealthcareServiceId row.healthcareServiceId
    , start               = row.startTime
    , duration            = d
    })
  <$> decodeDuration row.durationMinutes

fromDomainSlot :: AvailableSlot -> SlotRow
fromDomainSlot s =
  let SlotId sid              = s.id
      DoctorId did             = s.doctorId
      HealthcareServiceId hsid = s.healthcareServiceId
  in SlotRow
       { id = sid, doctorId = did, healthcareServiceId = hsid
       , startTime = s.start, durationMinutes = encodeDuration s.duration
       }

fetchSlot :: Connection -> SlotId -> IO (Either DecodeError (Maybe AvailableSlot))
fetchSlot conn (SlotId sid) = do
  rows <- query conn
    "SELECT id, doctor_id, healthcare_service_id, start_time, duration_minutes \
    \FROM slots WHERE id = ?"
    (Only sid)
  pure $ case rows of
    []        -> Right Nothing
    (row : _) -> Just <$> toDomainSlot row

-- doctor_calendar's EXCLUDE constraint (migrations/0001_init.sql) has no
-- affected-rows equivalent — there's no WHERE clause that expresses "does
-- this range overlap any existing one" — so this is the one deliberate,
-- contained exception to this module's no-caught-SqlError convention
-- (uniqueness-races-are-outcomes). See docs/decisions.md's overlap-
-- prevention entry.
data SlotOverlap = SlotOverlap
  deriving (Show, Eq)
-- One constructor, not SlotConflict/AppointedConflict — doctor_calendar's
-- EXCLUDE constraint doesn't distinguish which source (slot vs.
-- appointment) it collided with at violation time in any way the caller
-- can act on differently; both mean the same thing operationally ("this
-- time is unavailable").

insertAvailableSlot :: Connection -> AvailableSlot -> IO (Either SlotOverlap ())
insertAvailableSlot conn slot = do
  let row = fromDomainSlot slot
  result <- try $ execute conn
    "INSERT INTO slots (id, doctor_id, healthcare_service_id, start_time, duration_minutes) \
    \VALUES (?, ?, ?, ?, ?)"
    (row.id, row.doctorId, row.healthcareServiceId, row.startTime, row.durationMinutes)
  case result of
    Right _                        -> pure (Right ())
    Left e | sqlState e == "23P01" -> pure (Left SlotOverlap)
           | otherwise             -> throwIO (e :: SqlError)

-- Reports whether the slot row actually existed to delete. Zero rows
-- affected means a concurrent operation already claimed this slot first —
-- a storage-layer fact (row absent at delete time), not a decode problem,
-- so it's its own result type rather than folded into DecodeError.
data ClaimOutcome = Claimed | AlreadyClaimed
  deriving (Show, Eq)

-- Not paired with an insert — this row simply stops existing once matched.
-- Called only from inside the atomic-multi-table-write transactional
-- functions below, never on its own; a standalone deleteSlot with no
-- corresponding write on the intake_requests side would violate
-- atomic-multi-table-write. Now used as the slot-side guard for matching
-- against intake_requests (folded from the old separate appointments
-- table) rather than a standalone appointments table.
deleteSlot :: Connection -> SlotId -> IO ClaimOutcome
deleteSlot conn (SlotId sid) = do
  n <- execute conn "DELETE FROM slots WHERE id = ?" (Only sid)
  pure (if n > 0 then Claimed else AlreadyClaimed)

-- ═══════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST
-- discriminator-column-tables, extended to six states (submitted/
-- rejected/accepted/appointed/withdrawn/closed), one table, one identity
-- (IntakeRequestId) — mirrors Domain.hs's IntakeRequest sum type exactly,
-- now that Appointment no longer exists as a separate aggregate.
--
-- Two nullability-as-discriminator bijections carried over unchanged
-- (doctor requirement, routine due window), plus a third:
-- healthcare_service_id NULL/NOT NULL also discriminates
-- WithdrawnFromSubmitted vs. WithdrawnFromAccepted within
-- state = 'withdrawn' (see migrations/0001_init.sql).
--
-- No FK to slots (deleted-on-match) — appointed_doctor_id/start_time/
-- duration_minutes are hard-copied directly at matching time, mirroring
-- exactly what AppointedIntakeRequest itself hard-copies.
-- ═══════════════════════════════════════════════════════════════════════

data IntakeRequestRow = IntakeRequestRow
  { id                  :: UUID
  , patientId           :: UUID
  , narrative           :: Text
  , requiredDoctorId    :: Maybe UUID
  , createdAt           :: UTCTime
  , state               :: Text
  , rejectedAt          :: Maybe UTCTime
  , rejectionReason     :: Maybe Text
  , healthcareServiceId :: Maybe UUID
  , tier                :: Maybe Text
  , dueNotBefore        :: Maybe UTCTime
  , dueNotAfter         :: Maybe UTCTime
  , triagedAt           :: Maybe UTCTime
  , appointedDoctorId   :: Maybe UUID
  , startTime           :: Maybe UTCTime
  , durationMinutes     :: Maybe Int
  , withdrawnAt         :: Maybe UTCTime
  , withdrawalNote      :: Maybe Text
  , closeReason         :: Maybe Text
  , closedByParty       :: Maybe Text
  , cancelledAt         :: Maybe UTCTime
  , cancellationNote    :: Maybe Text
  }

-- Field order matches the table's column list in
-- migrations/0001_init.sql.
instance FromRow IntakeRequestRow where
  fromRow =
    IntakeRequestRow
      <$> field <*> field <*> field <*> field <*> field
      -- id, patient_id, narrative, required_doctor_id, created_at
      <*> field
      -- state
      <*> field <*> field
      -- rejected_at, rejection_reason
      <*> field <*> field <*> field <*> field <*> field
      -- healthcare_service_id, tier, due_not_before, due_not_after, triaged_at
      <*> field <*> field <*> field
      -- appointed_doctor_id, start_time, duration_minutes
      <*> field <*> field
      -- withdrawn_at, withdrawal_note
      <*> field <*> field <*> field <*> field
      -- close_reason, closed_by_party, cancelled_at, cancellation_note

decodeDoctorRequirement :: Maybe UUID -> DoctorRequirement
decodeDoctorRequirement Nothing  = AnyDoctor
decodeDoctorRequirement (Just u) = SpecificDoctor (DoctorId u)

encodeDoctorRequirement :: DoctorRequirement -> Maybe UUID
encodeDoctorRequirement AnyDoctor              = Nothing
encodeDoctorRequirement (SpecificDoctor docId) = let DoctorId u = docId in Just u

decodeRoutineDue :: Maybe UTCTime -> Maybe UTCTime -> Either DecodeError RoutineDue
decodeRoutineDue Nothing   Nothing   = Right RoutineAnytime
decodeRoutineDue (Just lo) Nothing   = Right (RoutineNotBefore lo)
decodeRoutineDue Nothing   (Just hi) = Right (RoutineNotAfter hi)
decodeRoutineDue (Just lo) (Just hi) =
  maybe (Left (InvalidWithin lo hi)) Right (mkRoutineWithin lo hi)

-- Emergency/Urgent should be structurally impossible to violate given the
-- CHECK constraint — checked anyway, per fail-loudly-on-decode.
decodePriority :: Text -> Maybe UTCTime -> Maybe UTCTime -> Either DecodeError IntakeRequestPriority
decodePriority "emergency" Nothing  (Just hi) = Right (Emergency (EmergencyDue hi))
decodePriority "urgent"    Nothing  (Just hi) = Right (Urgent (UrgentDue hi))
decodePriority "routine"   lo       hi        = Routine <$> decodeRoutineDue lo hi
decodePriority t           (Just _) _
  | t == "emergency" || t == "urgent" = Left (InvalidPriorityShape t)
decodePriority t           _        Nothing
  | t == "emergency" || t == "urgent" = Left (InvalidPriorityShape t)
decodePriority t           _        _         = Left (InvalidTier t)

-- routineWithinBounds is the read-only accessor for RoutineWithin's hidden
-- fields — RoutineWithin's constructor is not exported (mkRoutineWithin's
-- from <= to invariant), so this is the only way to encode one.
encodePriority :: IntakeRequestPriority -> (Text, Maybe UTCTime, Maybe UTCTime)
encodePriority (Emergency (EmergencyDue hi)) = ("emergency", Nothing, Just hi)
encodePriority (Urgent (UrgentDue hi))       = ("urgent", Nothing, Just hi)
encodePriority (Routine due)                 = ("routine", lo, hi)
  where
    (lo, hi) = case routineWithinBounds due of
      Just (from, to) -> (Just from, Just to)
      Nothing         -> case due of
        RoutineAnytime         -> (Nothing, Nothing)
        RoutineNotBefore from  -> (Just from, Nothing)
        RoutineNotAfter  to    -> (Nothing, Just to)
        _                      -> (Nothing, Nothing)  -- unreachable: routineWithinBounds covers RoutineWithin

decodeParty :: Text -> Either DecodeError AppointmentParty
decodeParty "doctor"  = Right ByDoctor
decodeParty "patient" = Right ByPatient
decodeParty other     = Left (InvalidCloseReason other)

encodeParty :: AppointmentParty -> Text
encodeParty ByDoctor  = "doctor"
encodeParty ByPatient = "patient"

-- Cancelled carries a UTCTime (when the cancellation occurred) — not
-- validated against the appointment's own start_time, per Domain.hs's own
-- comment: a booking manager's judgment call, recorded as given. The
-- trailing Maybe Text is cancellation_note — always independently
-- optional regardless of close_reason, mirroring the domain-level
-- Cancelled AppointmentParty UTCTime (Maybe Text). Returns Nothing only
-- for the not-yet-closed case (close_reason itself NULL); a closed row
-- missing its close_reason is caught by the caller, not here.
decodeCloseReason
  :: Maybe Text -> Maybe Text -> Maybe UTCTime -> Maybe Text
  -> Either DecodeError (Maybe CloseReason)
decodeCloseReason Nothing            _        _         _    = Right Nothing
decodeCloseReason (Just "completed") _        _         _    = Right (Just Completed)
decodeCloseReason (Just "cancelled") (Just p) (Just at) note  =
  (\party -> Just (Cancelled party at note)) <$> decodeParty p
decodeCloseReason (Just "no_show")   (Just p) _         _    = Just . NoShow <$> decodeParty p
decodeCloseReason (Just reason)      _        _         _    = Left (InvalidCloseReason reason)

encodeCloseReason :: CloseReason -> (Text, Maybe Text, Maybe UTCTime, Maybe Text)
encodeCloseReason Completed                 = ("completed", Nothing, Nothing, Nothing)
encodeCloseReason (Cancelled party at note) = ("cancelled", Just (encodeParty party), Just at, note)
encodeCloseReason (NoShow party)            = ("no_show", Just (encodeParty party), Nothing, Nothing)

decodeSubmitted :: IntakeRequestRow -> SubmittedIntakeRequest
decodeSubmitted row = SubmittedIntakeRequest
  { id = IntakeRequestId row.id, patientId = PatientId row.patientId
  , narrative = row.narrative, doctorRequirement = decodeDoctorRequirement row.requiredDoctorId
  , createdAt = row.createdAt
  }

decodeTriaged :: IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
decodeTriaged row = case (row.healthcareServiceId, row.tier, row.triagedAt) of
  (Just svcId, Just tier', Just triagedAt') ->
    (\p -> TriagedIntakeRequest
      { submitted = decodeSubmitted row, healthcareServiceId = HealthcareServiceId svcId
      , priority = p, triagedAt = triagedAt'
      })
    <$> decodePriority tier' row.dueNotBefore row.dueNotAfter
  _ -> Left (InvalidTriagedRowShape row.state)

decodeAppointed :: IntakeRequestRow -> Either DecodeError AppointedIntakeRequest
decodeAppointed row = do
  triaged <- decodeTriaged row
  case (row.appointedDoctorId, row.startTime, row.durationMinutes) of
    (Just did, Just st, Just dm) ->
      (\dur -> AppointedIntakeRequest { triaged, doctorId = DoctorId did, start = st, duration = dur })
      <$> decodeDuration dm
    _ -> Left (InvalidAppointedRowShape row.state)

-- Branches on state — a fetch doesn't know in advance which constructor a
-- row holds, so the case split belongs here, not pushed onto every caller.
toDomainIntakeRequest :: IntakeRequestRow -> Either DecodeError IntakeRequest
toDomainIntakeRequest row = case row.state of
  "submitted" -> Right (Submitted (decodeSubmitted row))
  "rejected"  -> case (row.rejectedAt, row.rejectionReason) of
    (Just at, Just reason) -> Right (Rejected (decodeSubmitted row) at reason)
    _ -> Left (InvalidState "rejected row missing rejected_at/rejection_reason")
  "accepted"  -> Accepted <$> decodeTriaged row
  "appointed" -> Appointed <$> decodeAppointed row
  "withdrawn" -> case row.withdrawnAt of
    Nothing -> Left (InvalidState "withdrawn row missing withdrawn_at")
    Just at -> case row.healthcareServiceId of
      Nothing -> Right (Withdrawn (WithdrawnFromSubmitted (decodeSubmitted row) at row.withdrawalNote))
      Just _  -> (\t -> Withdrawn (WithdrawnFromAccepted t at row.withdrawalNote)) <$> decodeTriaged row
  "closed" -> do
    appointed <- decodeAppointed row
    mReason   <- decodeCloseReason row.closeReason row.closedByParty row.cancelledAt row.cancellationNote
    maybe (Left (InvalidState "closed row has NULL close_reason")) (Right . Closed appointed) mReason
  other -> Left (InvalidState other)

-- Split by constructor — the writing caller already knows which one it
-- holds (unlike the read direction above). Each later stage is built on
-- top of the previous stage's row via record update, mirroring how
-- Domain.hs's own types embed the previous stage whole.
fromDomainSubmitted :: SubmittedIntakeRequest -> IntakeRequestRow
fromDomainSubmitted s =
  let IntakeRequestId rid = s.id
      PatientId pid        = s.patientId
  in IntakeRequestRow
       { id = rid, patientId = pid, narrative = s.narrative
       , requiredDoctorId = encodeDoctorRequirement s.doctorRequirement, createdAt = s.createdAt
       , state = "submitted"
       , rejectedAt = Nothing, rejectionReason = Nothing
       , healthcareServiceId = Nothing, tier = Nothing, dueNotBefore = Nothing, dueNotAfter = Nothing, triagedAt = Nothing
       , appointedDoctorId = Nothing, startTime = Nothing, durationMinutes = Nothing
       , withdrawnAt = Nothing, withdrawalNote = Nothing
       , closeReason = Nothing, closedByParty = Nothing, cancelledAt = Nothing, cancellationNote = Nothing
       }

fromDomainRejected :: SubmittedIntakeRequest -> UTCTime -> Text -> IntakeRequestRow
fromDomainRejected s at reason =
  (fromDomainSubmitted s) { state = "rejected", rejectedAt = Just at, rejectionReason = Just reason }

fromDomainTriaged :: TriagedIntakeRequest -> IntakeRequestRow
fromDomainTriaged t =
  let HealthcareServiceId svcId = t.healthcareServiceId
      (tierText, lo, hi)         = encodePriority t.priority
  in (fromDomainSubmitted t.submitted)
       { state = "accepted", healthcareServiceId = Just svcId, tier = Just tierText
       , dueNotBefore = lo, dueNotAfter = hi, triagedAt = Just t.triagedAt
       }

fromDomainAppointed :: AppointedIntakeRequest -> IntakeRequestRow
fromDomainAppointed a =
  let DoctorId did = a.doctorId
  in (fromDomainTriaged a.triaged)
       { state = "appointed", appointedDoctorId = Just did
       , startTime = Just a.start, durationMinutes = Just (encodeDuration a.duration)
       }

fromDomainWithdrawn :: WithdrawnIntakeRequest -> IntakeRequestRow
fromDomainWithdrawn (WithdrawnFromSubmitted s at note) =
  (fromDomainSubmitted s) { state = "withdrawn", withdrawnAt = Just at, withdrawalNote = note }
fromDomainWithdrawn (WithdrawnFromAccepted t at note) =
  (fromDomainTriaged t)   { state = "withdrawn", withdrawnAt = Just at, withdrawalNote = note }

fromDomainClosed :: AppointedIntakeRequest -> CloseReason -> IntakeRequestRow
fromDomainClosed appointed reason =
  let (reasonText, party, cAt, note) = encodeCloseReason reason
  in (fromDomainAppointed appointed)
       { state = "closed", closeReason = Just reasonText, closedByParty = party
       , cancelledAt = cAt, cancellationNote = note
       }

fetchIntakeRequest :: Connection -> IntakeRequestId -> IO (Either DecodeError (Maybe IntakeRequest))
fetchIntakeRequest conn (IntakeRequestId rid) = do
  rows <- query conn
    "SELECT id, patient_id, narrative, required_doctor_id, created_at, state, \
    \       rejected_at, rejection_reason, \
    \       healthcare_service_id, tier, due_not_before, due_not_after, triaged_at, \
    \       appointed_doctor_id, start_time, duration_minutes, \
    \       withdrawn_at, withdrawal_note, \
    \       close_reason, closed_by_party, cancelled_at, cancellation_note \
    \FROM intake_requests WHERE id = ?"
    (Only rid)
  pure $ case rows of
    []        -> Right Nothing
    (row : _) -> Just <$> toDomainIntakeRequest row

-- no-delete-on-consumption's state filter: with Appointment folded into
-- IntakeRequest, "the waitlist" is just state = 'accepted' — no join
-- against a separate appointments table needed anymore (the old
-- fetchWaitlist's LEFT JOIN anti-join no longer applies).
fetchIntakeWaitlist :: Connection -> IO (Either DecodeError [TriagedIntakeRequest])
fetchIntakeWaitlist conn = do
  rows <- query_ conn
    "SELECT id, patient_id, narrative, required_doctor_id, created_at, state, \
    \       rejected_at, rejection_reason, \
    \       healthcare_service_id, tier, due_not_before, due_not_after, triaged_at, \
    \       appointed_doctor_id, start_time, duration_minutes, \
    \       withdrawn_at, withdrawal_note, \
    \       close_reason, closed_by_party, cancelled_at, cancellation_note \
    \FROM intake_requests WHERE state = 'accepted'"
  pure $ traverse decodeTriaged rows

insertSubmittedIntakeRequest :: Connection -> SubmittedIntakeRequest -> IO ()
insertSubmittedIntakeRequest conn s = do
  let row = fromDomainSubmitted s
  _ <- execute conn
    "INSERT INTO intake_requests \
    \(id, patient_id, narrative, required_doctor_id, created_at, state, \
    \ rejected_at, rejection_reason, \
    \ healthcare_service_id, tier, due_not_before, due_not_after, triaged_at, \
    \ appointed_doctor_id, start_time, duration_minutes, \
    \ withdrawn_at, withdrawal_note, \
    \ close_reason, closed_by_party, cancelled_at, cancellation_note) \
    \VALUES (?, ?, ?, ?, ?, 'submitted', \
    \        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, \
    \        NULL, NULL, NULL, NULL, NULL, NULL)"
    (row.id, row.patientId, row.narrative, row.requiredDoctorId, row.createdAt)
  pure ()

persistTriagedIntakeRequest :: Connection -> TriagedIntakeRequest -> IO ()
persistTriagedIntakeRequest conn t = do
  let row = fromDomainTriaged t
  _ <- execute conn
    "UPDATE intake_requests \
    \SET state = 'accepted', healthcare_service_id = ?, tier = ?, \
    \    due_not_before = ?, due_not_after = ?, triaged_at = ? \
    \WHERE id = ?"
    (row.healthcareServiceId, row.tier, row.dueNotBefore, row.dueNotAfter, row.triagedAt, row.id)
  pure ()

persistRejectedIntakeRequest :: Connection -> SubmittedIntakeRequest -> UTCTime -> Text -> IO ()
persistRejectedIntakeRequest conn submitted rejectedAt reason = do
  let row = fromDomainRejected submitted rejectedAt reason
  _ <- execute conn
    "UPDATE intake_requests \
    \SET state = 'rejected', rejected_at = ?, rejection_reason = ? \
    \WHERE id = ?"
    (row.rejectedAt, row.rejectionReason, row.id)
  pure ()

-- Conditioned on state = 'appointed', unlike an earlier version of this
-- write that had no state guard at all — a concurrent close racing
-- against a reassignment could otherwise silently overwrite doctor/time/
-- duration on an already-closed row. Guarded the same way
-- persistClosedIntakeRequestIfAppointed guards itself below.
-- Wrapped in try/catch for 23P01 the same way claimAcceptedIntakeRequest
-- is above: this UPDATE can now also lose to doctor_calendar's EXCLUDE
-- constraint (the proposed new interval overlaps another commitment for
-- this doctor), on top of the pre-existing state = 'appointed' guard.
-- Both fold to AlreadyClaimed, which Service.reassignAppointedIntakeRequestSlot
-- already reports as NewSlotAlreadyClaimed — "try a different slot" is
-- accurate advice for either cause here, unlike the matching path below.
persistReassignedIntakeRequest :: Connection -> AppointedIntakeRequest -> IO ClaimOutcome
persistReassignedIntakeRequest conn appointed = do
  let row = fromDomainAppointed appointed
  result <- try $ execute conn
    "UPDATE intake_requests SET appointed_doctor_id = ?, start_time = ?, duration_minutes = ? \
    \WHERE id = ? AND state = 'appointed'"
    (row.appointedDoctorId, row.startTime, row.durationMinutes, row.id)
  case result of
    Right n                        -> pure (if n > 0 then Claimed else AlreadyClaimed)
    Left e | sqlState e == "23P01" -> pure AlreadyClaimed
           | otherwise             -> throwIO (e :: SqlError)

-- Conditioned on state = 'appointed': the initial fetch in Service.hs
-- catches the common case (already closed by the time this is called),
-- but between that fetch and this write, a concurrent second close on the
-- same request could pass the same check and silently overwrite which
-- reason it closed for — an undetectable data-corruption outcome, not a
-- visible duplicate like the slot-creation race. AlreadyClaimed here means
-- the request was no longer 'appointed' by the time this write ran.
persistClosedIntakeRequestIfAppointed :: Connection -> AppointedIntakeRequest -> CloseReason -> IO ClaimOutcome
persistClosedIntakeRequestIfAppointed conn appointed reason = do
  let row = fromDomainClosed appointed reason
  n <- execute conn
    "UPDATE intake_requests SET state = 'closed', close_reason = ?, closed_by_party = ?, \
    \       cancelled_at = ?, cancellation_note = ? \
    \WHERE id = ? AND state = 'appointed'"
    (row.closeReason, row.closedByParty, row.cancelledAt, row.cancellationNote, row.id)
  pure (if n > 0 then Claimed else AlreadyClaimed)

-- ═══════════════════════════════════════════════════════════════════════
-- atomic-multi-table-write: matching is an atomic delete-and-update — the
-- slots row must be deleted and the intake_requests row must move from
-- 'accepted' to 'appointed' in the same transaction, or a crash between
-- the two steps leaves either a phantom available slot for an
-- already-matched request, or an appointed request whose slot was never
-- actually claimed. Transaction boundary owned internally — the caller
-- passes a Connection and gets one atomic operation.
-- ═══════════════════════════════════════════════════════════════════════

-- Guards two concurrent operations both trying to move the SAME
-- intake_requests row from 'accepted' to 'appointed' (e.g. two different
-- slots' waitlist scans both picking up the same triaged request). This
-- is a DIFFERENT race from deleteSlot's — deleteSlot guards two
-- operations targeting the same SLOT; this guards two operations
-- targeting the same REQUEST. Both can independently fail, which is why
-- persistMatchedIntakeRequest below still needs compound rollback even
-- though matching no longer inserts into a second table — state itself
-- is the version discriminator for this transition, no separate
-- row_version column needed (nothing in this model changes state
-- without it being a real lifecycle transition worth naming).
-- Wrapped in try/catch for 23P01 alongside the pre-existing affected-rows
-- check: this UPDATE can now lose two independently-caused ways once
-- doctor_calendar exists — the WHERE state = 'accepted' guard matching
-- zero rows (another match already claimed this request), or the guard
-- matching a row but doctor_calendar's EXCLUDE constraint then rejecting
-- the new interval (this doctor already has an overlapping commitment,
-- e.g. a concurrent reassignment). Both fold to AlreadyClaimed — see
-- persistMatchedIntakeRequest below for why that fold is deliberately not
-- unpicked one level up, and the tradeoff that decision accepts.
claimAcceptedIntakeRequest :: Connection -> IntakeRequestId -> AppointedIntakeRequest -> IO ClaimOutcome
claimAcceptedIntakeRequest conn (IntakeRequestId rid) appointed = do
  let row = fromDomainAppointed appointed
  result <- try $ execute conn
    "UPDATE intake_requests \
    \SET state = 'appointed', appointed_doctor_id = ?, start_time = ?, duration_minutes = ? \
    \WHERE id = ? AND state = 'accepted'"
    (row.appointedDoctorId, row.startTime, row.durationMinutes, rid)
  case result of
    Right n                        -> pure (if n > 0 then Claimed else AlreadyClaimed)
    Left e | sqlState e == "23P01" -> pure AlreadyClaimed
           | otherwise             -> throwIO (e :: SqlError)

-- Combines persistMatchedIntakeRequest's two independent race checks
-- (slot side, request side) into which one, if either, lost. Named
-- distinctly from ClaimOutcome's Claimed/AlreadyClaimed (which each
-- individual check still uses) so Service.hs can translate this into its
-- own business-outcome vocabulary without a constructor-name collision
-- between the two modules.
--
-- No separate constructor for a doctor_calendar EXCLUDE violation on the
-- request-side write, deliberately: claimAcceptedIntakeRequest above
-- already folds that case into the same AlreadyClaimed its state-guard
-- failure produces, so by the time the result reaches here there is no
-- surviving information to build a distinct case from — doing so would
-- require ClaimOutcome to grow a third constructor that every other
-- ClaimOutcome consumer (persistReassignedIntakeRequest,
-- persistClosedIntakeRequestIfAppointed) would then have to pattern-match
-- on too, for a distinction none of them act on differently. The
-- accepted tradeoff: RequestAlreadyMatched's caller-facing meaning
-- ("this request is already scheduled, drop it") is a slight
-- overstatement when the true cause was an interval conflict rather than
-- a duplicate claim — the request itself is actually still 'accepted'
-- and could in principle be retried against a different slot — but this
-- is judged close enough (both mean "this attempt didn't go through")
-- against the cost of threading a new outcome through every unrelated
-- call site.
data MatchPersistOutcome
  = MatchPersisted
  | SlotAlreadyGone
  | RequestAlreadyMatched
  deriving (Show, Eq)

-- Internal-only signal used to unwind out of withTransaction's action when
-- the request-side race is lost after the slot-side one is already won —
-- never exported, never escapes persistMatchedIntakeRequest. withTransaction
-- rolls back on ANY exception that escapes its action, not just the ones a
-- caller explicitly coded for; throwing here and catching just outside it
-- keeps that blanket exception-safety, unlike manual begin/commit/rollback,
-- which only rolls back on the specific paths coded for and would silently
-- leak an open transaction if some other, unanticipated exception fired
-- first — exactly the class of risk atomic-multi-table-write exists to
-- prevent.
data MatchAbort = SlotGone | RequestGone
  deriving Show

instance Exception MatchAbort

-- Mirrors matchIntakeRequestToSlot: caller already ran the pure domain
-- function and holds the resulting AppointedIntakeRequest plus the SlotId
-- of whichever AvailableSlot got consumed to produce it.
--
-- Two independent races to guard, not one: the slot side (two concurrent
-- matches/reassignments targeting the same SlotId) and the request side
-- (two concurrent matches targeting the same intake_requests row — e.g.
-- two different slots' waitlist scans both picking up the same triaged
-- request before either commits). Both are detected by affected-rows
-- checks (deleteSlot, claimAcceptedIntakeRequest), never a caught
-- SqlError.
--
-- If the slot delete succeeds but the request claim then loses its race,
-- the slot delete must be rolled back too — that slot was never actually
-- consumed by a real match, so it must not stay deleted without a
-- committed appointment to show for it (the same phantom-slot-loss
-- atomic-multi-table-write exists to prevent). Throwing MatchAbort inside
-- withTransaction's action triggers exactly that rollback; handle just
-- outside translates it back into the corresponding MatchPersistOutcome.
persistMatchedIntakeRequest :: Connection -> SlotId -> AppointedIntakeRequest -> IO MatchPersistOutcome
persistMatchedIntakeRequest conn matchedSlotId appointed =
  handle recoverAbort $ withTransaction conn $ do
    slotOutcome <- deleteSlot conn matchedSlotId
    case slotOutcome of
      AlreadyClaimed -> throwIO SlotGone
      Claimed -> do
        let reqId = appointed.triaged.submitted.id
        reqOutcome <- claimAcceptedIntakeRequest conn reqId appointed
        case reqOutcome of
          AlreadyClaimed -> throwIO RequestGone
          Claimed        -> pure MatchPersisted
  where
    recoverAbort :: MatchAbort -> IO MatchPersistOutcome
    recoverAbort SlotGone    = pure SlotAlreadyGone
    recoverAbort RequestGone = pure RequestAlreadyMatched

-- ID generation (newDoctorId, newIntakeRequestId, etc.) has moved to
-- Service.hs — an orchestration decision (when a new ID is minted), not a
-- fetch or a store. See Service.hs.
