{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}

-- JSON wire-format boundary for the triage domain model, generated from
-- src/Domain.hs per .claude/skills/triage-api-codegen/SKILL.md. DTOs are
-- twin types, not ToJSON/FromJSON instances on Domain.hs types directly —
-- Domain.hs has no serialization awareness of any kind (see its own
-- Layering section), so every wire shape lives here instead. Same pattern
-- as Persistence.hs's Row types and toDomainX/fromDomainX boundary
-- functions, except JSON-shaped rather than SQL-row-shaped. Re-derive from
-- Domain.hs on any domain change rather than hand-patching this file out
-- of sync with it.
--
-- ToJSON/FromJSON instances below are written by hand against explicit
-- JSON string keys (opaque-uuid-ids, tagged-flat-serialization), never
-- `deriving (Generic, ToJSON)` — a wire key must not silently drift if a
-- Haskell field is renamed later.

module Transport
  ( -- ── Decode errors ────────────────────────────────────────────────────
    TransportError (..)

    -- ── Doctor / Patient ─────────────────────────────────────────────────
  , DoctorDTO (..)
  , toDomainDoctor
  , fromDomainDoctor
  , PatientDTO (..)
  , toDomainPatient
  , fromDomainPatient

    -- ── Healthcare Service ───────────────────────────────────────────────
  , HealthcareServiceDTO (..)
  , toDomainHealthcareService
  , fromDomainHealthcareService

    -- ── Slot ─────────────────────────────────────────────────────────────
  , AvailableSlotDTO (..)
  , toDomainAvailableSlot
  , fromDomainAvailableSlot

    -- ── Appointment Party ────────────────────────────────────────────────
  , AppointmentPartyDTO (..)
  , toDomainAppointmentParty
  , fromDomainAppointmentParty

    -- ── Routine Due ──────────────────────────────────────────────────────
  , RoutineDueDTO (..)
  , toDomainRoutineDue
  , fromDomainRoutineDue

    -- ── Close Reason ─────────────────────────────────────────────────────
  , CloseReasonDTO (..)
  , toDomainCloseReason
  , fromDomainCloseReason

    -- ── Intake Request Priority ──────────────────────────────────────────
  , IntakeRequestPriorityDTO (..)
  , toDomainIntakeRequestPriority
  , fromDomainIntakeRequestPriority

    -- ── Doctor Requirement ───────────────────────────────────────────────
  , DoctorRequirementDTO (..)
  , toDomainDoctorRequirement
  , fromDomainDoctorRequirement

    -- ── Appointed Intake Request ─────────────────────────────────────────
  , AppointedIntakeRequestDTO (..)
  , toDomainAppointedIntakeRequest
  , fromDomainAppointedIntakeRequest

    -- ── Intake Request ───────────────────────────────────────────────────
  , IntakeRequestDTO (..)
  , toDomainIntakeRequest
  , fromDomainIntakeRequest

    -- ── Calendar Entry ───────────────────────────────────────────────────
  , CalendarEntryDTO (..)
  , toDomainCalendarEntry
  , fromDomainCalendarEntry
  ) where

import Data.Aeson       (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser)
import Data.Text        (Text)
import Data.Time        (UTCTime)
import Data.UUID        (UUID)

import qualified Data.UUID as UUID

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

