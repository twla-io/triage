{-# LANGUAGE DuplicateRecordFields #-}
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

    -- ── Healthcare Request ───────────────────────────────────────────────
  , HealthcareRequestRow (..)
  , toDomainHealthcareRequest
  , fromDomainSubmitted
  , fromDomainTriaged
  , fetchHealthcareRequest
  , insertSubmittedRequest
  , persistTriagedRequest
  , fetchWaitlist

    -- ── Appointment ──────────────────────────────────────────────────────
  , AppointmentRow (..)
  , toDomainAppointment
  , fromDomainOpen
  , fromDomainClosed
  , fetchAppointment
  , persistMatchedAppointment
  , persistReassignedAppointment
  , persistClosedAppointment

    -- ── ID generation (provisional home — conceptually belongs in
    --    Service.hs, an orchestration decision, but Service.hs doesn't
    --    exist yet; see SKILL.md's note on this) ───────────────────────────
  , newDoctorId
  , newPatientId
  , newHealthcareServiceId
  , newHealthcareRequestId
  , newSlotId
  , newAppointmentId
  ) where

import Data.Pool                          (Pool)
import Data.Text                          (Text)
import Data.Time                          (UTCTime)
import Data.UUID                          (UUID)
import Data.UUID.V4                       (nextRandom)
import Database.PostgreSQL.Simple         (Connection, Only (..), execute, query, query_,
                                            withTransaction)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)

