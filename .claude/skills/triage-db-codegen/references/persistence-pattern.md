# Worked Examples: Row / toDomain / fromDomain

Four representative cases, not exhaustive coverage of every aggregate — apply the same pattern to whatever isn't shown here. Like `migrations/0001_init.sql`, this is illustrative reference material; the actual `Persistence.hs` should be generated fresh from `Domain.hs`, not copied from this file verbatim.

One error type, shared across every `toDomain` in this file — collecting every failure mode actually used below, per `fail-loudly-on-decode`:

```haskell
data DecodeError
  = InvalidDuration Int
  | InvalidTier Text
  | InvalidState Text
  | InvalidCloseReason Text
  | InvalidWithin UTCTime UTCTime
  deriving (Show, Eq)
```

## Case 1 — A simple type: `HealthcareService`

No sum type, no sealed constructor, nothing to reconstruct carefully. The baseline case everything else compares against. Duration now has three values, not two — `decodeDuration`/`encodeDuration` cover all three.

```haskell
data HealthcareServiceRow = HealthcareServiceRow
  { rowId              :: UUID
  , rowName            :: Text
  , rowDurationMinutes :: Int
  }

decodeDuration :: Int -> Either DecodeError Duration
decodeDuration 15 = Right QuarterOfAnHour
decodeDuration 30 = Right HalfAnHour
decodeDuration 60 = Right OneHour
decodeDuration n  = Left (InvalidDuration n)

encodeDuration :: Duration -> Int
encodeDuration QuarterOfAnHour = 15
encodeDuration HalfAnHour      = 30
encodeDuration OneHour         = 60

toDomain :: HealthcareServiceRow -> Either DecodeError HealthcareService
toDomain row = do
  d <- decodeDuration row.rowDurationMinutes
  Right HealthcareService
    { id = HealthcareServiceId row.rowId, name = row.rowName, duration = d }

fromDomain :: HealthcareService -> HealthcareServiceRow
fromDomain s =
  let HealthcareServiceId u = s.id
  in HealthcareServiceRow
       { rowId = u, rowName = s.name, rowDurationMinutes = encodeDuration s.duration }
```

`fromDomain` is total. `toDomain` can fail exactly where `decodeDuration` can, per `fail-loudly-on-decode`.

## Case 2 — A sum type needing `sealed-type-replay` reconstruction: `Slot`

`AvailableSlot` is open and carries no extra state — reconstructing it is trivial, no replay needed:

```haskell
toDomainAvailable :: SlotDetails -> AvailableSlot
toDomainAvailable = AvailableSlot  -- constructor is open; nothing to protect
```

