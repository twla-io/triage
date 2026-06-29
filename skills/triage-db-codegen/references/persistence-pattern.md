# Worked Examples: Row / toDomain / fromDomain

Three representative cases, not exhaustive coverage of every aggregate — apply the same pattern to whatever isn't shown here. Like `schema.sql`, this is illustrative reference material; the actual `Persistence.hs` should be generated fresh from `Domain.hs`, not copied from this file verbatim.

One error type, shared across every `toDomain` in this file — collecting every failure mode actually used below, per Rule 4:

```haskell
data DecodeError
  = InvalidDuration Int
  | InvalidPriority Int
  | InvalidState Text
  | InvalidWindow UTCTime UTCTime
  deriving (Show, Eq)
```

## Case 1 — A simple type: `Service`

No sum type, no sealed constructor, nothing to reconstruct carefully. The baseline case everything else compares against.

```haskell
data ServiceRow = ServiceRow
  { rowId              :: UUID
  , rowName            :: Text
  , rowDurationMinutes :: Int
  }

decodeDuration :: Int -> Either DecodeError Duration
decodeDuration 60 = Right OneHour
decodeDuration 30 = Right HalfAnHour
decodeDuration n  = Left (InvalidDuration n)

encodeDuration :: Duration -> Int
encodeDuration OneHour    = 60
encodeDuration HalfAnHour = 30

toDomain :: ServiceRow -> Either DecodeError Service
toDomain row = do
  d <- decodeDuration row.rowDurationMinutes
  Right Service { id = ServiceId row.rowId, name = row.rowName, duration = d }

fromDomain :: Service -> ServiceRow
fromDomain s =
  let ServiceId u = s.id
  in ServiceRow { rowId = u, rowName = s.name, rowDurationMinutes = encodeDuration s.duration }
```

`fromDomain` is total — nothing about going from an already-valid `Service` to its row shape can fail. `toDomain` can fail exactly where `decodeDuration` can, per Rule 4.

## Case 2 — A sum type needing Rule 8 reconstruction: `Slot`

`PendingSlot` and `AvailableSlot` are no longer sealed and carry no extra state — reconstructing either is now trivial, not a Rule 8 case at all:

```haskell
toDomainPending :: SlotDetails -> PendingSlot
toDomainPending = PendingSlot  -- constructor is open; no replay needed

toDomainAvailable :: SlotDetails -> AvailableSlot
toDomainAvailable = AvailableSlot  -- same — open, no invariant to protect
```

`BookedSlot` is still sealed, and its only producers (`bookAppointment`, `assignAppointment`) each also construct a full `Appointment` — which the `slots` row alone doesn't carry. This is a genuine Rule 8 case:

```haskell
data SlotRow = SlotRow
  { rowId               :: UUID
  , rowDoctorId         :: UUID
  , rowServiceId        :: UUID
  , rowStartTime        :: UTCTime
  , rowDurationMinutes  :: Int
  , rowState            :: Text
  , rowAppointmentId    :: Maybe UUID
  }

-- bookAppointment's BookedSlot half never reads patientId — only the
-- (fabricated, discarded) Appointment half does. Verified against the
-- current bookAppointment body before relying on this.
rebuildBookedSlot :: SlotDetails -> AppointmentId -> BookedSlot
rebuildBookedSlot details aid =
  fst (bookAppointment (releaseSlot (PendingSlot details)) aid (PatientId nil))

-- Shared with Service's example above — the same Int -> Duration decode,
-- not duplicated per-aggregate.
decodeSlotDetails :: SlotRow -> Either DecodeError SlotDetails
decodeSlotDetails row = do
  d <- decodeDuration row.rowDurationMinutes
  Right SlotDetails
    { id        = SlotId row.rowId
    , doctorId  = DoctorId row.rowDoctorId
    , serviceId = ServiceId row.rowServiceId
    , start     = row.rowStartTime
    , duration  = d
    }

toDomain :: SlotRow -> Either DecodeError Slot
toDomain row = do
  d <- decodeSlotDetails row
  case (row.rowState, row.rowAppointmentId) of
    ("pending",   _)        -> Right (Pending (toDomainPending d))
    ("available", _)        -> Right (Available (toDomainAvailable d))
    ("booked",    Just aid) -> Right (Booked (rebuildBookedSlot d (AppointmentId aid)))
    (other,       _)        -> Left (InvalidState other)
    -- "booked" with no appointment_id can't happen if the CHECK constraint
    -- holds, but this is total rather than partial: a row that somehow
    -- violates it surfaces as a decode failure, not a crash.
```