import Domain
  ( Appointment (..)
  , AppointmentId (..)
  , AppointmentParty (..)
  , AvailableSlot (..)
  , CloseReason (..)
  , ClosedAppointment (..)
  , Doctor (..)
  , DoctorId (..)
  , DoctorRequirement (..)
  , Duration (..)
  , EmergencyDue (..)
  , HealthcareRequest (..)
  , HealthcareRequestDetails (..)
  , HealthcareRequestId (..)
  , HealthcareRequestPriority (..)
  , HealthcareService (..)
  , HealthcareServiceId (..)
  , OpenAppointment (..)
  , Patient (..)
  , PatientId (..)
  , RoutineDue (RoutineAnytime, RoutineNotAfter, RoutineNotBefore)
  , SlotId (..)
  , TriagedHealthcareRequest (..)
  , UrgentDue (..)
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
-- InvalidTriagedRowShape are both defensive, not expected to ever fire —
-- the corresponding CHECK constraints should already make them impossible;
-- checked anyway as the last line of defense.
-- ═══════════════════════════════════════════════════════════════════════

data DecodeError
  = InvalidDuration Int
  | InvalidTier Text
  | InvalidState Text
  | InvalidCloseReason Text
  | InvalidWithin UTCTime UTCTime
  | InvalidPriorityShape Text
  | InvalidTriagedRowShape Text
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
-- every table with a duration_minutes column (also slots, appointments).
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
-- in the Appointment section.
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

insertAvailableSlot :: Connection -> AvailableSlot -> IO ()
insertAvailableSlot conn slot = do
  let row = fromDomainSlot slot
  _ <- execute conn
    "INSERT INTO slots (id, doctor_id, healthcare_service_id, start_time, duration_minutes) \
    \VALUES (?, ?, ?, ?, ?)"
    (row.id, row.doctorId, row.healthcareServiceId, row.startTime, row.durationMinutes)
  pure ()

-- Not paired with an insert — this row simply stops existing once matched.
-- Called only from inside the atomic-multi-table-write transactional
-- functions below, never on its own; a standalone deleteSlot with no
-- corresponding appointments write would violate atomic-multi-table-write.
deleteSlot :: Connection -> SlotId -> IO ()
deleteSlot conn (SlotId sid) = do
  _ <- execute conn "DELETE FROM slots WHERE id = ?" (Only sid)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE REQUEST
-- discriminator-column-tables (submitted/triaged) plus two
-- nullability-as-discriminator bijections (doctor requirement, routine
-- due window).
-- ═══════════════════════════════════════════════════════════════════════

data HealthcareRequestRow = HealthcareRequestRow
  { id                  :: UUID
  , patientId           :: UUID
  , narrative           :: Text
  , requiredDoctorId    :: Maybe UUID
  , createdAt           :: UTCTime
  , state               :: Text
  , healthcareServiceId :: Maybe UUID
  , tier                :: Maybe Text
  , dueNotBefore        :: Maybe UTCTime
  , dueNotAfter         :: Maybe UTCTime
  , triagedAt           :: Maybe UTCTime
  }

instance FromRow HealthcareRequestRow where
  fromRow =
    HealthcareRequestRow
      <$> field <*> field <*> field <*> field <*> field  -- id, patient_id, narrative, required_doctor_id, created_at
      <*> field <*> field <*> field <*> field <*> field <*> field
      -- state, healthcare_service_id, tier, due_not_before, due_not_after, triaged_at

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
decodePriority :: Text -> Maybe UTCTime -> Maybe UTCTime -> Either DecodeError HealthcareRequestPriority
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
encodePriority :: HealthcareRequestPriority -> (Text, Maybe UTCTime, Maybe UTCTime)
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

decodeDetails :: HealthcareRequestRow -> HealthcareRequestDetails
decodeDetails row = HealthcareRequestDetails
  { id = HealthcareRequestId row.id, patientId = PatientId row.patientId
  , narrative = row.narrative, doctorRequirement = decodeDoctorRequirement row.requiredDoctorId
  , createdAt = row.createdAt
  }

-- Branches on state — a fetch doesn't know in advance which constructor a
-- row holds, so the case split belongs here, not pushed onto every caller.
toDomainHealthcareRequest :: HealthcareRequestRow -> Either DecodeError HealthcareRequest
toDomainHealthcareRequest row =
  case row.state of
    "submitted" -> Right (Submitted (decodeDetails row))
    "triaged"   ->
      case (row.healthcareServiceId, row.tier, row.triagedAt) of
        (Just svcId, Just tier', Just triagedAt') ->
          (\p -> Triaged TriagedHealthcareRequest
            { details = decodeDetails row, healthcareServiceId = HealthcareServiceId svcId
            , priority = p, triagedAt = triagedAt'
            })
          <$> decodePriority tier' row.dueNotBefore row.dueNotAfter
        _ -> Left (InvalidTriagedRowShape row.state)
    other -> Left (InvalidState other)

-- Split by constructor — the writing caller already knows which one it
-- holds (unlike the read direction above).
fromDomainSubmitted :: HealthcareRequestDetails -> HealthcareRequestRow
fromDomainSubmitted d =
  let HealthcareRequestId rid = d.id
      PatientId pid            = d.patientId
  in HealthcareRequestRow
       { id = rid, patientId = pid, narrative = d.narrative
       , requiredDoctorId = encodeDoctorRequirement d.doctorRequirement, createdAt = d.createdAt
       , state = "submitted", healthcareServiceId = Nothing, tier = Nothing
       , dueNotBefore = Nothing, dueNotAfter = Nothing, triagedAt = Nothing
       }

fromDomainTriaged :: TriagedHealthcareRequest -> HealthcareRequestRow
fromDomainTriaged t =
  let d                         = t.details
      HealthcareRequestId rid   = d.id
      PatientId pid             = d.patientId
      HealthcareServiceId svcId = t.healthcareServiceId
      (tierText, lo, hi)        = encodePriority t.priority
  in HealthcareRequestRow
       { id = rid, patientId = pid, narrative = d.narrative
       , requiredDoctorId = encodeDoctorRequirement d.doctorRequirement, createdAt = d.createdAt
       , state = "triaged", healthcareServiceId = Just svcId, tier = Just tierText
       , dueNotBefore = lo, dueNotAfter = hi, triagedAt = Just t.triagedAt
       }

fetchHealthcareRequest :: Connection -> HealthcareRequestId -> IO (Either DecodeError (Maybe HealthcareRequest))
fetchHealthcareRequest conn (HealthcareRequestId rid) = do
  rows <- query conn
    "SELECT id, patient_id, narrative, required_doctor_id, created_at, state, \
    \       healthcare_service_id, tier, due_not_before, due_not_after, triaged_at \
    \FROM healthcare_requests WHERE id = ?"
    (Only rid)
  pure $ case rows of
    []        -> Right Nothing
    (row : _) -> Just <$> toDomainHealthcareRequest row

insertSubmittedRequest :: Connection -> HealthcareRequestDetails -> IO ()
insertSubmittedRequest conn d = do
  let row = fromDomainSubmitted d
  _ <- execute conn
    "INSERT INTO healthcare_requests \
    \(id, patient_id, narrative, required_doctor_id, created_at, state, \
    \ healthcare_service_id, tier, due_not_before, due_not_after, triaged_at) \
    \VALUES (?, ?, ?, ?, ?, 'submitted', NULL, NULL, NULL, NULL, NULL)"
    (row.id, row.patientId, row.narrative, row.requiredDoctorId, row.createdAt)
  pure ()

-- Named after triageHealthcareRequest, the Domain.hs verb that produces
-- the value being persisted here — mirrors the caller's own vocabulary.
persistTriagedRequest :: Connection -> TriagedHealthcareRequest -> IO ()
persistTriagedRequest conn t = do
  let row = fromDomainTriaged t
  _ <- execute conn
    "UPDATE healthcare_requests \
    \SET state = 'triaged', healthcare_service_id = ?, tier = ?, \
    \    due_not_before = ?, due_not_after = ?, triaged_at = ? \
    \WHERE id = ?"
    (row.healthcareServiceId, row.tier, row.dueNotBefore, row.dueNotAfter, row.triagedAt, row.id)
  pure ()

-- no-delete-on-consumption's anti-join: a triaged request with no
-- corresponding appointments row.
fetchWaitlist :: Connection -> IO (Either DecodeError [TriagedHealthcareRequest])
fetchWaitlist conn = do
  rows <- query_ conn
    "SELECT hr.id, hr.patient_id, hr.narrative, hr.required_doctor_id, hr.created_at, hr.state, \
    \       hr.healthcare_service_id, hr.tier, hr.due_not_before, hr.due_not_after, hr.triaged_at \
    \FROM healthcare_requests hr \
    \LEFT JOIN appointments a ON a.healthcare_request_id = hr.id \
    \WHERE hr.state = 'triaged' AND a.id IS NULL"
  pure $ traverse toDomainTriagedOnly rows
  where
    toDomainTriagedOnly row = case toDomainHealthcareRequest row of
      Right (Triaged t)   -> Right t
      Right (Submitted _) -> Left (InvalidState "submitted row returned by fetchWaitlist's anti-join")
      Left e              -> Left e

-- ═══════════════════════════════════════════════════════════════════════
-- APPOINTMENT
-- discriminator-column-tables (open/closed). No FK to slots at all
-- (deleted-on-match) — doctor_id/start_time/duration_minutes are
-- hard-copied directly at matching time, mirroring exactly what
-- OpenAppointment itself hard-copies. cancelled_at
-- (nullability-as-discriminator): populated only when close_reason =
-- 'cancelled'.
-- ═══════════════════════════════════════════════════════════════════════

data AppointmentRow = AppointmentRow
  { id                  :: UUID
  , healthcareRequestId :: UUID
  , doctorId            :: UUID
  , startTime           :: UTCTime
  , durationMinutes     :: Int
  , state               :: Text  -- 'open' | 'closed'
  , closeReason         :: Maybe Text
  , closedByParty       :: Maybe Text
  , cancelledAt         :: Maybe UTCTime
  }

instance FromRow AppointmentRow where
  fromRow =
    AppointmentRow
      <$> field <*> field <*> field <*> field <*> field
      -- id, healthcare_request_id, doctor_id, start_time, duration_minutes
      <*> field <*> field <*> field <*> field
      -- state, close_reason, closed_by_party, cancelled_at

decodeParty :: Text -> Either DecodeError AppointmentParty
decodeParty "doctor"  = Right ByDoctor
decodeParty "patient" = Right ByPatient
decodeParty other     = Left (InvalidCloseReason other)

encodeParty :: AppointmentParty -> Text
encodeParty ByDoctor  = "doctor"
encodeParty ByPatient = "patient"

-- Cancelled carries a UTCTime (when the cancellation occurred) — not
-- validated against the appointment's own start_time, per Domain.hs's own
-- comment: a booking manager's judgment call, recorded as given. Returns
-- Nothing only for the open-appointment case (close_reason itself NULL);
-- a closed row missing its close_reason is caught by the caller, not here.
decodeCloseReason :: Maybe Text -> Maybe Text -> Maybe UTCTime -> Either DecodeError (Maybe CloseReason)
decodeCloseReason Nothing            _        _         = Right Nothing
decodeCloseReason (Just "completed") _        _         = Right (Just Completed)
decodeCloseReason (Just "cancelled") (Just p) (Just at) = (\party -> Just (Cancelled party at)) <$> decodeParty p
decodeCloseReason (Just "no_show")   (Just p) _         = (Just . NoShow) <$> decodeParty p
decodeCloseReason (Just reason)      _        _         = Left (InvalidCloseReason reason)

encodeCloseReason :: CloseReason -> (Text, Maybe Text, Maybe UTCTime)
encodeCloseReason Completed            = ("completed", Nothing, Nothing)
encodeCloseReason (Cancelled party at) = ("cancelled", Just (encodeParty party), Just at)
encodeCloseReason (NoShow party)       = ("no_show", Just (encodeParty party), Nothing)

toDomainAppointment :: AppointmentRow -> TriagedHealthcareRequest -> Either DecodeError Appointment
toDomainAppointment row req = do
  duration' <- decodeDuration row.durationMinutes
  let openAppt = OpenAppointment (AppointmentId row.id) req (DoctorId row.doctorId) row.startTime duration'
  case row.state of
    "open" -> Right (Open openAppt)
    "closed" -> do
      mReason <- decodeCloseReason row.closeReason row.closedByParty row.cancelledAt
      case mReason of
        Just reason -> Right (Closed (ClosedAppointment openAppt reason))
        -- Structurally impossible per the CHECK constraint — a closed row
        -- always has close_reason set — caught anyway, fail-loudly-on-decode.
        Nothing     -> Left (InvalidState "closed appointment row has NULL close_reason")
    other -> Left (InvalidState other)

-- fromDomainOpen/fromDomainClosed: split by constructor, writing caller
-- already knows which one it holds (same reasoning as
-- fromDomainSubmitted/fromDomainTriaged above).
fromDomainOpen :: OpenAppointment -> AppointmentRow
fromDomainOpen (OpenAppointment aid req did startTime' duration') =
  let AppointmentId appointmentUuid   = aid
      HealthcareRequestId requestUuid = req.details.id
      DoctorId doctorUuid             = did
  in AppointmentRow
       { id = appointmentUuid, healthcareRequestId = requestUuid
       , doctorId = doctorUuid, startTime = startTime'
       , durationMinutes = encodeDuration duration'
       , state = "open", closeReason = Nothing, closedByParty = Nothing, cancelledAt = Nothing
       }

fromDomainClosed :: ClosedAppointment -> AppointmentRow
fromDomainClosed (ClosedAppointment openAppt reason) =
  -- ClosedAppointment is open (no sealed-type-replay needed) — direct
  -- pattern match, no accessor function required.
  let baseRow                  = fromDomainOpen openAppt
      (reasonText, party, cAt) = encodeCloseReason reason
  in baseRow { state = "closed", closeReason = Just reasonText, closedByParty = party, cancelledAt = cAt }

fetchAppointment :: Connection -> AppointmentId -> IO (Either DecodeError (Maybe Appointment))
fetchAppointment conn (AppointmentId aid) = do
  rows <- query conn
    "SELECT id, healthcare_request_id, doctor_id, start_time, duration_minutes, \
    \       state, close_reason, closed_by_party, cancelled_at \
    \FROM appointments WHERE id = ?"
    (Only aid)
  case rows of
    []        -> pure (Right Nothing)
    (row : _) -> do
      reqResult <- fetchHealthcareRequest conn (HealthcareRequestId row.healthcareRequestId)
      pure (reqResult >>= toDomainAppointmentFromRequest row)
  where
    toDomainAppointmentFromRequest _   Nothing =
      Left (InvalidState "appointments row references missing healthcare_requests row")
    toDomainAppointmentFromRequest _   (Just (Submitted _)) =
      Left (InvalidState "appointments row references a submitted (non-triaged) healthcare_requests row")
    toDomainAppointmentFromRequest row (Just (Triaged req)) =
      Just <$> toDomainAppointment row req

-- ═══════════════════════════════════════════════════════════════════════
-- atomic-multi-table-write: matching is an atomic insert-and-delete — the
-- appointments row must be inserted (or updated) and the slots row
-- deleted in the same transaction, or a crash between the two steps
-- leaves either a phantom available slot for an already-matched request,
-- or a matched appointment whose slot was never actually claimed.
-- Transaction boundary owned internally — the caller passes a Connection
-- and gets one atomic operation.
-- ═══════════════════════════════════════════════════════════════════════

-- Mirrors satisfyHealthcareRequest: caller already ran the pure domain
-- function and holds the resulting OpenAppointment plus the SlotId of
-- whichever AvailableSlot got consumed to produce it.
persistMatchedAppointment :: Connection -> SlotId -> OpenAppointment -> IO ()
persistMatchedAppointment conn matchedSlotId openAppt =
  withTransaction conn $ do
    let row = fromDomainOpen openAppt
    _ <- execute conn
      "INSERT INTO appointments \
      \(id, healthcare_request_id, doctor_id, start_time, duration_minutes, state, close_reason, closed_by_party, cancelled_at) \
      \VALUES (?, ?, ?, ?, ?, 'open', NULL, NULL, NULL)"
      (row.id, row.healthcareRequestId, row.doctorId, row.startTime, row.durationMinutes)
    deleteSlot conn matchedSlotId

-- Mirrors reassignSlot: same treatment as an initial match — the new slot
-- is deleted, the existing appointment's doctor/time/duration columns are
-- updated in place (same row, same id, no new appointments row).
-- Recreating the OLD vacated time is explicitly NOT this function's job —
-- see deleted-on-match.
persistReassignedAppointment :: Connection -> SlotId -> OpenAppointment -> IO ()
persistReassignedAppointment conn newlyMatchedSlotId openAppt =
  withTransaction conn $ do
    let row = fromDomainOpen openAppt
    _ <- execute conn
      "UPDATE appointments SET doctor_id = ?, start_time = ?, duration_minutes = ? WHERE id = ?"
      (row.doctorId, row.startTime, row.durationMinutes, row.id)
    deleteSlot conn newlyMatchedSlotId

-- Closing has no slot to delete — nothing to make atomic with anything
-- else, single-table write.
persistClosedAppointment :: Connection -> ClosedAppointment -> IO ()
persistClosedAppointment conn closed = do
  let row = fromDomainClosed closed
  _ <- execute conn
    "UPDATE appointments SET state = 'closed', close_reason = ?, closed_by_party = ?, cancelled_at = ? WHERE id = ?"
    (row.closeReason, row.closedByParty, row.cancelledAt, row.id)
  pure ()

-- ═══════════════════════════════════════════════════════════════════════
-- ID GENERATION
-- Provisional home per SKILL.md — conceptually an orchestration decision
-- (Service.hs), not a fetch or a store, but Service.hs doesn't exist yet.
-- ═══════════════════════════════════════════════════════════════════════

newDoctorId :: IO DoctorId
newDoctorId = DoctorId <$> nextRandom

newPatientId :: IO PatientId
newPatientId = PatientId <$> nextRandom

newHealthcareServiceId :: IO HealthcareServiceId
newHealthcareServiceId = HealthcareServiceId <$> nextRandom

newHealthcareRequestId :: IO HealthcareRequestId
newHealthcareRequestId = HealthcareRequestId <$> nextRandom

newSlotId :: IO SlotId
newSlotId = SlotId <$> nextRandom

newAppointmentId :: IO AppointmentId
newAppointmentId = AppointmentId <$> nextRandom
