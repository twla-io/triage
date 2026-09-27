# Worked Examples: Row / toDomainX / fromDomainX

Representative cases, not exhaustive coverage of every aggregate. Like `migrations/0001_init.sql`, this is illustrative reference material; the actual `Persistence.hs` should be generated fresh from `Domain.hs`, not copied from this file verbatim. It has gone stale before: a prior version assumed `Slot`/`BookedSlot` existed as a sum type, and until 2026-09-27 Cases 3 and 4 still showed the `HealthcareRequest`/`Appointment` tables from two designs ago. Those cases were then rewritten from the current `Persistence.hs`; if they disagree with `Domain.hs` again, trust `Domain.hs`.

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
  | InvalidAppointedRowShape Text
  | OverlappingCalendarEntries DoctorId
  deriving (Show, Eq)
```

`InvalidPriorityShape`/`InvalidTriagedRowShape`/`InvalidAppointedRowShape` are defensive, not expected to ever fire — see `fail-loudly-on-decode`'s note on checking things that should already be impossible per a `CHECK` constraint.

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

-- doctor_calendar's EXCLUDE constraint rejects an overlapping slot with
-- SQL state 23P01; that one error is caught and returned as an outcome
-- (cross-table-invariants-need-a-shadow-table). Any other SqlError is
-- rethrown.
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

-- Not paired with an insert — the row simply stops existing once matched.
-- Called only inside persistMatchedIntakeRequest's transaction (Case 4),
-- never on its own. Zero rows affected means a concurrent match took the
-- slot first (uniqueness-races-are-outcomes).
deleteSlot :: Connection -> SlotId -> IO ClaimOutcome
deleteSlot conn (SlotId sid) = do
  n <- execute conn "DELETE FROM slots WHERE id = ?" (Only sid)
  pure (if n > 0 then Claimed else AlreadyClaimed)
```

## Case 3 — `IntakeRequest`: one table, a `state` discriminator, nullability bijections, and a versioned fetch

`IntakeRequest`'s seven cases (`Submitted | Rejected | Accepted | Appointed | Withdrawn | Stale | Closed`) live in one `intake_requests` table (`discriminator-column-tables`), one row per `IntakeRequestId` for its whole life (`no-delete-on-consumption`). The row type has one field per column — every stage's columns, nullable where a stage doesn't use them (see `migrations/0001_init.sql` for the per-state `CHECK`s):

```haskell
data IntakeRequestRow = IntakeRequestRow
  { id :: UUID, patientId :: UUID, narrative :: Text
  , requiredDoctorId :: Maybe UUID, createdAt :: UTCTime, state :: Text
  , rejectedAt :: Maybe UTCTime, rejectionReason :: Maybe Text
  , healthcareServiceId :: Maybe UUID, tier :: Maybe Text
  , dueNotBefore :: Maybe UTCTime, dueNotAfter :: Maybe UTCTime, triagedAt :: Maybe UTCTime
  , appointedDoctorId :: Maybe UUID, startTime :: Maybe UTCTime, durationMinutes :: Maybe Int
  , withdrawnAt :: Maybe UTCTime, withdrawalNote :: Maybe Text
  , staleAt :: Maybe UTCTime
  , closeReason :: Maybe Text, closedByParty :: Maybe Text
  , cancelledAt :: Maybe UTCTime, cancellationNote :: Maybe Text
  }
```

Three nullability bijections (`nullability-as-discriminator`), each with no redundant discriminator column:

```haskell
-- required_doctor_id: NULL = AnyDoctor
decodeDoctorRequirement :: Maybe UUID -> DoctorRequirement
decodeDoctorRequirement Nothing  = AnyDoctor
decodeDoctorRequirement (Just u) = SpecificDoctor (DoctorId u)

-- due_not_before / due_not_after: the four RoutineDue cases. RoutineWithin
-- goes through its smart constructor, so a stored from > to fails loudly.
decodeRoutineDue :: Maybe UTCTime -> Maybe UTCTime -> Either DecodeError RoutineDue
decodeRoutineDue Nothing   Nothing   = Right RoutineAnytime
decodeRoutineDue (Just lo) Nothing   = Right (RoutineNotBefore lo)
decodeRoutineDue Nothing   (Just hi) = Right (RoutineNotAfter hi)
decodeRoutineDue (Just lo) (Just hi) =
  maybe (Left (InvalidWithin lo hi)) Right (mkRoutineWithin lo hi)

-- Third bijection: within state = 'withdrawn', healthcare_service_id NULL
-- means WithdrawnFromSubmitted, NOT NULL means WithdrawnFromAccepted (see
-- toDomainIntakeRequest below).
```

Each stage decodes on top of the one before it, mirroring how `Domain.hs`'s types embed the previous stage whole:

```haskell
decodeSubmitted :: IntakeRequestRow -> SubmittedIntakeRequest            -- total
decodeTriaged   :: IntakeRequestRow -> Either DecodeError TriagedIntakeRequest
decodeAppointed :: IntakeRequestRow -> Either DecodeError AppointedIntakeRequest

decodeAppointed row = do
  triaged <- decodeTriaged row
  case (row.appointedDoctorId, row.startTime, row.durationMinutes) of
    (Just did, Just st, Just dm) ->
      (\dur -> AppointedIntakeRequest { triaged, doctorId = DoctorId did, start = st, duration = dur })
      <$> decodeDuration dm
    _ -> Left (InvalidAppointedRowShape row.state)
```