`BookedSlot` is still sealed. Its only producers, `satisfyHealthcareRequest` and `reassignSlot`, are both gated by `matches` — reconstruction has to make that gate provably succeed, not just avoid reading unused fields (unlike the old skill's `PatientId nil` case, which worked because the relevant function simply never touched that field):

```haskell
data SlotRow = SlotRow
  { rowId                  :: UUID
  , rowDoctorId            :: UUID
  , rowHealthcareServiceId :: UUID
  , rowStartTime           :: UTCTime
  , rowDurationMinutes     :: Int
  , rowState               :: Text
  , rowAppointmentId       :: Maybe UUID
  }

-- BookedSlot's constructor (BookedSlot slot appointmentId) never reads
-- `request` at all — only `matches` does, to gate whether
-- satisfyHealthcareRequest fires.
-- healthcareServiceId is real (must equal the slot's own, or matches
-- fails). doctorRequirement = AnyDoctor and priority = Routine
-- RoutineAnytime are the unique constructors that make
-- matchesDoctorRequirement/matchesTime unconditionally True, verified
-- against their current bodies — not assumed. id/patientId/narrative/
-- createdAt/triagedAt are sentinel — discarded either way, since only the
-- BookedSlot half of the result is kept.
--
-- fromJust is safe here specifically because matches is proven, not
-- merely expected, to succeed given this placeholder — this is the one
-- place in generated Persistence code where fromJust is acceptable, and
-- only because of that proof.
rebuildBookedSlot :: SlotDetails -> AppointmentId -> BookedSlot
rebuildBookedSlot details aid =
  fst . fromJust $ satisfyHealthcareRequest (AvailableSlot details) aid placeholderRequest
  where
    placeholderRequest = TriagedHealthcareRequest
      { details  = HealthcareRequestDetails
          { id = HealthcareRequestId nil, patientId = PatientId nil
          , narrative = "", doctorRequirement = AnyDoctor
          , createdAt = posixSecondsToUTCTime 0 }
      , healthcareServiceId = details.healthcareServiceId
      , priority  = Routine RoutineAnytime
      , triagedAt = posixSecondsToUTCTime 0
      }

-- Shared with HealthcareService's example above — the same Int -> Duration
-- decode, not duplicated per-aggregate.
decodeSlotDetails :: SlotRow -> Either DecodeError SlotDetails
decodeSlotDetails row = do
  d <- decodeDuration row.rowDurationMinutes
  Right SlotDetails
    { id                  = SlotId row.rowId
    , doctorId            = DoctorId row.rowDoctorId
    , healthcareServiceId = HealthcareServiceId row.rowHealthcareServiceId
    , start                = row.rowStartTime
    , duration             = d
    }

toDomain :: SlotRow -> Either DecodeError Slot
toDomain row = do
  d <- decodeSlotDetails row
  case (row.rowState, row.rowAppointmentId) of
    ("available", _)        -> Right (Available (toDomainAvailable d))
    ("booked",    Just aid) -> Right (Booked (rebuildBookedSlot d (AppointmentId aid)))
    (other,       _)        -> Left (InvalidState other)
    -- "booked" with no appointment_id can't happen if the CHECK constraint
    -- holds, but this is total rather than partial: a row that somehow
    -- violates it surfaces as a decode failure, not a crash.
```

## Case 3 — `HealthcareRequest`: two-stage discriminator plus `nullability-as-discriminator` bijections

Covers the `submitted`/`triaged` discriminator (`discriminator-column-tables`) and the two nullability-as-discriminator cases (`nullability-as-discriminator`): `DoctorRequirement` (on every row) and `RoutineDue` (only within the `routine` tier).

```haskell
data HealthcareRequestRow = HealthcareRequestRow
  { rowId                  :: UUID
  , rowPatientId           :: UUID
  , rowNarrative           :: Text
  , rowRequiredDoctorId    :: Maybe UUID  -- nullability-as-discriminator: NULL = AnyDoctor
  , rowCreatedAt           :: UTCTime
  , rowState               :: Text        -- 'submitted' | 'triaged'
  , rowHealthcareServiceId :: Maybe UUID
  , rowTier                :: Maybe Text  -- 'emergency' | 'urgent' | 'routine'
                                          -- ord-ranking-check does NOT require an int encoding here:
                                          -- verified against Domain.hs's checkWaitlist, whose
                                          -- `sortOn priority` runs in Haskell over already-decoded
                                          -- values, never as a SQL ORDER BY. Nothing compares this
                                          -- column at the database layer, so TEXT is fine.
  , rowDueNotBefore        :: Maybe UTCTime
  , rowDueNotAfter         :: Maybe UTCTime
  , rowTriagedAt           :: Maybe UTCTime
  }

decodeDoctorRequirement :: Maybe UUID -> DoctorRequirement
decodeDoctorRequirement Nothing  = AnyDoctor
decodeDoctorRequirement (Just u) = SpecificDoctor (DoctorId u)

encodeDoctorRequirement :: DoctorRequirement -> Maybe UUID
encodeDoctorRequirement AnyDoctor              = Nothing
encodeDoctorRequirement (SpecificDoctor docId) = let DoctorId u = docId in Just u

-- nullability-as-discriminator's bijection, decode direction. Goes through mkRoutineWithin per
-- fail-loudly-on-decode — the same validation protecting in-memory construction has to
-- protect the read-from-storage path too.
decodeRoutineDue :: Maybe UTCTime -> Maybe UTCTime -> Either DecodeError RoutineDue
decodeRoutineDue Nothing   Nothing   = Right RoutineAnytime
decodeRoutineDue (Just lo) Nothing   = Right (RoutineNotBefore lo)
decodeRoutineDue Nothing   (Just hi) = Right (RoutineNotAfter hi)
decodeRoutineDue (Just lo) (Just hi) =
  maybe (Left (InvalidWithin lo hi)) Right (mkRoutineWithin lo hi)

decodePriority :: Text -> Maybe UTCTime -> Maybe UTCTime -> Either DecodeError HealthcareRequestPriority
decodePriority "emergency" _  (Just hi) = Right (Emergency (EmergencyDue hi))
decodePriority "urgent"    _  (Just hi) = Right (Urgent (UrgentDue hi))
decodePriority "routine"   lo hi        = Routine <$> decodeRoutineDue lo hi
decodePriority t           _  _         = Left (InvalidTier t)

encodePriority :: HealthcareRequestPriority -> (Text, Maybe UTCTime, Maybe UTCTime)
encodePriority (Emergency (EmergencyDue hi))    = ("emergency", Nothing, Just hi)
encodePriority (Urgent (UrgentDue hi))          = ("urgent", Nothing, Just hi)
encodePriority (Routine RoutineAnytime)         = ("routine", Nothing, Nothing)
encodePriority (Routine (RoutineNotBefore lo))  = ("routine", Just lo, Nothing)
encodePriority (Routine (RoutineNotAfter hi))   = ("routine", Nothing, Just hi)
encodePriority (Routine (RoutineWithin lo hi))  = ("routine", Just lo, Just hi)

toDomain :: HealthcareRequestRow -> Either DecodeError HealthcareRequest
toDomain row = do
  let details = HealthcareRequestDetails
        { id                = HealthcareRequestId row.rowId
        , patientId         = PatientId row.rowPatientId
        , narrative         = row.rowNarrative
        , doctorRequirement = decodeDoctorRequirement row.rowRequiredDoctorId
        , createdAt         = row.rowCreatedAt
        }
  case row.rowState of
    "submitted" -> Right (Submitted details)
    "triaged"   ->
      case (row.rowHealthcareServiceId, row.rowTier, row.rowTriagedAt) of
        (Just svcId, Just tier, Just triagedAt) -> do
          priority <- decodePriority tier row.rowDueNotBefore row.rowDueNotAfter
          Right . Triaged $ TriagedHealthcareRequest
            { details             = details
            , healthcareServiceId = HealthcareServiceId svcId
            , priority            = priority
            , triagedAt           = triagedAt
            }
        _ -> Left (InvalidState "triaged row missing required triage columns")
    other -> Left (InvalidState other)

fromDomain :: HealthcareRequest -> HealthcareRequestRow
fromDomain (Submitted d) = HealthcareRequestRow
  { rowId               = let HealthcareRequestId u = d.id in u
  , rowPatientId        = let PatientId u = d.patientId in u
  , rowNarrative        = d.narrative
  , rowRequiredDoctorId = encodeDoctorRequirement d.doctorRequirement
  , rowCreatedAt        = d.createdAt
  , rowState            = "submitted"
  , rowHealthcareServiceId = Nothing
  , rowTier                = Nothing
  , rowDueNotBefore        = Nothing
  , rowDueNotAfter         = Nothing
  , rowTriagedAt           = Nothing
  }
fromDomain (Triaged t) =
  let (tier, lo, hi) = encodePriority t.priority
      HealthcareServiceId svcId = t.healthcareServiceId
      d = t.details
  in HealthcareRequestRow
       { rowId               = let HealthcareRequestId u = d.id in u
       , rowPatientId        = let PatientId u = d.patientId in u
       , rowNarrative        = d.narrative
       , rowRequiredDoctorId = encodeDoctorRequirement d.doctorRequirement
       , rowCreatedAt        = d.createdAt
       , rowState            = "triaged"
       , rowHealthcareServiceId = Just svcId
       , rowTier                = Just tier
       , rowDueNotBefore        = lo
       , rowDueNotAfter         = hi
       , rowTriagedAt           = Just t.triagedAt
       }
```

## Case 4 — No delete-on-consumption, and a plain-join `Appointment`

Per `no-delete-on-consumption`, `healthcare_requests` rows are never deleted or flagged matched — the waitlist is a derived anti-join. Per `sealed-type-replay`, `OpenAppointment` and `ClosedAppointment` need no replay: both reconstruct from real row/join data directly, since neither has a gating predicate to satisfy at reconstruction time (unlike `BookedSlot` in Case 2).

```haskell
data AppointmentRow = AppointmentRow
  { rowId                  :: UUID
  , rowHealthcareRequestId :: UUID
  , rowSlotId              :: UUID
  , rowState               :: Text  -- 'open' | 'closed'
  , rowCloseReason         :: Maybe Text
  , rowClosedByParty       :: Maybe Text
  }

decodeParty :: Text -> Either DecodeError AppointmentParty
decodeParty "doctor"  = Right ByDoctor
decodeParty "patient" = Right ByPatient
decodeParty other     = Left (InvalidCloseReason other)

decodeCloseReason :: Maybe Text -> Maybe Text -> Either DecodeError (Maybe CloseReason)
decodeCloseReason Nothing        _              = Right Nothing
decodeCloseReason (Just "completed") _          = Right (Just Completed)
decodeCloseReason (Just "cancelled") (Just p)   = Just . Cancelled <$> decodeParty p
decodeCloseReason (Just "no_show")   (Just p)   = Just . NoShow    <$> decodeParty p
decodeCloseReason (Just reason)      _          = Left (InvalidCloseReason reason)

-- Takes the already-fetched TriagedHealthcareRequest (via the
-- healthcare_request_id join) rather than re-decoding it here — the
-- caller is responsible for the join, this function just assembles.
toDomain :: AppointmentRow -> TriagedHealthcareRequest -> Either DecodeError Appointment
toDomain row req = do
  let openAppt = OpenAppointment (AppointmentId row.rowId) req (SlotId row.rowSlotId)
  closeReason <- decodeCloseReason row.rowCloseReason row.rowClosedByParty
  case (row.rowState, closeReason) of
    ("open",   Nothing)  -> Right (Open openAppt)
    ("closed", Just cr)  -> Right (Closed (closeAppointment openAppt cr))
    (other,    _)        -> Left (InvalidState other)

fromDomain :: Appointment -> AppointmentRow
fromDomain (Open (OpenAppointment aid req slotId)) = AppointmentRow
  { rowId                  = let AppointmentId u = aid in u
  , rowHealthcareRequestId = let HealthcareRequestId u = req.details.id in u
  , rowSlotId              = let SlotId u = slotId in u
  , rowState               = "open"
  , rowCloseReason         = Nothing
  , rowClosedByParty       = Nothing
  }
fromDomain (Closed closed) =
  -- ClosedAppointment is sealed but has no invariant beyond "wraps an
  -- OpenAppointment and a CloseReason" — Domain.hs would need an accessor
  -- to pull those back out for encoding; assumed to exist as e.g.
  -- `closedAppointmentParts :: ClosedAppointment -> (OpenAppointment, CloseReason)`.
  -- Flag to the user if no such accessor exists yet — that's a Domain.hs
  -- gap, not a Persistence-layer decision to route around.
  let (openAppt@(OpenAppointment aid req slotId), reason) = closedAppointmentParts closed
      (reasonText, partyText) = case reason of
        Completed        -> ("completed", Nothing)
        Cancelled ByDoctor  -> ("cancelled", Just "doctor")
        Cancelled ByPatient -> ("cancelled", Just "patient")
        NoShow ByDoctor     -> ("no_show", Just "doctor")
        NoShow ByPatient    -> ("no_show", Just "patient")
  in AppointmentRow
       { rowId                  = let AppointmentId u = aid in u
       , rowHealthcareRequestId = let HealthcareRequestId u = req.details.id in u
       , rowSlotId              = let SlotId u = slotId in u
       , rowState               = "closed"
       , rowCloseReason         = Just reasonText
       , rowClosedByParty       = partyText
       }

-- no-delete-on-consumption: the waitlist is derived, not stored. This is the anti-join
-- from SKILL.md's Persistence section, decoded through Case 3's toDomain,
-- filtered down to just the Triaged half (safe: the WHERE clause already
-- restricts to state = 'triaged', so Submitted never appears here — a
-- pattern-match failure on that would indicate the SQL and this function
-- have drifted out of sync).
fetchWaitlistRows :: <connection> -> IO [HealthcareRequestRow]
fetchWaitlistRows = {- SELECT ... per SKILL.md's anti-join, left as an
                        open parameter pending the DB library decision -}
```

`closedAppointmentParts` above is flagged, not assumed silently, per the skill's "when unsure, flag rather than invent" closing rule — check `Domain.hs`'s actual export list for `ClosedAppointment` before relying on it; if no such accessor is exported, that's a real gap to raise, not something to route around with a new raw-state export (which would repeat the exact mistake `sealed-type-replay` exists to prevent).