## Case 3 — Delete-on-consumption: `AppointmentRequest`

Per Rule 9, `appointment_requests` has no terminal state — a row is deleted the moment `assignAppointment` consumes it, in the same transaction as the `slots`/`appointments` writes. The store-side function reflects this directly: there is no "mark as fulfilled" path, only "insert while waiting" and "delete on consumption."

```haskell
data AppointmentRequestRow = AppointmentRequestRow
  { rowId            :: UUID
  , rowPatientId     :: UUID
  , rowServiceId     :: UUID
  , rowCreatedAt      :: UTCTime
  , rowPriority       :: Int  -- 0/1/2, see Rule 2
  , rowDoctorId       :: Maybe UUID
  , rowDueNotBefore   :: Maybe UTCTime
  , rowDueNotAfter    :: Maybe UTCTime
  }

decodeDueAt :: Maybe UTCTime -> Maybe UTCTime -> Either DecodeError DueAt
decodeDueAt Nothing   Nothing   = Right Anytime
decodeDueAt (Just lo) Nothing   = Right (NotBefore lo)
decodeDueAt Nothing   (Just hi) = Right (NotAfter hi)
decodeDueAt (Just lo) (Just hi) =
  maybe (Left (InvalidWindow lo hi)) Right (mkWithin lo hi)  -- goes through mkWithin, per Rule 4

toDomain :: AppointmentRequestRow -> Either DecodeError AppointmentRequest
toDomain row = case row.rowPriority of
  0 -> Right (EmergencyRequest details)
  1 -> Right (UrgentRequest details)
  2 -> do
    dueAt <- decodeDueAt row.rowDueNotBefore row.rowDueNotAfter
    Right (RoutineRequest details (DoctorId <$> row.rowDoctorId) dueAt)
  n -> Left (InvalidPriority n)
  where
    details = AppointmentRequestDetails
      { id = AppointmentRequestId row.rowId, patientId = PatientId row.rowPatientId
      , serviceId = ServiceId row.rowServiceId, createdAt = row.rowCreatedAt
      }

-- No fromDomain for the consumed case: assignAppointment's caller deletes
-- the row by id rather than encoding the consumed AppointmentRequest back
-- into a row that would just need deleting anyway.
```

`OpenAppointment`'s reconstruction is the same Rule 8 shape as `BookedSlot`, through `assignAppointment` instead of `bookAppointment` — simpler than it would have been before the offer mechanism was removed, since `assignAppointment` is total (no `Maybe` to satisfy):

```haskell
rebuildOpenAppointment :: AppointmentId -> PatientId -> AppointmentPriority -> SlotId -> OpenAppointment
rebuildOpenAppointment aid realPid realPrio realSlotId =
  case assignAppointment placeholderSlot placeholderRequest aid of
    (_, Open oa) -> oa
  where
    placeholderRequest = case realPrio of
      Emergency -> EmergencyRequest details
      Urgent    -> UrgentRequest    details
      Routine   -> RoutineRequest   details Nothing Anytime
      where details = AppointmentRequestDetails
              { id = AppointmentRequestId nil, patientId = realPid
              , serviceId = ServiceId nil, createdAt = posixSecondsToUTCTime 0 }
    placeholderSlot = PendingSlot SlotDetails
      { id = realSlotId, doctorId = DoctorId nil, serviceId = ServiceId nil
      , start = posixSecondsToUTCTime 0, duration = OneHour }
```

`ClosedAppointment` needs no placeholder at all — `closeAppointment :: OpenAppointment -> CloseReason -> ClosedAppointment` takes real data throughout; reconstructing one is just calling it with the real `OpenAppointment` (itself reconstructed via the function above) and the real `CloseReason` decoded from the row.
