# Worked Examples: Row / toDomainX / fromDomainX

Representative cases, not exhaustive coverage of every aggregate. Like `migrations/0001_init.sql`, this is illustrative reference material; the actual `Persistence.hs` should be generated fresh from `Domain.hs`, not copied from this file verbatim — it has already gone stale once (a prior version of this file assumed `Slot`/`BookedSlot` existed as a sum type; they don't anymore).

One error type, shared across every `toDomainX` in this file:

```haskell
data DecodeError
  = InvalidDuration Int
  | InvalidTier Text
  | InvalidState Text
  | InvalidCloseReason Text
  | InvalidWithin UTCTime UTCTime
  | InvalidPriorityShape Text
  | InvalidTriagedRowShape Text
  deriving (Show, Eq)
```

`InvalidPriorityShape`/`InvalidTriagedRowShape` are both defensive, not expected to ever fire — see `fail-loudly-on-decode`'s note on checking things that should already be impossible per a `CHECK` constraint.

## Case 1 — A simple type: `HealthcareService`

No sum type, nothing sealed. The baseline everything else compares against.

```haskell
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
  let HealthcareServiceId u = s.id
  in HealthcareServiceRow { id = u, name = s.name, durationMinutes = encodeDuration s.duration }
```

`<$>` is used rather than `do`-notation: exactly one fallible sub-computation (`decodeDuration`) feeding pure construction.

## Case 2 — `AvailableSlot`: also simple now, but ephemeral (`deleted-on-match`)

Before the `Slot` redesign, this case needed `sealed-type-replay` to reconstruct a sealed `BookedSlot`. That entire problem is gone: `AvailableSlot` is the only slot type, open, no invariant to protect. The interesting part of this case isn't decoding — it's that a `slots` row's *lifetime* is what's unusual, not its shape.

```haskell
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
  let SlotId sid                   = s.id
      DoctorId did                  = s.doctorId
      HealthcareServiceId hsid      = s.healthcareServiceId
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

-- Not paired with an insert — this row simply stops existing once
-- matched. Called only from inside the atomic-multi-table-write
-- transactional functions in Case 4, never on its own; a standalone
-- deleteSlot with no corresponding appointments write would violate
-- atomic-multi-table-write.
deleteSlot :: Connection -> SlotId -> IO ()
deleteSlot conn (SlotId sid) = do
  _ <- execute conn "DELETE FROM slots WHERE id = ?" (Only sid)
  pure ()
```

## Case 3 — `HealthcareRequest`: two-stage discriminator plus nullability bijections

Unaffected by the `Slot` redesign — shown here unchanged, since `Appointment` (Case 4) depends on fetching a `TriagedHealthcareRequest` via join.

```haskell
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
      <$> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field

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

-- NOTE: an earlier version of this file pattern-matched `RoutineWithin lo
-- hi` directly here. That does not compile — RoutineWithin's constructor
-- is not exported (see sealed-value-decomposition), so it cannot be
-- pattern-matched from outside Domain.hs. routineWithinBounds is the
-- correct, read-only accessor for this — check it first (Just case);
-- only fall through to the other three constructors if it's Nothing.
encodePriority :: HealthcareRequestPriority -> (Text, Maybe UTCTime, Maybe UTCTime)
encodePriority (Emergency (EmergencyDue hi)) = ("emergency", Nothing, Just hi)
encodePriority (Urgent (UrgentDue hi))       = ("urgent", Nothing, Just hi)
encodePriority (Routine due)                 = ("routine", lo, hi)
  where
    (lo, hi) = case routineWithinBounds due of
      Just (from, to) -> (Just from, Just to)
      Nothing         -> case due of
        RoutineAnytime        -> (Nothing, Nothing)
        RoutineNotBefore from -> (Just from, Nothing)
        RoutineNotAfter  to   -> (Nothing, Just to)
        _                     -> (Nothing, Nothing)  -- unreachable: routineWithinBounds covers RoutineWithin

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

-- no-delete-on-consumption's anti-join.
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
```

## Case 4 — `Appointment`: hard-copied slot facts, no FK, and the atomic match/reassign transactions

This is where the `Slot` redesign changes the most. `appointments` now carries `doctor_id`/`start_time`/`duration_minutes` directly — no `slot_id`, no join back to `slots` at all, since a matched slot's row no longer exists (`deleted-on-match`).

```haskell
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
      <*> field <*> field <*> field <*> field

decodeParty :: Text -> Either DecodeError AppointmentParty
decodeParty "doctor"  = Right ByDoctor
decodeParty "patient" = Right ByPatient
decodeParty other     = Left (InvalidCloseReason other)

encodeParty :: AppointmentParty -> Text
encodeParty ByDoctor  = "doctor"
encodeParty ByPatient = "patient"

-- Cancelled now carries a UTCTime (when the cancellation occurred) — not
-- validated against the appointment's own date, per Domain.hs's own
-- comment: a booking manager's judgment call, recorded as given.
decodeCloseReason :: Maybe Text -> Maybe Text -> Maybe UTCTime -> Either DecodeError (Maybe CloseReason)
decodeCloseReason Nothing            _        _         = Right Nothing
decodeCloseReason (Just "completed") _        _         = Right (Just Completed)
decodeCloseReason (Just "cancelled") (Just p) (Just at) = (\party -> Just (Cancelled party at)) <$> decodeParty p
decodeCloseReason (Just "no_show")   (Just p) _         = (\party -> Just (NoShow party)) <$> decodeParty p
decodeCloseReason (Just reason)      _        _         = Left (InvalidCloseReason reason)

encodeCloseReason :: CloseReason -> (Text, Maybe Text, Maybe UTCTime)
encodeCloseReason Completed            = ("completed", Nothing, Nothing)
encodeCloseReason (Cancelled party at) = ("cancelled", Just (encodeParty party), Just at)
encodeCloseReason (NoShow party)       = ("no_show", Just (encodeParty party), Nothing)

-- NOTE: an earlier version of this file defaulted a NULL close_reason on
-- a 'closed' row to `Completed` silently. That's a fail-loudly-on-decode
-- violation — a closed row with no reason is exactly the kind of
-- CHECK-constraint-should-prevent-this-but-verify-anyway case that rule
-- exists for. Fixed below to surface it as a decode failure instead.
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
        Nothing     -> Left (InvalidState "closed appointment row has NULL close_reason")
    other -> Left (InvalidState other)

-- fromDomainOpen/fromDomainClosed: split by constructor, writing caller
-- already knows which one it holds (same reasoning as
-- fromDomainSubmitted/fromDomainTriaged in Case 3).
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
  let baseRow                    = fromDomainOpen openAppt
      (reasonText, party, cAt)   = encodeCloseReason reason
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
      toDomainAppointment row req

-- ═══════════════════════════════════════════════════════════════════════
-- atomic-multi-table-write: the two operations that must insert/update
-- appointments AND delete slots together, in one transaction.
-- Transaction boundary owned internally — the caller passes a Connection
-- and gets one atomic operation, per SKILL.md's Persistence module
-- conventions.
-- ═══════════════════════════════════════════════════════════════════════

-- Mirrors satisfyHealthcareRequest: caller already ran the pure domain
-- function and holds the resulting OpenAppointment plus the SlotId of
-- whichever AvailableSlot got consumed to produce it.
persistMatchedAppointment :: Connection -> SlotId -> OpenAppointment -> IO ()
persistMatchedAppointment conn (SlotId sid) openAppt =
  withTransaction conn $ do
    let row = fromDomainOpen openAppt
    _ <- execute conn
      "INSERT INTO appointments \
      \(id, healthcare_request_id, doctor_id, start_time, duration_minutes, state, close_reason, closed_by_party, cancelled_at) \
      \VALUES (?, ?, ?, ?, ?, 'open', NULL, NULL, NULL)"
      (row.id, row.healthcareRequestId, row.doctorId, row.startTime, row.durationMinutes)
    _ <- execute conn "DELETE FROM slots WHERE id = ?" (Only sid)
    pure ()

-- Mirrors reassignSlot: same treatment as an initial match — the new
-- slot is deleted, the existing appointment's doctor/time/duration
-- columns are updated in place (same row, same id, no new appointments
-- row). Recreating the OLD vacated time is explicitly NOT this
-- function's job — see deleted-on-match.
persistReassignedAppointment :: Connection -> SlotId -> OpenAppointment -> IO ()
persistReassignedAppointment conn (SlotId newSlotId) openAppt =
  withTransaction conn $ do
    let row = fromDomainOpen openAppt
    _ <- execute conn
      "UPDATE appointments SET doctor_id = ?, start_time = ?, duration_minutes = ? WHERE id = ?"
      (row.doctorId, row.startTime, row.durationMinutes, row.id)
    _ <- execute conn "DELETE FROM slots WHERE id = ?" (Only newSlotId)
    pure ()

-- Closing has no slot to delete — nothing to make atomic with anything
-- else, single-table write.
persistClosedAppointment :: Connection -> ClosedAppointment -> IO ()
persistClosedAppointment conn closed = do
  let row = fromDomainClosed closed
  _ <- execute conn
    "UPDATE appointments SET state = 'closed', close_reason = ?, closed_by_party = ?, cancelled_at = ? WHERE id = ?"
    (row.closeReason, row.closedByParty, row.cancelledAt, row.id)
  pure ()
```

Note on `toDomainAppointment` above: `OpenAppointment`'s constructor takes `Duration` as its last argument, so decoding it requires binding (`do`) rather than `<$>`, since the result of `decodeDuration` has to be threaded into a partially-applied constructor rather than mapped over directly — a genuine multiple-fallible-step case, per the `<$>`-vs-`do` convention in `SKILL.md`.