The read direction branches on `state`, because a fetch doesn't know in advance which case a row holds. The write direction is split by constructor instead (`fromDomainSubmitted`, `fromDomainTriaged`, `fromDomainAppointed`, …), because the writing caller already knows which one it has:

```haskell
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
  "stale" -> case row.staleAt of
    Nothing -> Left (InvalidState "stale row missing stale_at")
    Just at -> (`Stale` at) <$> decodeTriaged row
  "closed" -> do
    appointed <- decodeAppointed row
    mReason   <- decodeCloseReason row.closeReason row.closedByParty row.cancelledAt row.cancellationNote
    maybe (Left (InvalidState "closed row has NULL close_reason")) (Right . Closed appointed) mReason
  other -> Left (InvalidState other)
```

**The fetch a decision is made from is versioned** (`row-version-for-freshness`). The version isn't part of the row type or of `Domain.hs`; it's selected first and composed with postgresql-simple's `:.`:

```haskell
fetchIntakeRequest :: Connection -> IntakeRequestId -> IO (Either DecodeError (Maybe (Versioned IntakeRequest)))
fetchIntakeRequest conn (IntakeRequestId rid) = do
  rows <- query conn
    "SELECT version, id, patient_id, ..., cancellation_note \
    \FROM intake_requests WHERE id = ?"
    (Only rid)
  pure $ case rows of
    []                  -> Right Nothing
    ((Only v :. row) : _) -> Just . Versioned (RowVersion v) <$> toDomainIntakeRequest row
```

**Every transition write is guarded twice**: on the source case `Domain.hs` defines (`updates-follow-domain-transitions`, legality) and on the version the caller read (`row-version-for-freshness`, freshness). Zero rows affected is a lost race, reported as an outcome (`uniqueness-races-are-outcomes`). Accepted → Stale is the plain template; every other transition has the same shape:

```haskell
persistStaleIntakeRequest :: Connection -> RowVersion -> IntakeRequestId -> UTCTime -> IO ClaimOutcome
persistStaleIntakeRequest conn (RowVersion v) (IntakeRequestId rid) staleAt = do
  n <- execute conn
    "UPDATE intake_requests SET state = 'stale', stale_at = ? \
    \WHERE id = ? AND state = 'accepted' AND version = ?"
    (staleAt, rid, v)
  pure (if n > 0 then Claimed else AlreadyClaimed)
```

## Case 4 — Matching: one transaction over two tables, two independent races

Matching deletes the `slots` row and moves the `intake_requests` row from `'accepted'` to `'appointed'`, copying the slot's doctor/start/duration into it (`deleted-on-match`: no FK back to the slot, which no longer exists). Both writes must commit together or not at all (`atomic-multi-table-write`), and each can independently lose a race: another match took the slot, or the request changed since it was read.

The request-side write is guarded like every other transition (source case plus version). It also catches `doctor_calendar`'s `EXCLUDE` violation (23P01) and folds it into the same `AlreadyClaimed`; since the appointment copies the deleted slot's own interval, freed in the same transaction, that case should be unreachable.

```haskell
claimAcceptedIntakeRequest :: Connection -> RowVersion -> IntakeRequestId -> AppointedIntakeRequest -> IO ClaimOutcome
claimAcceptedIntakeRequest conn (RowVersion v) (IntakeRequestId rid) appointed = do
  let row = fromDomainAppointed appointed
  result <- try $ execute conn
    "UPDATE intake_requests \
    \SET state = 'appointed', appointed_doctor_id = ?, start_time = ?, duration_minutes = ? \
    \WHERE id = ? AND state = 'accepted' AND version = ?"
    (row.appointedDoctorId, row.startTime, row.durationMinutes, rid, v)
  case result of
    Right n                        -> pure (if n > 0 then Claimed else AlreadyClaimed)
    Left e | sqlState e == "23P01" -> pure AlreadyClaimed
           | otherwise             -> throwIO (e :: SqlError)
```

If the slot delete wins but the request claim loses, the delete must be rolled back too, or the slot disappears with no appointment to show for it. `withTransaction` rolls back on any exception, so an internal, unexported exception unwinds out of it, and is caught just outside and turned back into an outcome. It never escapes the function:

```haskell
data MatchPersistOutcome = MatchPersisted | SlotAlreadyGone | RequestAlreadyMatched

data MatchAbort = SlotGone | RequestGone   -- not exported
instance Exception MatchAbort

persistMatchedIntakeRequest :: Connection -> SlotId -> RowVersion -> AppointedIntakeRequest -> IO MatchPersistOutcome
persistMatchedIntakeRequest conn matchedSlotId requestVersion appointed =
  handle recoverAbort $ withTransaction conn $ do
    slotOutcome <- deleteSlot conn matchedSlotId
    case slotOutcome of
      AlreadyClaimed -> throwIO SlotGone
      Claimed -> do
        let reqId = appointed.triaged.submitted.id
        reqOutcome <- claimAcceptedIntakeRequest conn requestVersion reqId appointed
        case reqOutcome of
          AlreadyClaimed -> throwIO RequestGone
          Claimed        -> pure MatchPersisted
  where
    recoverAbort SlotGone    = pure SlotAlreadyGone
    recoverAbort RequestGone = pure RequestAlreadyMatched
```

The caller (`Service.hs`) passes the stored slot's id and the `AppointedIntakeRequest` that `Domain.matchIntakeRequestToSlot` built from that stored slot, never a slot supplied by a client (`stored-facts-by-reference` in `triage-service-codegen`).