-- CalendarEntry has no Domain.hs equivalent to import instead — it's a
-- Service.hs-level type by design (see Service.hs's own CALENDAR section:
-- "not a domain concept with a lifecycle or invariant to protect, it's a
-- display-composition of two already-real things"). This is Transport's
-- first dependency on anything beyond Domain, but it isn't a layering
-- violation: triage-api-codegen's own architecture diagram already places
-- Transport downstream of Service (Domain -> Persistence -> Service ->
-- Transport -> API), unlike the earlier TransportError-vs-
-- Persistence.DecodeError choice, where an equivalent concept existed
-- Domain-side and depending on Persistence there would have been an
-- arbitrary sideways dependency instead of a real need.
import Service (CalendarEntry (..))

-- ═══════════════════════════════════════════════════════════════════════
-- DECODE ERRORS
-- Transport-local, not Persistence.DecodeError — Transport and Persistence
-- are peer layers over Domain (see Domain.hs's Layering section), neither
-- stacked on the other, so Transport does not depend on Persistence for
-- this. The one overlapping failure mode (an out-of-range duration in
-- minutes) is re-checked here against the same 15/30/60 restriction
-- Persistence.decodeDuration enforces, rather than imported from it.
-- ═══════════════════════════════════════════════════════════════════════

-- The shared decode-error type for the whole Transport module, not scoped
-- to Duration alone — expected to keep growing constructors as later
-- steps add IntakeRequestPriority/CloseReason/IntakeRequest parsing (e.g.
-- an unrecognized "type" discriminator string will need its own case).
data TransportError
  = InvalidDurationMinutes Int
  | InvalidRoutineWithinRange UTCTime UTCTime
    -- ^ a { "type": "routineWithin", "from": ..., "to": ... } DTO whose
    -- from/to fail mkRoutineWithin's from <= to invariant.
  deriving (Show, Eq)

decodeDurationMinutes :: Int -> Either TransportError Duration
decodeDurationMinutes 15 = Right QuarterOfAnHour
decodeDurationMinutes 30 = Right HalfAnHour
decodeDurationMinutes 60 = Right OneHour
decodeDurationMinutes n  = Left (InvalidDurationMinutes n)

encodeDurationMinutes :: Duration -> Int
encodeDurationMinutes QuarterOfAnHour = 15
encodeDurationMinutes HalfAnHour      = 30
encodeDurationMinutes OneHour         = 60

-- Shared by every DTO field below carrying an ID — opaque-uuid-ids: plain
-- UUID strings on the wire, never a wrapped object.
parseUUIDField :: Text -> Parser UUID
parseUUIDField t = maybe (fail ("invalid UUID: " ++ show t)) pure (UUID.fromText t)

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT
-- No invariant beyond field types already enforced (same as Domain.hs's
-- own reasoning for exporting these constructors openly) — no decode
-- failure is possible, so toDomainX here is total, unlike the Healthcare
-- Service / Slot DTOs below.
-- ═══════════════════════════════════════════════════════════════════════

data DoctorDTO = DoctorDTO
  { id   :: UUID
  , name :: Text
  }
  deriving (Show, Eq)

instance ToJSON DoctorDTO where
  toJSON dto = object ["id" .= UUID.toText dto.id, "name" .= dto.name]

instance FromJSON DoctorDTO where
  parseJSON = withObject "DoctorDTO" $ \v -> do
    idText <- v .: "id"
    uid    <- parseUUIDField idText
    DoctorDTO uid <$> v .: "name"

toDomainDoctor :: DoctorDTO -> Doctor
toDomainDoctor dto = Doctor { id = DoctorId dto.id, name = dto.name }

fromDomainDoctor :: Doctor -> DoctorDTO
fromDomainDoctor d =
  let DoctorId did = d.id
  in DoctorDTO { id = did, name = d.name }

data PatientDTO = PatientDTO
  { id   :: UUID
  , name :: Text
  }
  deriving (Show, Eq)

instance ToJSON PatientDTO where
  toJSON dto = object ["id" .= UUID.toText dto.id, "name" .= dto.name]

instance FromJSON PatientDTO where
  parseJSON = withObject "PatientDTO" $ \v -> do
    idText <- v .: "id"
    uid    <- parseUUIDField idText
    PatientDTO uid <$> v .: "name"

toDomainPatient :: PatientDTO -> Patient
toDomainPatient dto = Patient { id = PatientId dto.id, name = dto.name }

fromDomainPatient :: Patient -> PatientDTO
fromDomainPatient p =
  let PatientId pid = p.id
  in PatientDTO { id = pid, name = p.name }

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICE
-- Duration on the wire as minutes (Int), matching how Persistence.hs
-- already encodes it, for consistency across layers. Unlike Doctor/
-- Patient above, decoding can fail (an out-of-range durationMinutes), so
-- toDomainHealthcareService returns Either TransportError.
-- ═══════════════════════════════════════════════════════════════════════

data HealthcareServiceDTO = HealthcareServiceDTO
  { id              :: UUID
  , name            :: Text
  , durationMinutes :: Int
  }
  deriving (Show, Eq)

instance ToJSON HealthcareServiceDTO where
  toJSON dto = object
    [ "id" .= UUID.toText dto.id
    , "name" .= dto.name
    , "durationMinutes" .= dto.durationMinutes
    ]

instance FromJSON HealthcareServiceDTO where
  parseJSON = withObject "HealthcareServiceDTO" $ \v -> do
    idText <- v .: "id"
    uid    <- parseUUIDField idText
    HealthcareServiceDTO uid <$> v .: "name" <*> v .: "durationMinutes"

toDomainHealthcareService :: HealthcareServiceDTO -> Either TransportError HealthcareService
toDomainHealthcareService dto =
  (\d -> HealthcareService { id = HealthcareServiceId dto.id, name = dto.name, duration = d })
    <$> decodeDurationMinutes dto.durationMinutes

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceDTO
fromDomainHealthcareService s =
  let HealthcareServiceId hsid = s.id
  in HealthcareServiceDTO
       { id = hsid, name = s.name, durationMinutes = encodeDurationMinutes s.duration }

-- ═══════════════════════════════════════════════════════════════════════
-- SLOT
-- Same duration-as-minutes shape and same decode-failure risk as
-- Healthcare Service above.
-- ═══════════════════════════════════════════════════════════════════════

data AvailableSlotDTO = AvailableSlotDTO
  { id                  :: UUID
  , doctorId            :: UUID
  , healthcareServiceId :: UUID
  , start               :: UTCTime
  , durationMinutes     :: Int
  }
  deriving (Show, Eq)

instance ToJSON AvailableSlotDTO where
  toJSON dto = object
    [ "id" .= UUID.toText dto.id
    , "doctorId" .= UUID.toText dto.doctorId
    , "healthcareServiceId" .= UUID.toText dto.healthcareServiceId
    , "start" .= dto.start
    , "durationMinutes" .= dto.durationMinutes
    ]

instance FromJSON AvailableSlotDTO where
  parseJSON = withObject "AvailableSlotDTO" $ \v -> do
    idText                  <- v .: "id"
    doctorIdText            <- v .: "doctorId"
    healthcareServiceIdText <- v .: "healthcareServiceId"
    uid                     <- parseUUIDField idText
    did                     <- parseUUIDField doctorIdText
    hsid                    <- parseUUIDField healthcareServiceIdText
    AvailableSlotDTO uid did hsid <$> v .: "start" <*> v .: "durationMinutes"

toDomainAvailableSlot :: AvailableSlotDTO -> Either TransportError AvailableSlot
toDomainAvailableSlot dto =
  (\d -> AvailableSlot
    { id                  = SlotId dto.id
    , doctorId            = DoctorId dto.doctorId
    , healthcareServiceId = HealthcareServiceId dto.healthcareServiceId
    , start               = dto.start
    , duration            = d
    })
  <$> decodeDurationMinutes dto.durationMinutes

fromDomainAvailableSlot :: AvailableSlot -> AvailableSlotDTO
fromDomainAvailableSlot s =
  let SlotId sid              = s.id
      DoctorId did             = s.doctorId
      HealthcareServiceId hsid = s.healthcareServiceId
  in AvailableSlotDTO
       { id = sid, doctorId = did, healthcareServiceId = hsid
       , start = s.start, durationMinutes = encodeDurationMinutes s.duration
       }

-- ═══════════════════════════════════════════════════════════════════════
-- APPOINTMENT PARTY
-- A flat two-case enum, no embedded data at all — mirrored here as a
-- nullary two-constructor sum type (not a single DTO record with a bare
-- "type" field and nothing else), the more idiomatic aeson encoding for a
-- no-payload Haskell enum: it lets ToJSON/FromJSON pattern-match on the
-- constructor directly instead of every caller re-checking a string. No
-- invariant beyond the two cases themselves, so toDomain/fromDomain are
-- both total.
-- ═══════════════════════════════════════════════════════════════════════

data AppointmentPartyDTO
  = ByDoctorDTO
  | ByPatientDTO
  deriving (Show, Eq)

instance ToJSON AppointmentPartyDTO where
  toJSON ByDoctorDTO  = object ["type" .= ("byDoctor" :: Text)]
  toJSON ByPatientDTO = object ["type" .= ("byPatient" :: Text)]

instance FromJSON AppointmentPartyDTO where
  parseJSON = withObject "AppointmentPartyDTO" $ \v -> do
    tag <- v .: "type"
    case (tag :: Text) of
      "byDoctor"  -> pure ByDoctorDTO
      "byPatient" -> pure ByPatientDTO
      other       -> fail ("unrecognized AppointmentParty type: " ++ show other)

toDomainAppointmentParty :: AppointmentPartyDTO -> AppointmentParty
toDomainAppointmentParty ByDoctorDTO  = ByDoctor
toDomainAppointmentParty ByPatientDTO = ByPatient

fromDomainAppointmentParty :: AppointmentParty -> AppointmentPartyDTO
fromDomainAppointmentParty ByDoctor  = ByDoctorDTO
fromDomainAppointmentParty ByPatient = ByPatientDTO

-- ═══════════════════════════════════════════════════════════════════════
-- ROUTINE DUE
-- Mirrors Domain.hs's RoutineDue shape exactly, including its positional
-- (non-record) fields — RoutineWithin's Domain-level constructor is
-- SEALED (not exported; only mkRoutineWithin's from <= to invariant can
-- produce one), so RoutineWithinDTO's decode direction is the one real
-- decode-failure case in this section: toDomainRoutineDue must go through
-- mkRoutineWithin like every other caller, never construct RoutineWithin
-- directly, and its Nothing case surfaces as InvalidRoutineWithinRange.
-- The "from"/"to" wire keys are shared verbatim by RoutineNotBefore (its
-- one earliest-bound field) and RoutineNotAfter (its one latest-bound
-- field) — same fact, same key, per tagged-flat-serialization, even
-- though each case only carries one of the two.
-- ═══════════════════════════════════════════════════════════════════════

data RoutineDueDTO
  = RoutineAnytimeDTO
  | RoutineNotBeforeDTO UTCTime
  | RoutineNotAfterDTO  UTCTime
  | RoutineWithinDTO    UTCTime UTCTime
  deriving (Show, Eq)

instance ToJSON RoutineDueDTO where
  toJSON RoutineAnytimeDTO          = object ["type" .= ("routineAnytime" :: Text)]
  toJSON (RoutineNotBeforeDTO from) = object ["type" .= ("routineNotBefore" :: Text), "from" .= from]
  toJSON (RoutineNotAfterDTO  to)   = object ["type" .= ("routineNotAfter" :: Text), "to" .= to]
  toJSON (RoutineWithinDTO from to) = object
    ["type" .= ("routineWithin" :: Text), "from" .= from, "to" .= to]

instance FromJSON RoutineDueDTO where
  parseJSON = withObject "RoutineDueDTO" $ \v -> do
    tag <- v .: "type"
    case (tag :: Text) of
      "routineAnytime"   -> pure RoutineAnytimeDTO
      "routineNotBefore" -> RoutineNotBeforeDTO <$> v .: "from"
      "routineNotAfter"  -> RoutineNotAfterDTO  <$> v .: "to"
      "routineWithin"    -> RoutineWithinDTO    <$> v .: "from" <*> v .: "to"
      other              -> fail ("unrecognized RoutineDue type: " ++ show other)

toDomainRoutineDue :: RoutineDueDTO -> Either TransportError RoutineDue
toDomainRoutineDue RoutineAnytimeDTO        = Right RoutineAnytime
toDomainRoutineDue (RoutineNotBeforeDTO lo) = Right (RoutineNotBefore lo)
toDomainRoutineDue (RoutineNotAfterDTO  hi) = Right (RoutineNotAfter hi)
toDomainRoutineDue (RoutineWithinDTO lo hi) =
  maybe (Left (InvalidRoutineWithinRange lo hi)) Right (mkRoutineWithin lo hi)

-- routineWithinBounds is the read-only accessor for RoutineWithin's
-- hidden fields (same reasoning as Persistence.hs's encodePriority) —
-- RoutineWithin's constructor is not in scope here, so this is the only
-- way to read one back out for encoding.
fromDomainRoutineDue :: RoutineDue -> RoutineDueDTO
fromDomainRoutineDue due = case routineWithinBounds due of
  Just (from, to) -> RoutineWithinDTO from to
  Nothing         -> case due of
    RoutineAnytime      -> RoutineAnytimeDTO
    RoutineNotBefore lo -> RoutineNotBeforeDTO lo
    RoutineNotAfter  hi -> RoutineNotAfterDTO hi
    _                   -> RoutineAnytimeDTO  -- unreachable: routineWithinBounds covers RoutineWithin

-- ═══════════════════════════════════════════════════════════════════════
-- CLOSE REASON
-- Three cases, Cancelled/NoShow each embedding AppointmentPartyDTO under
-- the shared "by" key — reuses toDomainAppointmentParty/
-- fromDomainAppointmentParty rather than re-encoding AppointmentParty
-- inline. Cancelled's trailing Maybe Text (its free-text note) is encoded
-- via aeson's own ToJSON (Maybe a) instance: Nothing becomes a JSON
-- `null`, not an omitted key — the "note" key is always present in a
-- cancelled object, only its value is optional, so parseJSON below reads
-- it with plain (.:), which requires the key to exist (it always does,
-- since our own encoder always emits it) but accepts null via aeson's
-- FromJSON (Maybe a) instance.
--
-- No decode failure of its own: AppointmentPartyDTO's toDomain is total
-- (verified above), and neither the "completed" nor "noShow" cases carry
-- anything else that could fail, so toDomainCloseReason returns
-- CloseReason directly, not Either.
-- ═══════════════════════════════════════════════════════════════════════

data CloseReasonDTO
  = CompletedDTO
  | CancelledDTO AppointmentPartyDTO UTCTime (Maybe Text)
  | NoShowDTO    AppointmentPartyDTO
  deriving (Show, Eq)

instance ToJSON CloseReasonDTO where
  toJSON CompletedDTO = object ["type" .= ("completed" :: Text)]
  toJSON (CancelledDTO by at note) = object
    [ "type" .= ("cancelled" :: Text)
    , "by" .= by
    , "cancelledAt" .= at
    , "note" .= note
    ]
  toJSON (NoShowDTO by) = object ["type" .= ("noShow" :: Text), "by" .= by]

instance FromJSON CloseReasonDTO where
  parseJSON = withObject "CloseReasonDTO" $ \v -> do
    tag <- v .: "type"
    case (tag :: Text) of
      "completed" -> pure CompletedDTO
      "cancelled" -> CancelledDTO <$> v .: "by" <*> v .: "cancelledAt" <*> v .: "note"
      "noShow"    -> NoShowDTO <$> v .: "by"
      other       -> fail ("unrecognized CloseReason type: " ++ show other)

toDomainCloseReason :: CloseReasonDTO -> CloseReason
toDomainCloseReason CompletedDTO                = Completed
toDomainCloseReason (CancelledDTO by at note)   = Cancelled (toDomainAppointmentParty by) at note
toDomainCloseReason (NoShowDTO by)              = NoShow (toDomainAppointmentParty by)

fromDomainCloseReason :: CloseReason -> CloseReasonDTO
fromDomainCloseReason Completed                = CompletedDTO
fromDomainCloseReason (Cancelled party at note) = CancelledDTO (fromDomainAppointmentParty party) at note
fromDomainCloseReason (NoShow party)            = NoShowDTO (fromDomainAppointmentParty party)

-- ═══════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST PRIORITY
-- EmergencyDue/UrgentDue are both newtypes wrapping a bare positional
-- UTCTime (verified against Domain.hs, not assumed) — unwrapped here via
-- pattern match, same as any other newtype field. All three cases share
-- the "due" key even though its shape differs: a flat timestamp for
-- Emergency/Urgent, a nested tagged RoutineDueDTO object for Routine —
-- expected, not an inconsistency, since RoutineDue is itself a
-- multi-shape variant unlike EmergencyDue/UrgentDue.
--
-- Emergency/Urgent are individually total, but Routine's case propagates
-- toDomainRoutineDue's Either TransportError (RoutineWithin's from > to
-- failure), which makes toDomainIntakeRequestPriority as a whole
-- Either TransportError, not total.
-- ═══════════════════════════════════════════════════════════════════════

data IntakeRequestPriorityDTO
  = EmergencyDTO UTCTime
  | UrgentDTO    UTCTime
  | RoutineDTO   RoutineDueDTO
  deriving (Show, Eq)

instance ToJSON IntakeRequestPriorityDTO where
  toJSON (EmergencyDTO due) = object ["type" .= ("emergency" :: Text), "due" .= due]
  toJSON (UrgentDTO due)    = object ["type" .= ("urgent" :: Text), "due" .= due]
  toJSON (RoutineDTO due)   = object ["type" .= ("routine" :: Text), "due" .= due]

instance FromJSON IntakeRequestPriorityDTO where
  parseJSON = withObject "IntakeRequestPriorityDTO" $ \v -> do
    tag <- v .: "type"
    case (tag :: Text) of
      "emergency" -> EmergencyDTO <$> v .: "due"
      "urgent"    -> UrgentDTO    <$> v .: "due"
      "routine"   -> RoutineDTO   <$> v .: "due"
      other       -> fail ("unrecognized IntakeRequestPriority type: " ++ show other)

toDomainIntakeRequestPriority :: IntakeRequestPriorityDTO -> Either TransportError IntakeRequestPriority
toDomainIntakeRequestPriority (EmergencyDTO due) = Right (Emergency (EmergencyDue due))
toDomainIntakeRequestPriority (UrgentDTO due)    = Right (Urgent (UrgentDue due))
toDomainIntakeRequestPriority (RoutineDTO due)   = Routine <$> toDomainRoutineDue due

fromDomainIntakeRequestPriority :: IntakeRequestPriority -> IntakeRequestPriorityDTO
fromDomainIntakeRequestPriority (Emergency (EmergencyDue due)) = EmergencyDTO due
fromDomainIntakeRequestPriority (Urgent (UrgentDue due))       = UrgentDTO due
fromDomainIntakeRequestPriority (Routine due)                  = RoutineDTO (fromDomainRoutineDue due)

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTOR REQUIREMENT
-- Two cases, verified against Domain.hs (AnyDoctor | SpecificDoctor
-- DoctorId), no embedded invariant — same pattern as AppointmentPartyDTO/
-- CloseReasonDTO. No decode failure possible beyond the UUID-string
-- parse already handled at the JSON-parse boundary (parseUUIDField, same
-- as every other UUID field in this module), so both directions are
-- total.
-- ═══════════════════════════════════════════════════════════════════════

data DoctorRequirementDTO
  = AnyDoctorDTO
  | SpecificDoctorDTO UUID
  deriving (Show, Eq)

instance ToJSON DoctorRequirementDTO where
  toJSON AnyDoctorDTO = object ["type" .= ("anyDoctor" :: Text)]
  toJSON (SpecificDoctorDTO did) = object
    ["type" .= ("specificDoctor" :: Text), "doctorId" .= UUID.toText did]

instance FromJSON DoctorRequirementDTO where
  parseJSON = withObject "DoctorRequirementDTO" $ \v -> do
    tag <- v .: "type"
    case (tag :: Text) of
      "anyDoctor"      -> pure AnyDoctorDTO
      "specificDoctor" -> do
        didText <- v .: "doctorId"
        SpecificDoctorDTO <$> parseUUIDField didText
      other -> fail ("unrecognized DoctorRequirement type: " ++ show other)

toDomainDoctorRequirement :: DoctorRequirementDTO -> DoctorRequirement
toDomainDoctorRequirement AnyDoctorDTO          = AnyDoctor
toDomainDoctorRequirement (SpecificDoctorDTO did) = SpecificDoctor (DoctorId did)

fromDomainDoctorRequirement :: DoctorRequirement -> DoctorRequirementDTO
fromDomainDoctorRequirement AnyDoctor = AnyDoctorDTO
fromDomainDoctorRequirement (SpecificDoctor did) =
  let DoctorId d = did
  in SpecificDoctorDTO d

-- ═══════════════════════════════════════════════════════════════════════
-- APPOINTED INTAKE REQUEST
-- AppointedIntakeRequest is a Domain type in its own right, not just an
-- IntakeRequest sub-case — it's also returned standalone by
-- Service.fetchAppointedIntakeRequests and needed standalone below by
-- CalendarEntryDTO. Flat record, the exact field set IntakeRequestDTO's
-- "appointed" tag already flattens (id, patientId, narrative,
-- doctorRequirement, createdAt, healthcareServiceId, priority,
-- triagedAt, doctorId, start, durationMinutes), but with NO
-- discriminator tag of its own at the top level — unlike IntakeRequest's
-- six/seven cases, there is only one shape here.
--
-- submittedFields/toDomainSubmitted and triagedFields/toDomainTriaged
-- live here (rather than in the Intake Request section below) because
-- they are now shared by two callers: AppointedIntakeRequestDTO's own
-- conversions, and IntakeRequestDTO's Submitted/Rejected/Accepted/
-- Withdrawn* cases below, which still use them directly (only the
-- Appointed/Closed cases route through AppointedIntakeRequestDTO).
-- submittedFields/triagedFields exist only on the fromDomain side (a
-- tuple, since neither IntakeRequestDTO's nor AppointedIntakeRequestDTO's
-- cases are one flat row admitting record update — mirrors
-- Persistence.hs's fromDomainSubmitted/fromDomainTriaged chain, which
-- uses record update instead since IntakeRequestRow is one flat row);
-- toDomainSubmitted/toDomainTriaged play the equivalent role on the
-- toDomain side, taking the already-flattened DTO fields as plain
-- arguments since those are already individually available from the
-- incoming pattern match.
--
-- toDomainAppointedIntakeRequest returns Either TransportError,
-- propagating toDomainTriaged's priority failure and
-- decodeDurationMinutes's duration failure — same two failure modes
-- IntakeRequestDTO's own "appointed"/"closed" cases already propagate.
-- fromDomainAppointedIntakeRequest is total (same as everything else on
-- this side).
-- ═══════════════════════════════════════════════════════════════════════

submittedFields :: SubmittedIntakeRequest -> (UUID, UUID, Text, DoctorRequirementDTO, UTCTime)
submittedFields s =
  let IntakeRequestId rid = s.id
      PatientId pid       = s.patientId
  in (rid, pid, s.narrative, fromDomainDoctorRequirement s.doctorRequirement, s.createdAt)

triagedFields
  :: TriagedIntakeRequest
  -> (UUID, UUID, Text, DoctorRequirementDTO, UTCTime, UUID, IntakeRequestPriorityDTO, UTCTime)
triagedFields t =
  let (rid, pid, narr, req, created) = submittedFields t.submitted
      HealthcareServiceId svcId      = t.healthcareServiceId
  in (rid, pid, narr, req, created, svcId, fromDomainIntakeRequestPriority t.priority, t.triagedAt)

toDomainSubmitted :: UUID -> UUID -> Text -> DoctorRequirementDTO -> UTCTime -> SubmittedIntakeRequest
toDomainSubmitted rid pid narr req =
  SubmittedIntakeRequest (IntakeRequestId rid) (PatientId pid) narr (toDomainDoctorRequirement req)

toDomainTriaged
  :: UUID -> UUID -> Text -> DoctorRequirementDTO -> UTCTime
  -> UUID -> IntakeRequestPriorityDTO -> UTCTime
  -> Either TransportError TriagedIntakeRequest
toDomainTriaged rid pid narr req created svcId prio triagedTime =
  (\p -> TriagedIntakeRequest
    (toDomainSubmitted rid pid narr req created) (HealthcareServiceId svcId) p triagedTime)
  <$> toDomainIntakeRequestPriority prio

data AppointedIntakeRequestDTO = AppointedIntakeRequestDTO
  { id                  :: UUID
  , patientId           :: UUID
  , narrative           :: Text
  , doctorRequirement   :: DoctorRequirementDTO
  , createdAt           :: UTCTime
  , healthcareServiceId :: UUID
  , priority            :: IntakeRequestPriorityDTO
  , triagedAt            :: UTCTime
  , doctorId            :: UUID
  , start               :: UTCTime
  , durationMinutes     :: Int
  }
  deriving (Show, Eq)

instance ToJSON AppointedIntakeRequestDTO where
  toJSON dto = object
    [ "id" .= UUID.toText dto.id
    , "patientId" .= UUID.toText dto.patientId
    , "narrative" .= dto.narrative
    , "doctorRequirement" .= dto.doctorRequirement
    , "createdAt" .= dto.createdAt
    , "healthcareServiceId" .= UUID.toText dto.healthcareServiceId
    , "priority" .= dto.priority
    , "triagedAt" .= dto.triagedAt
    , "doctorId" .= UUID.toText dto.doctorId
    , "start" .= dto.start
    , "durationMinutes" .= dto.durationMinutes
    ]

instance FromJSON AppointedIntakeRequestDTO where
  parseJSON = withObject "AppointedIntakeRequestDTO" $ \v -> do
    rid         <- v .: "id" >>= parseUUIDField
    pid         <- v .: "patientId" >>= parseUUIDField
    narr        <- v .: "narrative"
    req         <- v .: "doctorRequirement"
    created     <- v .: "createdAt"
    svcId       <- v .: "healthcareServiceId" >>= parseUUIDField
    prio        <- v .: "priority"
    triagedTime <- v .: "triagedAt"
    did         <- v .: "doctorId" >>= parseUUIDField
    start'      <- v .: "start"
    durMin      <- v .: "durationMinutes"
    pure (AppointedIntakeRequestDTO rid pid narr req created svcId prio triagedTime did start' durMin)

toDomainAppointedIntakeRequest :: AppointedIntakeRequestDTO -> Either TransportError AppointedIntakeRequest
toDomainAppointedIntakeRequest dto = do
  triagedReq <- toDomainTriaged
    dto.id dto.patientId dto.narrative dto.doctorRequirement dto.createdAt
    dto.healthcareServiceId dto.priority dto.triagedAt
  dur <- decodeDurationMinutes dto.durationMinutes
  Right (AppointedIntakeRequest triagedReq (DoctorId dto.doctorId) dto.start dur)

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> AppointedIntakeRequestDTO
fromDomainAppointedIntakeRequest a =
  let (rid, pid, narr, req, created, svcId, prio, triagedTime) = triagedFields a.triaged
      DoctorId did = a.doctorId
  in AppointedIntakeRequestDTO rid pid narr req created svcId prio triagedTime did a.start
       (encodeDurationMinutes a.duration)

-- ═══════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST
-- Seven tags, not six: WithdrawnIntakeRequest's two sub-cases
-- (WithdrawnFromSubmitted/WithdrawnFromAccepted) get their own top-level
-- "type" tags rather than a shared "withdrawn" tag plus a
-- nullable/conditional field distinguishing them — the same
-- no-field-stands-in-for-which-case principle tagged-flat-serialization
-- already applies to IntakeRequest's own six states applies one level
-- deeper here too.
--
-- Every field list below verified against Domain.hs's actual embedding
-- chain (SubmittedIntakeRequest -> TriagedIntakeRequest ->
-- AppointedIntakeRequest), not assumed:
--   submitted: id, patientId, narrative, doctorRequirement, createdAt
--   rejected:  + rejectedAt, rejectionReason :: Text (NOT Maybe Text —
--              unlike Cancelled's/Withdrawn's own free-text notes, a
--              rejection reason is mandatory in Domain.hs)
--   accepted:  submitted's fields + healthcareServiceId, priority,
--              triagedAt
--   appointed: accepted's fields + doctorId, start,
--              durationMinutes :: Int (matching every other DTO's
--              minutes convention) — same field set as
--              AppointedIntakeRequestDTO above, verbatim
--   withdrawnFromSubmitted: submitted's fields + withdrawnAt,
--              withdrawalNote :: Maybe Text
--   withdrawnFromAccepted:  accepted's fields + withdrawnAt,
--              withdrawalNote :: Maybe Text
--   closed:    appointed's fields + closeReason
--
-- toDomainIntakeRequest/fromDomainIntakeRequest's Appointed/Closed cases
-- build on top of toDomainAppointedIntakeRequest/
-- fromDomainAppointedIntakeRequest above rather than repeating the
-- triaged+duration flattening inline a second time — this is the same
-- flattening logic, reused, not duplicated. The other five cases
-- (Submitted/Rejected/Accepted/WithdrawnFromSubmitted/
-- WithdrawnFromAccepted) still use submittedFields/triagedFields/
-- toDomainSubmitted/toDomainTriaged directly, since they don't go
-- through AppointedIntakeRequest at all. The wire shape for "appointed"/
-- "closed" is unchanged by this — only the Haskell-side composition
-- moved; the ToJSON/FromJSON instances below (which fully determine the
-- wire format) are untouched.
--
-- toDomainIntakeRequest propagates every failure mode from the pieces it
-- composes: toDomainIntakeRequestPriority's InvalidRoutineWithinRange
-- (every case carrying a priority) and decodeDurationMinutes's
-- InvalidDurationMinutes (Appointed/Closed, now via
-- toDomainAppointedIntakeRequest). DoctorRequirementDTO introduces no
-- failure of its own (verified above), so it contributes nothing to
-- propagate. No NEW TransportError constructor is needed for this
-- flattening/reassembly step itself — Domain.hs has no invariant
-- spanning these embedded pieces beyond what Priority/Duration already
-- enforce (SubmittedIntakeRequest/TriagedIntakeRequest/
-- AppointedIntakeRequest/WithdrawnIntakeRequest/IntakeRequest are all
-- "constructor open — no invariant to protect" per Domain.hs's own
-- header comments), so nothing new can fail here that isn't already
-- covered by the existing constructors.
--
-- fromDomainIntakeRequest is total: every piece it calls
-- (fromDomainDoctorRequirement, fromDomainIntakeRequestPriority,
-- fromDomainCloseReason, fromDomainAppointedIntakeRequest,
-- encodeDurationMinutes, UUID.toText) is total.
-- ═══════════════════════════════════════════════════════════════════════

data IntakeRequestDTO
  = SubmittedDTO
      { id                :: UUID
      , patientId         :: UUID
      , narrative         :: Text
      , doctorRequirement :: DoctorRequirementDTO
      , createdAt         :: UTCTime
      }
  | RejectedDTO
      { id                :: UUID
      , patientId         :: UUID
      , narrative         :: Text
      , doctorRequirement :: DoctorRequirementDTO
      , createdAt         :: UTCTime
      , rejectedAt        :: UTCTime
      , rejectionReason   :: Text
      }
  | AcceptedDTO
      { id                  :: UUID
      , patientId           :: UUID
      , narrative           :: Text
      , doctorRequirement   :: DoctorRequirementDTO
      , createdAt           :: UTCTime
      , healthcareServiceId :: UUID
      , priority            :: IntakeRequestPriorityDTO
      , triagedAt           :: UTCTime
      }
  | AppointedDTO
      { id                  :: UUID
      , patientId           :: UUID
      , narrative           :: Text
      , doctorRequirement   :: DoctorRequirementDTO
      , createdAt           :: UTCTime
      , healthcareServiceId :: UUID
      , priority            :: IntakeRequestPriorityDTO
      , triagedAt           :: UTCTime
      , doctorId            :: UUID
      , start               :: UTCTime
      , durationMinutes     :: Int
      }
  | WithdrawnFromSubmittedDTO
      { id                :: UUID
      , patientId         :: UUID
      , narrative         :: Text
      , doctorRequirement :: DoctorRequirementDTO
      , createdAt         :: UTCTime
      , withdrawnAt       :: UTCTime
      , withdrawalNote    :: Maybe Text
      }
  | WithdrawnFromAcceptedDTO
      { id                  :: UUID
      , patientId           :: UUID
      , narrative           :: Text
      , doctorRequirement   :: DoctorRequirementDTO
      , createdAt           :: UTCTime
      , healthcareServiceId :: UUID
      , priority            :: IntakeRequestPriorityDTO
      , triagedAt           :: UTCTime
      , withdrawnAt         :: UTCTime
      , withdrawalNote      :: Maybe Text
      }
  | ClosedDTO
      { id                  :: UUID
      , patientId           :: UUID
      , narrative           :: Text
      , doctorRequirement   :: DoctorRequirementDTO
      , createdAt           :: UTCTime
      , healthcareServiceId :: UUID
      , priority            :: IntakeRequestPriorityDTO
      , triagedAt           :: UTCTime
      , doctorId            :: UUID
      , start               :: UTCTime
      , durationMinutes     :: Int
      , closeReason         :: CloseReasonDTO
      }
  deriving (Show, Eq)

instance ToJSON IntakeRequestDTO where
  toJSON (SubmittedDTO rid pid narr req created) = object
    [ "type" .= ("submitted" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    ]
  toJSON (RejectedDTO rid pid narr req created rejectedTime reason) = object
    [ "type" .= ("rejected" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    , "rejectedAt" .= rejectedTime
    , "rejectionReason" .= reason
    ]
  toJSON (AcceptedDTO rid pid narr req created svcId prio triagedTime) = object
    [ "type" .= ("accepted" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    , "healthcareServiceId" .= UUID.toText svcId
    , "priority" .= prio
    , "triagedAt" .= triagedTime
    ]
  toJSON (AppointedDTO rid pid narr req created svcId prio triagedTime did start' durMin) = object
    [ "type" .= ("appointed" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    , "healthcareServiceId" .= UUID.toText svcId
    , "priority" .= prio
    , "triagedAt" .= triagedTime
    , "doctorId" .= UUID.toText did
    , "start" .= start'
    , "durationMinutes" .= durMin
    ]
  toJSON (WithdrawnFromSubmittedDTO rid pid narr req created withdrawnTime note) = object
    [ "type" .= ("withdrawnFromSubmitted" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    , "withdrawnAt" .= withdrawnTime
    , "withdrawalNote" .= note
    ]
  toJSON (WithdrawnFromAcceptedDTO rid pid narr req created svcId prio triagedTime withdrawnTime note) = object
    [ "type" .= ("withdrawnFromAccepted" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    , "healthcareServiceId" .= UUID.toText svcId
    , "priority" .= prio
    , "triagedAt" .= triagedTime
    , "withdrawnAt" .= withdrawnTime
    , "withdrawalNote" .= note
    ]
  toJSON (ClosedDTO rid pid narr req created svcId prio triagedTime did start' durMin reason) = object
    [ "type" .= ("closed" :: Text)
    , "id" .= UUID.toText rid
    , "patientId" .= UUID.toText pid
    , "narrative" .= narr
    , "doctorRequirement" .= req
    , "createdAt" .= created
    , "healthcareServiceId" .= UUID.toText svcId
    , "priority" .= prio
    , "triagedAt" .= triagedTime
    , "doctorId" .= UUID.toText did
    , "start" .= start'
    , "durationMinutes" .= durMin
    , "closeReason" .= reason
    ]

instance FromJSON IntakeRequestDTO where
  parseJSON = withObject "IntakeRequestDTO" $ \v -> do
    tag <- v .: "type"
    case (tag :: Text) of
      "submitted" -> do
        rid     <- v .: "id" >>= parseUUIDField
        pid     <- v .: "patientId" >>= parseUUIDField
        narr    <- v .: "narrative"
        req     <- v .: "doctorRequirement"
        created <- v .: "createdAt"
        pure (SubmittedDTO rid pid narr req created)
      "rejected" -> do
        rid          <- v .: "id" >>= parseUUIDField
        pid          <- v .: "patientId" >>= parseUUIDField
        narr         <- v .: "narrative"
        req          <- v .: "doctorRequirement"
        created      <- v .: "createdAt"
        rejectedTime <- v .: "rejectedAt"
        reason       <- v .: "rejectionReason"
        pure (RejectedDTO rid pid narr req created rejectedTime reason)
      "accepted" -> do
        rid         <- v .: "id" >>= parseUUIDField
        pid         <- v .: "patientId" >>= parseUUIDField
        narr        <- v .: "narrative"
        req         <- v .: "doctorRequirement"
        created     <- v .: "createdAt"
        svcId       <- v .: "healthcareServiceId" >>= parseUUIDField
        prio        <- v .: "priority"
        triagedTime <- v .: "triagedAt"
        pure (AcceptedDTO rid pid narr req created svcId prio triagedTime)
      "appointed" -> do
        rid         <- v .: "id" >>= parseUUIDField
        pid         <- v .: "patientId" >>= parseUUIDField
        narr        <- v .: "narrative"
        req         <- v .: "doctorRequirement"
        created     <- v .: "createdAt"
        svcId       <- v .: "healthcareServiceId" >>= parseUUIDField
        prio        <- v .: "priority"
        triagedTime <- v .: "triagedAt"
        did         <- v .: "doctorId" >>= parseUUIDField
        start'      <- v .: "start"
        durMin      <- v .: "durationMinutes"
        pure (AppointedDTO rid pid narr req created svcId prio triagedTime did start' durMin)
      "withdrawnFromSubmitted" -> do
        rid           <- v .: "id" >>= parseUUIDField
        pid           <- v .: "patientId" >>= parseUUIDField
        narr          <- v .: "narrative"
        req           <- v .: "doctorRequirement"
        created       <- v .: "createdAt"
        withdrawnTime <- v .: "withdrawnAt"
        note          <- v .: "withdrawalNote"
        pure (WithdrawnFromSubmittedDTO rid pid narr req created withdrawnTime note)
      "withdrawnFromAccepted" -> do
        rid           <- v .: "id" >>= parseUUIDField
        pid           <- v .: "patientId" >>= parseUUIDField
        narr          <- v .: "narrative"
        req           <- v .: "doctorRequirement"
        created       <- v .: "createdAt"
        svcId         <- v .: "healthcareServiceId" >>= parseUUIDField
        prio          <- v .: "priority"
        triagedTime   <- v .: "triagedAt"
        withdrawnTime <- v .: "withdrawnAt"
        note          <- v .: "withdrawalNote"
        pure (WithdrawnFromAcceptedDTO rid pid narr req created svcId prio triagedTime withdrawnTime note)
      "closed" -> do
        rid         <- v .: "id" >>= parseUUIDField
        pid         <- v .: "patientId" >>= parseUUIDField
        narr        <- v .: "narrative"
        req         <- v .: "doctorRequirement"
        created     <- v .: "createdAt"
        svcId       <- v .: "healthcareServiceId" >>= parseUUIDField
        prio        <- v .: "priority"
        triagedTime <- v .: "triagedAt"
        did         <- v .: "doctorId" >>= parseUUIDField
        start'      <- v .: "start"
        durMin      <- v .: "durationMinutes"
        reason      <- v .: "closeReason"
        pure (ClosedDTO rid pid narr req created svcId prio triagedTime did start' durMin reason)
      other -> fail ("unrecognized IntakeRequest type: " ++ show other)

toDomainIntakeRequest :: IntakeRequestDTO -> Either TransportError IntakeRequest
toDomainIntakeRequest (SubmittedDTO rid pid narr req created) =
  Right (Submitted (toDomainSubmitted rid pid narr req created))
toDomainIntakeRequest (RejectedDTO rid pid narr req created rejectedTime reason) =
  Right (Rejected (toDomainSubmitted rid pid narr req created) rejectedTime reason)
toDomainIntakeRequest (AcceptedDTO rid pid narr req created svcId prio triagedTime) =
  Accepted <$> toDomainTriaged rid pid narr req created svcId prio triagedTime
toDomainIntakeRequest (AppointedDTO rid pid narr req created svcId prio triagedTime did start' durMin) =
  Appointed <$> toDomainAppointedIntakeRequest
    (AppointedIntakeRequestDTO rid pid narr req created svcId prio triagedTime did start' durMin)
toDomainIntakeRequest (WithdrawnFromSubmittedDTO rid pid narr req created withdrawnTime note) =
  Right
    (Withdrawn
      (WithdrawnFromSubmitted (toDomainSubmitted rid pid narr req created) withdrawnTime note))
toDomainIntakeRequest
  (WithdrawnFromAcceptedDTO rid pid narr req created svcId prio triagedTime withdrawnTime note) = do
  triagedReq <- toDomainTriaged rid pid narr req created svcId prio triagedTime
  Right (Withdrawn (WithdrawnFromAccepted triagedReq withdrawnTime note))
toDomainIntakeRequest (ClosedDTO rid pid narr req created svcId prio triagedTime did start' durMin reason) =
  (\appointed -> Closed appointed (toDomainCloseReason reason))
  <$> toDomainAppointedIntakeRequest
        (AppointedIntakeRequestDTO rid pid narr req created svcId prio triagedTime did start' durMin)

fromDomainIntakeRequest :: IntakeRequest -> IntakeRequestDTO
fromDomainIntakeRequest (Submitted s) =
  let (rid, pid, narr, req, created) = submittedFields s
  in SubmittedDTO rid pid narr req created
fromDomainIntakeRequest (Rejected s rejectedTime reason) =
  let (rid, pid, narr, req, created) = submittedFields s
  in RejectedDTO rid pid narr req created rejectedTime reason
fromDomainIntakeRequest (Accepted t) =
  let (rid, pid, narr, req, created, svcId, prio, triagedTime) = triagedFields t
  in AcceptedDTO rid pid narr req created svcId prio triagedTime
fromDomainIntakeRequest (Appointed a) =
  let AppointedIntakeRequestDTO rid pid narr req created svcId prio triagedTime did start' durMin =
        fromDomainAppointedIntakeRequest a
  in AppointedDTO rid pid narr req created svcId prio triagedTime did start' durMin
fromDomainIntakeRequest (Withdrawn (WithdrawnFromSubmitted s withdrawnTime note)) =
  let (rid, pid, narr, req, created) = submittedFields s
  in WithdrawnFromSubmittedDTO rid pid narr req created withdrawnTime note
fromDomainIntakeRequest (Withdrawn (WithdrawnFromAccepted t withdrawnTime note)) =
  let (rid, pid, narr, req, created, svcId, prio, triagedTime) = triagedFields t
  in WithdrawnFromAcceptedDTO rid pid narr req created svcId prio triagedTime withdrawnTime note
fromDomainIntakeRequest (Closed a reason) =
  let AppointedIntakeRequestDTO rid pid narr req created svcId prio triagedTime did start' durMin =
        fromDomainAppointedIntakeRequest a
  in ClosedDTO rid pid narr req created svcId prio triagedTime did start' durMin
       (fromDomainCloseReason reason)

-- ═══════════════════════════════════════════════════════════════════════
-- CALENDAR ENTRY
-- CalendarEntry lives in Service.hs, not Domain.hs (see the import note
-- above) — two cases, Slot AvailableSlot | Appointment
-- AppointedIntakeRequest, verified against Service.hs directly rather
-- than assumed.
--
-- AvailableSlotDTO's fields (id, doctorId, healthcareServiceId, start,
-- durationMinutes) are a strict subset of AppointedIntakeRequestDTO's
-- fields — neither carries its own discriminator today, and without one,
-- a naive "try parsing as a slot, else an appointment" FromJSON would
-- always successfully (mis)parse actual appointment JSON as a slot too,
-- since every key a slot needs is also present on an appointment. This
-- is a genuine decode-ambiguity risk, not just a style-consistency
-- argument, so CalendarEntryDTO adds its own "type": "slot" /
-- "type": "appointment" wrapper, flattened per tagged-flat-serialization
-- (never a nested "contents" wrapper) rather than nesting the embedded
-- DTO under its own key.
--
-- FromJSON reuses AvailableSlotDTO's/AppointedIntakeRequestDTO's own
-- parseJSON directly on the same underlying value once the tag selects
-- which one applies — safe because neither embedded FromJSON instance
-- looks for a "type" key, so the extra key already present is simply
-- ignored, and no field list is re-typed a second time. ToJSON is not
-- symmetrically reused this way (it duplicates the embedded DTO's field
-- list instead of merging JSON values) to avoid introducing this file's
-- only raw-Aeson-Object-merging code path for a single two-constructor
-- type; every other ToJSON instance here builds an object literal from
-- scratch the same way.
-- ═══════════════════════════════════════════════════════════════════════

data CalendarEntryDTO
  = SlotEntryDTO        AvailableSlotDTO
  | AppointmentEntryDTO AppointedIntakeRequestDTO
  deriving (Show, Eq)

instance ToJSON CalendarEntryDTO where
  toJSON (SlotEntryDTO slot) = object
    [ "type" .= ("slot" :: Text)
    , "id" .= UUID.toText slot.id
    , "doctorId" .= UUID.toText slot.doctorId
    , "healthcareServiceId" .= UUID.toText slot.healthcareServiceId
    , "start" .= slot.start
    , "durationMinutes" .= slot.durationMinutes
    ]
  toJSON (AppointmentEntryDTO appt) = object
    [ "type" .= ("appointment" :: Text)
    , "id" .= UUID.toText appt.id
    , "patientId" .= UUID.toText appt.patientId
    , "narrative" .= appt.narrative
    , "doctorRequirement" .= appt.doctorRequirement
    , "createdAt" .= appt.createdAt
    , "healthcareServiceId" .= UUID.toText appt.healthcareServiceId
    , "priority" .= appt.priority
    , "triagedAt" .= appt.triagedAt
    , "doctorId" .= UUID.toText appt.doctorId
    , "start" .= appt.start
    , "durationMinutes" .= appt.durationMinutes
    ]

instance FromJSON CalendarEntryDTO where
  parseJSON v = do
    tag <- withObject "CalendarEntryDTO" (.: "type") v
    case (tag :: Text) of
      "slot"        -> SlotEntryDTO        <$> parseJSON v
      "appointment" -> AppointmentEntryDTO <$> parseJSON v
      other         -> fail ("unrecognized CalendarEntry type: " ++ show other)

toDomainCalendarEntry :: CalendarEntryDTO -> Either TransportError CalendarEntry
toDomainCalendarEntry (SlotEntryDTO slot)        = Slot <$> toDomainAvailableSlot slot
toDomainCalendarEntry (AppointmentEntryDTO appt) = Appointment <$> toDomainAppointedIntakeRequest appt

fromDomainCalendarEntry :: CalendarEntry -> CalendarEntryDTO
fromDomainCalendarEntry (Slot s)        = SlotEntryDTO (fromDomainAvailableSlot s)
fromDomainCalendarEntry (Appointment a) = AppointmentEntryDTO (fromDomainAppointedIntakeRequest a)
