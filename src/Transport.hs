{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeApplications      #-}

-- Derived from src/Domain.hs by the triage-api-codegen skill: the JSON wire
-- format. One DTO per Domain.hs type that crosses the wire, with
-- hand-written ToJSON / FromJSON / ToSchema, plus one request type per
-- Service function that takes caller-supplied facts. Domain types carry no
-- instances.
--
-- Wire shape (tagged-flat-serialization): a sum type is one flat object per
-- case, discriminated by "type" (the constructor in lowerCamelCase);
-- embedded stages are flattened into their case's object; a nested value is
-- an object under its field's key; every ID is a plain UUID string.
module Transport
  ( -- ── IDs ──────────────────────────────────────────────────────────────
    DoctorIdDTO (..)
  , PatientIdDTO (..)
  , HealthcareServiceIdDTO (..)
  , IntakeRequestIdDTO (..)
  , SlotIdDTO (..)
  , toDomainDoctorId
  , fromDomainDoctorId
  , toDomainPatientId
  , fromDomainPatientId
  , toDomainHealthcareServiceId
  , fromDomainHealthcareServiceId
  , toDomainIntakeRequestId
  , fromDomainIntakeRequestId
  , toDomainSlotId
  , fromDomainSlotId

    -- ── Enumerations ─────────────────────────────────────────────────────
  , DurationDTO (..)
  , toDomainDuration
  , fromDomainDuration
  , AppointmentPartyDTO (..)
  , toDomainAppointmentParty
  , fromDomainAppointmentParty

    -- ── Doctor / Patient / Healthcare service ────────────────────────────
  , DoctorDTO (..)
  , fromDomainDoctor
  , toDomainDoctor
  , PatientDTO (..)
  , fromDomainPatient
  , toDomainPatient
  , HealthcareServiceDTO (..)
  , fromDomainHealthcareService
  , toDomainHealthcareService

    -- ── Doctor requirement / priority ────────────────────────────────────
  , DoctorRequirementDTO (..)
  , toDomainDoctorRequirement
  , fromDomainDoctorRequirement
  , MustBeSeenByDTO (..)
  , toDomainMustBeSeenBy
  , fromDomainMustBeSeenBy
  , RoutineWindowDTO (..)
  , toDomainRoutineWindow
  , fromDomainRoutineWindow
  , RoutineDueDTO (..)
  , toDomainRoutineDue
  , fromDomainRoutineDue
  , IntakeRequestPriorityDTO (..)
  , toDomainIntakeRequestPriority
  , fromDomainIntakeRequestPriority

    -- ── Intake request ───────────────────────────────────────────────────
  , SubmittedIntakeRequestDTO (..)
  , toDomainSubmittedIntakeRequest
  , fromDomainSubmittedIntakeRequest
  , RejectedIntakeRequestDTO (..)
  , toDomainRejectedIntakeRequest
  , fromDomainRejectedIntakeRequest
  , TriagedIntakeRequestDTO (..)
  , toDomainTriagedIntakeRequest
  , fromDomainTriagedIntakeRequest
  , AppointedIntakeRequestDTO (..)
  , toDomainAppointedIntakeRequest
  , fromDomainAppointedIntakeRequest
  , WithdrawnFromDTO (..)
  , toDomainWithdrawnFrom
  , fromDomainWithdrawnFrom
  , WithdrawnIntakeRequestDTO (..)
  , toDomainWithdrawnIntakeRequest
  , fromDomainWithdrawnIntakeRequest
  , StaleIntakeRequestDTO (..)
  , toDomainStaleIntakeRequest
  , fromDomainStaleIntakeRequest
  , CancellationDTO (..)
  , toDomainCancellation
  , fromDomainCancellation
  , AbsenceDTO (..)
  , toDomainAbsence
  , fromDomainAbsence
  , CloseReasonDTO (..)
  , toDomainCloseReason
  , fromDomainCloseReason
  , ClosedIntakeRequestDTO (..)
  , toDomainClosedIntakeRequest
  , fromDomainClosedIntakeRequest
  , IntakeRequestDTO (..)
  , toDomainIntakeRequest
  , fromDomainIntakeRequest

    -- ── Slot / doctor calendar ───────────────────────────────────────────
  , AvailableSlotDTO (..)
  , toDomainAvailableSlot
  , fromDomainAvailableSlot
  , DoctorCalendarEntryDTO (..)
  , toDomainDoctorCalendarEntry
  , fromDomainDoctorCalendarEntry

    -- ── Request bodies ───────────────────────────────────────────────────
  , CreateDoctorRequest (..)
  , CreatePatientRequest (..)
  , CreateHealthcareServiceRequest (..)
  , SubmitIntakeRequestRequest (..)
  , AcceptSubmittedIntakeRequestRequest (..)
  , RejectSubmittedIntakeRequestRequest (..)
  , MatchAcceptedIntakeRequestToSlotRequest (..)
  , WithdrawIntakeRequestRequest (..)
  , CloseAppointedIntakeRequestRequest (..)
  , CloseReasonRequest (..)
  , CancellationRequest (..)
  , toDomainCloseReasonRequest
  , CreateAvailableSlotRequest (..)
  ) where

import Control.Lens        ((&), (.~), (?~))
import Control.Monad       (unless)
import Data.Aeson
  ( FromJSON (..), Object, ToJSON (..), Value (..), object, withObject, (.:), (.=) )
import Data.Aeson.Types    (Pair, Parser)
import Data.Function       (on)
import Data.List           (find, intersect, nubBy)
import Data.Proxy          (Proxy (..))
import Data.Swagger
  ( Definitions, NamedSchema (..), Referenced (..), Schema, SwaggerType (..), ToParamSchema (..)
  , ToSchema (..), declareSchemaRef, description, enum_, properties, required, toSchema, type_ )
import Data.Swagger.Declare (Declare)
import Data.Text           (Text)
import Data.Time           (UTCTime)
import Data.UUID           (UUID)
import GHC.Exts            (fromList)
import Servant.API         (FromHttpApiData (..))

import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Text         as Text
import qualified Data.UUID         as UUID

import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- FLAT OBJECTS
-- Every DTO is an object; flattening a value into an enclosing object is
-- concatenating its keys. Each DTO says once which keys it contributes, how
-- to read them back from an object, and their schema; its ToJSON, FromJSON
-- and ToSchema are built from that.
-- ═══════════════════════════════════════════════════════════════════════════

type Decl = Declare (Definitions Schema)

-- An object's schema, before it is named: its properties in order, the keys
-- every value has, and (for a sum) which keys each case has.
data Shape = Shape
  { shapeProperties  :: [(Text, Referenced Schema)]
  , shapeRequired    :: [Text]
  , shapeDescription :: Maybe Text
  }

instance Semigroup Shape where
  Shape p r d <> Shape p' r' d' = Shape (p <> p') (r <> r') (maybe d' Just d)

instance Monoid Shape where
  mempty = Shape [] [] Nothing

class Flat a where
  flatten   :: a -> [Pair]
  unflatten :: Object -> Parser a
  shape     :: Proxy a -> Decl Shape

encodeFlat :: Flat a => a -> Value
encodeFlat = object . flatten

-- A case's object has exactly its own keys: a key the decoded value would
-- not encode is a wrong field.
decodeFlat :: Flat a => String -> Value -> Parser a
decodeFlat name = withObject name $ \o -> do
  a <- unflatten o
  let expected = map fst (flatten a)
      extra    = filter (`notElem` expected) (KeyMap.keys o)
  unless (null extra) $
    fail (name <> ": unexpected keys " <> show (map Key.toString extra))
  pure a

schemaFlat :: Flat a => Text -> Proxy a -> Decl NamedSchema
schemaFlat name p = NamedSchema (Just name) . shapeSchema <$> shape p

shapeSchema :: Shape -> Schema
shapeSchema (Shape props req desc) =
  mempty
    & type_ ?~ SwaggerObject
    & properties .~ fromList props
    & required .~ req
    & description .~ desc

-- A key every value has.
field :: ToSchema a => Text -> Proxy a -> Decl Shape
field key p = do
  ref <- declareSchemaRef p
  pure (Shape [(key, ref)] [key] Nothing)

-- A Maybe field: its key is always present, and null when the value is
-- absent. Swagger 2.0 cannot mark a property nullable, so it is left out of
-- "required" (the validator accepts null only for a non-required key).
maybeField :: ToSchema a => Text -> Proxy a -> Decl Shape
maybeField key p = do
  ref <- declareSchemaRef p
  pure (Shape [(key, ref)] [] (Nothing))

tagKey :: Text -> Pair
tagKey t = "type" .= t

tagSchema :: [Text] -> Referenced Schema
tagSchema tags = Inline $
  mempty & type_ ?~ SwaggerString & enum_ ?~ map String tags

-- Swagger 2.0 has no oneOf: a sum is described as one object with the union
-- of its cases' properties, "type" listing the cases, only the keys every
-- case has as required, and each case's keys in the description.
unionShape :: Text -> [(Text, Shape)] -> Shape
unionShape intro cases = Shape
  { shapeProperties  = nubBy ((==) `on` fst) (concatMap (shapeProperties . snd) cases)
  , shapeRequired    = foldr1 intersect (map (shapeRequired . snd) cases)
  , shapeDescription = Just $ intro <> Text.intercalate "; " (map describe cases)
  }
  where
    describe (t, s) = case map fst (shapeProperties s) of
      []   -> t <> ": no other keys"
      keys -> t <> ": " <> Text.intercalate ", " keys

sumShape :: [(Text, Decl Shape)] -> Decl Shape
sumShape cases = do
  shapes <- traverse (\(t, d) -> (,) t <$> d) cases
  let union = unionShape "One object per case, told apart by \"type\". " shapes
  pure union
    { shapeProperties = ("type", tagSchema (map fst cases)) : shapeProperties union
    , shapeRequired   = "type" : shapeRequired union
    }

readTag :: Object -> Parser Text
readTag o = o .: "type"

unknownTag :: String -> Text -> Parser a
unknownTag name t = fail (name <> ": unknown type " <> show t)

-- An enumeration: an object with only "type".
enumerationFrom :: (Enum a, Bounded a) => String -> (a -> Text) -> Object -> Parser a
enumerationFrom name tagOf o = do
  t <- readTag o
  maybe (unknownTag name t) pure (find ((== t) . tagOf) [minBound .. maxBound])

enumerationShape :: (Enum a, Bounded a) => (a -> Text) -> Proxy a -> Decl Shape
enumerationShape tagOf p = sumShape [(tagOf c, pure mempty) | c <- values p]
  where
    values :: (Enum a, Bounded a) => Proxy a -> [a]
    values _ = [minBound .. maxBound]

-- ═══════════════════════════════════════════════════════════════════════════
-- IDS
-- A plain UUID string; each ID type has its own named schema.
-- ═══════════════════════════════════════════════════════════════════════════

idSchema :: Text -> Decl NamedSchema
idSchema name = pure (NamedSchema (Just name) (toSchema (Proxy @UUID)))

parseIdPiece :: (UUID -> a) -> Text -> Either Text a
parseIdPiece wrap = maybe (Left "not a UUID") (Right . wrap) . UUID.fromText

newtype DoctorIdDTO = DoctorIdDTO UUID deriving (Show, Eq)

instance ToJSON DoctorIdDTO where toJSON (DoctorIdDTO u) = toJSON u
instance FromJSON DoctorIdDTO where parseJSON v = DoctorIdDTO <$> parseJSON v
instance ToSchema DoctorIdDTO where declareNamedSchema _ = idSchema "DoctorId"
instance ToParamSchema DoctorIdDTO where toParamSchema _ = toParamSchema (Proxy @UUID)
instance FromHttpApiData DoctorIdDTO where parseUrlPiece = parseIdPiece DoctorIdDTO

toDomainDoctorId :: DoctorIdDTO -> DoctorId
toDomainDoctorId (DoctorIdDTO u) = DoctorId u

fromDomainDoctorId :: DoctorId -> DoctorIdDTO
fromDomainDoctorId (DoctorId u) = DoctorIdDTO u

newtype PatientIdDTO = PatientIdDTO UUID deriving (Show, Eq)

instance ToJSON PatientIdDTO where toJSON (PatientIdDTO u) = toJSON u
instance FromJSON PatientIdDTO where parseJSON v = PatientIdDTO <$> parseJSON v
instance ToSchema PatientIdDTO where declareNamedSchema _ = idSchema "PatientId"
instance ToParamSchema PatientIdDTO where toParamSchema _ = toParamSchema (Proxy @UUID)
instance FromHttpApiData PatientIdDTO where parseUrlPiece = parseIdPiece PatientIdDTO

toDomainPatientId :: PatientIdDTO -> PatientId
toDomainPatientId (PatientIdDTO u) = PatientId u

fromDomainPatientId :: PatientId -> PatientIdDTO
fromDomainPatientId (PatientId u) = PatientIdDTO u

newtype HealthcareServiceIdDTO = HealthcareServiceIdDTO UUID deriving (Show, Eq)

instance ToJSON HealthcareServiceIdDTO where toJSON (HealthcareServiceIdDTO u) = toJSON u
instance FromJSON HealthcareServiceIdDTO where parseJSON v = HealthcareServiceIdDTO <$> parseJSON v
instance ToSchema HealthcareServiceIdDTO where declareNamedSchema _ = idSchema "HealthcareServiceId"
instance ToParamSchema HealthcareServiceIdDTO where toParamSchema _ = toParamSchema (Proxy @UUID)
instance FromHttpApiData HealthcareServiceIdDTO where parseUrlPiece = parseIdPiece HealthcareServiceIdDTO

toDomainHealthcareServiceId :: HealthcareServiceIdDTO -> HealthcareServiceId
toDomainHealthcareServiceId (HealthcareServiceIdDTO u) = HealthcareServiceId u

fromDomainHealthcareServiceId :: HealthcareServiceId -> HealthcareServiceIdDTO
fromDomainHealthcareServiceId (HealthcareServiceId u) = HealthcareServiceIdDTO u

newtype IntakeRequestIdDTO = IntakeRequestIdDTO UUID deriving (Show, Eq)

instance ToJSON IntakeRequestIdDTO where toJSON (IntakeRequestIdDTO u) = toJSON u
instance FromJSON IntakeRequestIdDTO where parseJSON v = IntakeRequestIdDTO <$> parseJSON v
instance ToSchema IntakeRequestIdDTO where declareNamedSchema _ = idSchema "IntakeRequestId"
instance ToParamSchema IntakeRequestIdDTO where toParamSchema _ = toParamSchema (Proxy @UUID)
instance FromHttpApiData IntakeRequestIdDTO where parseUrlPiece = parseIdPiece IntakeRequestIdDTO

toDomainIntakeRequestId :: IntakeRequestIdDTO -> IntakeRequestId
toDomainIntakeRequestId (IntakeRequestIdDTO u) = IntakeRequestId u

fromDomainIntakeRequestId :: IntakeRequestId -> IntakeRequestIdDTO
fromDomainIntakeRequestId (IntakeRequestId u) = IntakeRequestIdDTO u

newtype SlotIdDTO = SlotIdDTO UUID deriving (Show, Eq)

instance ToJSON SlotIdDTO where toJSON (SlotIdDTO u) = toJSON u
instance FromJSON SlotIdDTO where parseJSON v = SlotIdDTO <$> parseJSON v
instance ToSchema SlotIdDTO where declareNamedSchema _ = idSchema "SlotId"
instance ToParamSchema SlotIdDTO where toParamSchema _ = toParamSchema (Proxy @UUID)
instance FromHttpApiData SlotIdDTO where parseUrlPiece = parseIdPiece SlotIdDTO

toDomainSlotId :: SlotIdDTO -> SlotId
toDomainSlotId (SlotIdDTO u) = SlotId u

fromDomainSlotId :: SlotId -> SlotIdDTO
fromDomainSlotId (SlotId u) = SlotIdDTO u

-- ═══════════════════════════════════════════════════════════════════════════
-- ENUMERATIONS
-- ═══════════════════════════════════════════════════════════════════════════

data DurationDTO
  = QuarterOfAnHourDTO
  | HalfAnHourDTO
  | OneHourDTO
  deriving (Show, Eq, Enum, Bounded)

durationTag :: DurationDTO -> Text
durationTag QuarterOfAnHourDTO = "quarterOfAnHour"
durationTag HalfAnHourDTO      = "halfAnHour"
durationTag OneHourDTO         = "oneHour"

instance Flat DurationDTO where
  flatten d = [tagKey (durationTag d)]
  unflatten = enumerationFrom "Duration" durationTag
  shape     = enumerationShape durationTag

instance ToJSON DurationDTO where toJSON = encodeFlat
instance FromJSON DurationDTO where parseJSON = decodeFlat "Duration"
instance ToSchema DurationDTO where declareNamedSchema = schemaFlat "Duration"

toDomainDuration :: DurationDTO -> Duration
toDomainDuration QuarterOfAnHourDTO = QuarterOfAnHour
toDomainDuration HalfAnHourDTO      = HalfAnHour
toDomainDuration OneHourDTO         = OneHour

fromDomainDuration :: Duration -> DurationDTO
fromDomainDuration QuarterOfAnHour = QuarterOfAnHourDTO
fromDomainDuration HalfAnHour      = HalfAnHourDTO
fromDomainDuration OneHour         = OneHourDTO

data AppointmentPartyDTO
  = DoctorPartyDTO
  | PatientPartyDTO
  deriving (Show, Eq, Enum, Bounded)

appointmentPartyTag :: AppointmentPartyDTO -> Text
appointmentPartyTag DoctorPartyDTO  = "doctorParty"
appointmentPartyTag PatientPartyDTO = "patientParty"

instance Flat AppointmentPartyDTO where
  flatten p = [tagKey (appointmentPartyTag p)]
  unflatten = enumerationFrom "AppointmentParty" appointmentPartyTag
  shape     = enumerationShape appointmentPartyTag

instance ToJSON AppointmentPartyDTO where toJSON = encodeFlat
instance FromJSON AppointmentPartyDTO where parseJSON = decodeFlat "AppointmentParty"
instance ToSchema AppointmentPartyDTO where declareNamedSchema = schemaFlat "AppointmentParty"

toDomainAppointmentParty :: AppointmentPartyDTO -> AppointmentParty
toDomainAppointmentParty DoctorPartyDTO  = DoctorParty
toDomainAppointmentParty PatientPartyDTO = PatientParty

fromDomainAppointmentParty :: AppointmentParty -> AppointmentPartyDTO
fromDomainAppointmentParty DoctorParty  = DoctorPartyDTO
fromDomainAppointmentParty PatientParty = PatientPartyDTO

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT / HEALTHCARE SERVICE
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorDTO = DoctorDTO
  { id   :: DoctorIdDTO
  , name :: Text
  }
  deriving (Show, Eq)

instance Flat DoctorDTO where
  flatten d = ["id" .= d.id, "name" .= d.name]
  unflatten o = DoctorDTO <$> o .: "id" <*> o .: "name"
  shape _ = mconcat <$> sequence [field "id" (Proxy @DoctorIdDTO), field "name" (Proxy @Text)]

instance ToJSON DoctorDTO where toJSON = encodeFlat
instance FromJSON DoctorDTO where parseJSON = decodeFlat "Doctor"
instance ToSchema DoctorDTO where declareNamedSchema = schemaFlat "Doctor"

fromDomainDoctor :: Doctor -> DoctorDTO
fromDomainDoctor d = DoctorDTO (fromDomainDoctorId d.id) d.name

toDomainDoctor :: DoctorDTO -> Doctor
toDomainDoctor d = Doctor { id = toDomainDoctorId d.id, name = d.name }

data PatientDTO = PatientDTO
  { id   :: PatientIdDTO
  , name :: Text
  }
  deriving (Show, Eq)

instance Flat PatientDTO where
  flatten p = ["id" .= p.id, "name" .= p.name]
  unflatten o = PatientDTO <$> o .: "id" <*> o .: "name"
  shape _ = mconcat <$> sequence [field "id" (Proxy @PatientIdDTO), field "name" (Proxy @Text)]

instance ToJSON PatientDTO where toJSON = encodeFlat
instance FromJSON PatientDTO where parseJSON = decodeFlat "Patient"
instance ToSchema PatientDTO where declareNamedSchema = schemaFlat "Patient"

fromDomainPatient :: Patient -> PatientDTO
fromDomainPatient p = PatientDTO (fromDomainPatientId p.id) p.name

toDomainPatient :: PatientDTO -> Patient
toDomainPatient p = Patient { id = toDomainPatientId p.id, name = p.name }

data HealthcareServiceDTO = HealthcareServiceDTO
  { id       :: HealthcareServiceIdDTO
  , name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

instance Flat HealthcareServiceDTO where
  flatten s = ["id" .= s.id, "name" .= s.name, "duration" .= s.duration]
  unflatten o = HealthcareServiceDTO <$> o .: "id" <*> o .: "name" <*> o .: "duration"
  shape _ = mconcat <$> sequence
    [ field "id" (Proxy @HealthcareServiceIdDTO)
    , field "name" (Proxy @Text)
    , field "duration" (Proxy @DurationDTO)
    ]

instance ToJSON HealthcareServiceDTO where toJSON = encodeFlat
instance FromJSON HealthcareServiceDTO where parseJSON = decodeFlat "HealthcareService"
instance ToSchema HealthcareServiceDTO where declareNamedSchema = schemaFlat "HealthcareService"

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceDTO
fromDomainHealthcareService s =
  HealthcareServiceDTO (fromDomainHealthcareServiceId s.id) s.name (fromDomainDuration s.duration)

toDomainHealthcareService :: HealthcareServiceDTO -> HealthcareService
toDomainHealthcareService s = HealthcareService
  { id = toDomainHealthcareServiceId s.id, name = s.name, duration = toDomainDuration s.duration }

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR REQUIREMENT
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorRequirementDTO
  = AnyDoctorDTO
  | SpecificDoctorDTO DoctorIdDTO
  deriving (Show, Eq)

instance Flat DoctorRequirementDTO where
  flatten AnyDoctorDTO          = [tagKey "anyDoctor"]
  flatten (SpecificDoctorDTO d) = [tagKey "specificDoctor", "specificDoctor" .= d]
  unflatten o = readTag o >>= \t -> case t of
    "anyDoctor"      -> pure AnyDoctorDTO
    "specificDoctor" -> SpecificDoctorDTO <$> o .: "specificDoctor"
    _                -> unknownTag "DoctorRequirement" t
  shape _ = sumShape
    [ ("anyDoctor", pure mempty)
    , ("specificDoctor", field "specificDoctor" (Proxy @DoctorIdDTO))
    ]

instance ToJSON DoctorRequirementDTO where toJSON = encodeFlat
instance FromJSON DoctorRequirementDTO where parseJSON = decodeFlat "DoctorRequirement"
instance ToSchema DoctorRequirementDTO where declareNamedSchema = schemaFlat "DoctorRequirement"

toDomainDoctorRequirement :: DoctorRequirementDTO -> DoctorRequirement
toDomainDoctorRequirement AnyDoctorDTO          = AnyDoctor
toDomainDoctorRequirement (SpecificDoctorDTO d) = SpecificDoctor (toDomainDoctorId d)

fromDomainDoctorRequirement :: DoctorRequirement -> DoctorRequirementDTO
fromDomainDoctorRequirement AnyDoctor          = AnyDoctorDTO
fromDomainDoctorRequirement (SpecificDoctor d) = SpecificDoctorDTO (fromDomainDoctorId d)

-- ═══════════════════════════════════════════════════════════════════════════
-- PRIORITY / DUE CONSTRAINTS
-- ═══════════════════════════════════════════════════════════════════════════

newtype MustBeSeenByDTO = MustBeSeenByDTO UTCTime
  deriving (Show, Eq)

instance Flat MustBeSeenByDTO where
  flatten (MustBeSeenByDTO t) = ["mustBeSeenBy" .= t]
  unflatten o = MustBeSeenByDTO <$> o .: "mustBeSeenBy"
  shape _ = field "mustBeSeenBy" (Proxy @UTCTime)

instance ToJSON MustBeSeenByDTO where toJSON = encodeFlat
instance FromJSON MustBeSeenByDTO where parseJSON = decodeFlat "MustBeSeenBy"
instance ToSchema MustBeSeenByDTO where declareNamedSchema = schemaFlat "MustBeSeenBy"

toDomainMustBeSeenBy :: MustBeSeenByDTO -> MustBeSeenBy
toDomainMustBeSeenBy (MustBeSeenByDTO t) = MustBeSeenBy t

fromDomainMustBeSeenBy :: MustBeSeenBy -> MustBeSeenByDTO
fromDomainMustBeSeenBy (MustBeSeenBy t) = MustBeSeenByDTO t

-- Sealed: holds a RoutineWindow, so it exists only once mkRoutineWindow has
-- accepted its bounds. Decoding goes through mkRoutineWindow; a refusal is a
-- parse failure.
newtype RoutineWindowDTO = RoutineWindowDTO RoutineWindow
  deriving (Show, Eq)

instance Flat RoutineWindowDTO where
  flatten (RoutineWindowDTO w) =
    ["routineNotBefore" .= routineNotBefore w, "routineNotAfter" .= routineNotAfter w]
  unflatten o = do
    notBefore <- o .: "routineNotBefore"
    notAfter  <- o .: "routineNotAfter"
    maybe (fail "RoutineWindow: routineNotBefore is after routineNotAfter")
          (pure . RoutineWindowDTO)
          (mkRoutineWindow notBefore notAfter)
  shape _ = mconcat <$> sequence
    [field "routineNotBefore" (Proxy @UTCTime), field "routineNotAfter" (Proxy @UTCTime)]

instance ToJSON RoutineWindowDTO where toJSON = encodeFlat
instance FromJSON RoutineWindowDTO where parseJSON = decodeFlat "RoutineWindow"
instance ToSchema RoutineWindowDTO where declareNamedSchema = schemaFlat "RoutineWindow"

toDomainRoutineWindow :: RoutineWindowDTO -> RoutineWindow
toDomainRoutineWindow (RoutineWindowDTO w) = w

fromDomainRoutineWindow :: RoutineWindow -> RoutineWindowDTO
fromDomainRoutineWindow = RoutineWindowDTO

data RoutineDueDTO
  = RoutineAnytimeDTO
  | RoutineNotBeforeDTO UTCTime
  | RoutineNotAfterDTO  UTCTime
  | RoutineWithinDTO    RoutineWindowDTO
  deriving (Show, Eq)

instance Flat RoutineDueDTO where
  flatten RoutineAnytimeDTO       = [tagKey "routineAnytime"]
  flatten (RoutineNotBeforeDTO t) = [tagKey "routineNotBefore", "routineNotBefore" .= t]
  flatten (RoutineNotAfterDTO t)  = [tagKey "routineNotAfter", "routineNotAfter" .= t]
  flatten (RoutineWithinDTO w)    = tagKey "routineWithin" : flatten w
  unflatten o = readTag o >>= \t -> case t of
    "routineAnytime"   -> pure RoutineAnytimeDTO
    "routineNotBefore" -> RoutineNotBeforeDTO <$> o .: "routineNotBefore"
    "routineNotAfter"  -> RoutineNotAfterDTO <$> o .: "routineNotAfter"
    "routineWithin"    -> RoutineWithinDTO <$> unflatten o
    _                  -> unknownTag "RoutineDue" t
  shape _ = sumShape
    [ ("routineAnytime", pure mempty)
    , ("routineNotBefore", field "routineNotBefore" (Proxy @UTCTime))
    , ("routineNotAfter", field "routineNotAfter" (Proxy @UTCTime))
    , ("routineWithin", shape (Proxy @RoutineWindowDTO))
    ]

instance ToJSON RoutineDueDTO where toJSON = encodeFlat
instance FromJSON RoutineDueDTO where parseJSON = decodeFlat "RoutineDue"
instance ToSchema RoutineDueDTO where declareNamedSchema = schemaFlat "RoutineDue"

toDomainRoutineDue :: RoutineDueDTO -> RoutineDue
toDomainRoutineDue RoutineAnytimeDTO       = RoutineAnytime
toDomainRoutineDue (RoutineNotBeforeDTO t) = RoutineNotBefore t
toDomainRoutineDue (RoutineNotAfterDTO t)  = RoutineNotAfter t
toDomainRoutineDue (RoutineWithinDTO w)    = RoutineWithin (toDomainRoutineWindow w)

fromDomainRoutineDue :: RoutineDue -> RoutineDueDTO
fromDomainRoutineDue RoutineAnytime       = RoutineAnytimeDTO
fromDomainRoutineDue (RoutineNotBefore t) = RoutineNotBeforeDTO t
fromDomainRoutineDue (RoutineNotAfter t)  = RoutineNotAfterDTO t
fromDomainRoutineDue (RoutineWithin w)    = RoutineWithinDTO (fromDomainRoutineWindow w)

-- Routine's payload is a sum type, so it is nested under "routine" (one
-- object can't hold two "type" keys).
data IntakeRequestPriorityDTO
  = EmergencyDTO MustBeSeenByDTO
  | UrgentDTO    MustBeSeenByDTO
  | RoutineDTO   RoutineDueDTO
  deriving (Show, Eq)

instance Flat IntakeRequestPriorityDTO where
  flatten (EmergencyDTO m) = tagKey "emergency" : flatten m
  flatten (UrgentDTO m)    = tagKey "urgent" : flatten m
  flatten (RoutineDTO d)   = [tagKey "routine", "routine" .= d]
  unflatten o = readTag o >>= \t -> case t of
    "emergency" -> EmergencyDTO <$> unflatten o
    "urgent"    -> UrgentDTO <$> unflatten o
    "routine"   -> RoutineDTO <$> o .: "routine"
    _           -> unknownTag "IntakeRequestPriority" t
  shape _ = sumShape
    [ ("emergency", shape (Proxy @MustBeSeenByDTO))
    , ("urgent", shape (Proxy @MustBeSeenByDTO))
    , ("routine", field "routine" (Proxy @RoutineDueDTO))
    ]

instance ToJSON IntakeRequestPriorityDTO where toJSON = encodeFlat
instance FromJSON IntakeRequestPriorityDTO where parseJSON = decodeFlat "IntakeRequestPriority"
instance ToSchema IntakeRequestPriorityDTO where
  declareNamedSchema = schemaFlat "IntakeRequestPriority"

toDomainIntakeRequestPriority :: IntakeRequestPriorityDTO -> IntakeRequestPriority
toDomainIntakeRequestPriority (EmergencyDTO m) = Emergency (toDomainMustBeSeenBy m)
toDomainIntakeRequestPriority (UrgentDTO m)    = Urgent (toDomainMustBeSeenBy m)
toDomainIntakeRequestPriority (RoutineDTO d)   = Routine (toDomainRoutineDue d)

fromDomainIntakeRequestPriority :: IntakeRequestPriority -> IntakeRequestPriorityDTO
fromDomainIntakeRequestPriority (Emergency m) = EmergencyDTO (fromDomainMustBeSeenBy m)
fromDomainIntakeRequestPriority (Urgent m)    = UrgentDTO (fromDomainMustBeSeenBy m)
fromDomainIntakeRequestPriority (Routine d)   = RoutineDTO (fromDomainRoutineDue d)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST STAGES
-- Each stage embeds the one before it; on the wire the embedded stage's
-- keys join the stage's own.
-- ═══════════════════════════════════════════════════════════════════════════

data SubmittedIntakeRequestDTO = SubmittedIntakeRequestDTO
  { id        :: IntakeRequestIdDTO
  , patientId :: PatientIdDTO
  , narrative :: Text
  , createdAt :: UTCTime
  }
  deriving (Show, Eq)

instance Flat SubmittedIntakeRequestDTO where
  flatten s =
    [ "id" .= s.id, "patientId" .= s.patientId, "narrative" .= s.narrative
    , "createdAt" .= s.createdAt ]
  unflatten o = SubmittedIntakeRequestDTO
    <$> o .: "id" <*> o .: "patientId" <*> o .: "narrative" <*> o .: "createdAt"
  shape _ = mconcat <$> sequence
    [ field "id" (Proxy @IntakeRequestIdDTO)
    , field "patientId" (Proxy @PatientIdDTO)
    , field "narrative" (Proxy @Text)
    , field "createdAt" (Proxy @UTCTime)
    ]

instance ToJSON SubmittedIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON SubmittedIntakeRequestDTO where parseJSON = decodeFlat "SubmittedIntakeRequest"
instance ToSchema SubmittedIntakeRequestDTO where
  declareNamedSchema = schemaFlat "SubmittedIntakeRequest"

toDomainSubmittedIntakeRequest :: SubmittedIntakeRequestDTO -> SubmittedIntakeRequest
toDomainSubmittedIntakeRequest s = SubmittedIntakeRequest
  { id        = toDomainIntakeRequestId s.id
  , patientId = toDomainPatientId s.patientId
  , narrative = s.narrative
  , createdAt = s.createdAt
  }

fromDomainSubmittedIntakeRequest :: SubmittedIntakeRequest -> SubmittedIntakeRequestDTO
fromDomainSubmittedIntakeRequest s = SubmittedIntakeRequestDTO
  { id        = fromDomainIntakeRequestId s.id
  , patientId = fromDomainPatientId s.patientId
  , narrative = s.narrative
  , createdAt = s.createdAt
  }

data RejectedIntakeRequestDTO = RejectedIntakeRequestDTO
  { submitted       :: SubmittedIntakeRequestDTO
  , rejectedAt      :: UTCTime
  , rejectionReason :: Text
  }
  deriving (Show, Eq)

instance Flat RejectedIntakeRequestDTO where
  flatten r =
    flatten r.submitted <> ["rejectedAt" .= r.rejectedAt, "rejectionReason" .= r.rejectionReason]
  unflatten o = RejectedIntakeRequestDTO
    <$> unflatten o <*> o .: "rejectedAt" <*> o .: "rejectionReason"
  shape _ = mconcat <$> sequence
    [ shape (Proxy @SubmittedIntakeRequestDTO)
    , field "rejectedAt" (Proxy @UTCTime)
    , field "rejectionReason" (Proxy @Text)
    ]

instance ToJSON RejectedIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON RejectedIntakeRequestDTO where parseJSON = decodeFlat "RejectedIntakeRequest"
instance ToSchema RejectedIntakeRequestDTO where
  declareNamedSchema = schemaFlat "RejectedIntakeRequest"

toDomainRejectedIntakeRequest :: RejectedIntakeRequestDTO -> RejectedIntakeRequest
toDomainRejectedIntakeRequest r = RejectedIntakeRequest
  { submitted       = toDomainSubmittedIntakeRequest r.submitted
  , rejectedAt      = r.rejectedAt
  , rejectionReason = r.rejectionReason
  }

fromDomainRejectedIntakeRequest :: RejectedIntakeRequest -> RejectedIntakeRequestDTO
fromDomainRejectedIntakeRequest r = RejectedIntakeRequestDTO
  { submitted       = fromDomainSubmittedIntakeRequest r.submitted
  , rejectedAt      = r.rejectedAt
  , rejectionReason = r.rejectionReason
  }

data TriagedIntakeRequestDTO = TriagedIntakeRequestDTO
  { submitted           :: SubmittedIntakeRequestDTO
  , healthcareServiceId :: HealthcareServiceIdDTO
  , priority            :: IntakeRequestPriorityDTO
  , doctorRequirement   :: DoctorRequirementDTO
  , triagedAt           :: UTCTime
  }
  deriving (Show, Eq)

instance Flat TriagedIntakeRequestDTO where
  flatten t = flatten t.submitted <>
    [ "healthcareServiceId" .= t.healthcareServiceId
    , "priority" .= t.priority
    , "doctorRequirement" .= t.doctorRequirement
    , "triagedAt" .= t.triagedAt
    ]
  unflatten o = TriagedIntakeRequestDTO
    <$> unflatten o <*> o .: "healthcareServiceId" <*> o .: "priority"
    <*> o .: "doctorRequirement" <*> o .: "triagedAt"
  shape _ = mconcat <$> sequence
    [ shape (Proxy @SubmittedIntakeRequestDTO)
    , field "healthcareServiceId" (Proxy @HealthcareServiceIdDTO)
    , field "priority" (Proxy @IntakeRequestPriorityDTO)
    , field "doctorRequirement" (Proxy @DoctorRequirementDTO)
    , field "triagedAt" (Proxy @UTCTime)
    ]

instance ToJSON TriagedIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON TriagedIntakeRequestDTO where parseJSON = decodeFlat "TriagedIntakeRequest"
instance ToSchema TriagedIntakeRequestDTO where
  declareNamedSchema = schemaFlat "TriagedIntakeRequest"

toDomainTriagedIntakeRequest :: TriagedIntakeRequestDTO -> TriagedIntakeRequest
toDomainTriagedIntakeRequest t = TriagedIntakeRequest
  { submitted           = toDomainSubmittedIntakeRequest t.submitted
  , healthcareServiceId = toDomainHealthcareServiceId t.healthcareServiceId
  , priority            = toDomainIntakeRequestPriority t.priority
  , doctorRequirement   = toDomainDoctorRequirement t.doctorRequirement
  , triagedAt           = t.triagedAt
  }

fromDomainTriagedIntakeRequest :: TriagedIntakeRequest -> TriagedIntakeRequestDTO
fromDomainTriagedIntakeRequest t = TriagedIntakeRequestDTO
  { submitted           = fromDomainSubmittedIntakeRequest t.submitted
  , healthcareServiceId = fromDomainHealthcareServiceId t.healthcareServiceId
  , priority            = fromDomainIntakeRequestPriority t.priority
  , doctorRequirement   = fromDomainDoctorRequirement t.doctorRequirement
  , triagedAt           = t.triagedAt
  }

data AppointedIntakeRequestDTO = AppointedIntakeRequestDTO
  { triaged  :: TriagedIntakeRequestDTO
  , doctorId :: DoctorIdDTO
  , start    :: UTCTime
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

instance Flat AppointedIntakeRequestDTO where
  flatten a = flatten a.triaged <>
    ["doctorId" .= a.doctorId, "start" .= a.start, "duration" .= a.duration]
  unflatten o = AppointedIntakeRequestDTO
    <$> unflatten o <*> o .: "doctorId" <*> o .: "start" <*> o .: "duration"
  shape _ = mconcat <$> sequence
    [ shape (Proxy @TriagedIntakeRequestDTO)
    , field "doctorId" (Proxy @DoctorIdDTO)
    , field "start" (Proxy @UTCTime)
    , field "duration" (Proxy @DurationDTO)
    ]

instance ToJSON AppointedIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON AppointedIntakeRequestDTO where parseJSON = decodeFlat "AppointedIntakeRequest"
instance ToSchema AppointedIntakeRequestDTO where
  declareNamedSchema = schemaFlat "AppointedIntakeRequest"

toDomainAppointedIntakeRequest :: AppointedIntakeRequestDTO -> AppointedIntakeRequest
toDomainAppointedIntakeRequest a = AppointedIntakeRequest
  { triaged  = toDomainTriagedIntakeRequest a.triaged
  , doctorId = toDomainDoctorId a.doctorId
  , start    = a.start
  , duration = toDomainDuration a.duration
  }

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> AppointedIntakeRequestDTO
fromDomainAppointedIntakeRequest a = AppointedIntakeRequestDTO
  { triaged  = fromDomainTriagedIntakeRequest a.triaged
  , doctorId = fromDomainDoctorId a.doctorId
  , start    = a.start
  , duration = fromDomainDuration a.duration
  }

-- Each case carries a stage. Standalone it is a flat case object; as
-- WithdrawnIntakeRequest's field its stage's keys join the enclosing object
-- and the field keeps only {"type": <case>}.
data WithdrawnFromDTO
  = FromSubmittedDTO SubmittedIntakeRequestDTO
  | FromAcceptedDTO  TriagedIntakeRequestDTO
  deriving (Show, Eq)

withdrawnFromTag :: WithdrawnFromDTO -> Text
withdrawnFromTag (FromSubmittedDTO _) = "fromSubmitted"
withdrawnFromTag (FromAcceptedDTO _)  = "fromAccepted"

withdrawnFromStage :: WithdrawnFromDTO -> [Pair]
withdrawnFromStage (FromSubmittedDTO s) = flatten s
withdrawnFromStage (FromAcceptedDTO t)  = flatten t

-- The stage, read from the object its keys were flattened into.
withdrawnFromStageOf :: Text -> Object -> Parser WithdrawnFromDTO
withdrawnFromStageOf t o = case t of
  "fromSubmitted" -> FromSubmittedDTO <$> unflatten o
  "fromAccepted"  -> FromAcceptedDTO <$> unflatten o
  _               -> unknownTag "WithdrawnFrom" t

withdrawnFromStageShapes :: Decl [(Text, Shape)]
withdrawnFromStageShapes = sequence
  [ (,) "fromSubmitted" <$> shape (Proxy @SubmittedIntakeRequestDTO)
  , (,) "fromAccepted" <$> shape (Proxy @TriagedIntakeRequestDTO)
  ]

instance Flat WithdrawnFromDTO where
  flatten f = tagKey (withdrawnFromTag f) : withdrawnFromStage f
  unflatten o = readTag o >>= \t -> withdrawnFromStageOf t o
  shape _ = sumShape
    [ ("fromSubmitted", shape (Proxy @SubmittedIntakeRequestDTO))
    , ("fromAccepted", shape (Proxy @TriagedIntakeRequestDTO))
    ]

instance ToJSON WithdrawnFromDTO where toJSON = encodeFlat
instance FromJSON WithdrawnFromDTO where parseJSON = decodeFlat "WithdrawnFrom"
instance ToSchema WithdrawnFromDTO where declareNamedSchema = schemaFlat "WithdrawnFrom"

toDomainWithdrawnFrom :: WithdrawnFromDTO -> WithdrawnFrom
toDomainWithdrawnFrom (FromSubmittedDTO s) = FromSubmitted (toDomainSubmittedIntakeRequest s)
toDomainWithdrawnFrom (FromAcceptedDTO t)  = FromAccepted (toDomainTriagedIntakeRequest t)

fromDomainWithdrawnFrom :: WithdrawnFrom -> WithdrawnFromDTO
fromDomainWithdrawnFrom (FromSubmitted s) = FromSubmittedDTO (fromDomainSubmittedIntakeRequest s)
fromDomainWithdrawnFrom (FromAccepted t)  = FromAcceptedDTO (fromDomainTriagedIntakeRequest t)

data WithdrawnIntakeRequestDTO = WithdrawnIntakeRequestDTO
  { withdrawnFrom  :: WithdrawnFromDTO
  , withdrawnAt    :: UTCTime
  , withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

instance Flat WithdrawnIntakeRequestDTO where
  flatten w =
    ("withdrawnFrom" .= object [tagKey (withdrawnFromTag w.withdrawnFrom)])
      : withdrawnFromStage w.withdrawnFrom
      <> ["withdrawnAt" .= w.withdrawnAt, "withdrawalNote" .= w.withdrawalNote]
  unflatten o = do
    from <- o .: "withdrawnFrom" >>= withObject "withdrawnFrom" onlyTag
    WithdrawnIntakeRequestDTO
      <$> withdrawnFromStageOf from o <*> o .: "withdrawnAt" <*> o .: "withdrawalNote"
    where
      onlyTag f = do
        unless (KeyMap.keys f == ["type"]) $ fail "withdrawnFrom: only \"type\" is allowed"
        readTag f
  shape _ = do
    stages <- withdrawnFromStageShapes
    let stageUnion = unionShape "Keys of the stage it was withdrawn from, by withdrawnFrom.type. " stages
        from = Shape [("withdrawnFrom", fromTag)] ["withdrawnFrom"] Nothing
        fromTag = Inline (shapeSchema (Shape [("type", tagSchema (map fst stages))] ["type"] Nothing))
    own <- mconcat <$> sequence
      [ field "withdrawnAt" (Proxy @UTCTime), maybeField "withdrawalNote" (Proxy @Text) ]
    pure (from <> stageUnion <> own)

instance ToJSON WithdrawnIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON WithdrawnIntakeRequestDTO where parseJSON = decodeFlat "WithdrawnIntakeRequest"
instance ToSchema WithdrawnIntakeRequestDTO where
  declareNamedSchema = schemaFlat "WithdrawnIntakeRequest"

toDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequestDTO -> WithdrawnIntakeRequest
toDomainWithdrawnIntakeRequest w = WithdrawnIntakeRequest
  { withdrawnFrom  = toDomainWithdrawnFrom w.withdrawnFrom
  , withdrawnAt    = w.withdrawnAt
  , withdrawalNote = w.withdrawalNote
  }

fromDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequest -> WithdrawnIntakeRequestDTO
fromDomainWithdrawnIntakeRequest w = WithdrawnIntakeRequestDTO
  { withdrawnFrom  = fromDomainWithdrawnFrom w.withdrawnFrom
  , withdrawnAt    = w.withdrawnAt
  , withdrawalNote = w.withdrawalNote
  }

data StaleIntakeRequestDTO = StaleIntakeRequestDTO
  { triaged :: TriagedIntakeRequestDTO
  , staleAt :: UTCTime
  }
  deriving (Show, Eq)

instance Flat StaleIntakeRequestDTO where
  flatten s = flatten s.triaged <> ["staleAt" .= s.staleAt]
  unflatten o = StaleIntakeRequestDTO <$> unflatten o <*> o .: "staleAt"
  shape _ = mconcat <$> sequence
    [ shape (Proxy @TriagedIntakeRequestDTO), field "staleAt" (Proxy @UTCTime) ]

instance ToJSON StaleIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON StaleIntakeRequestDTO where parseJSON = decodeFlat "StaleIntakeRequest"
instance ToSchema StaleIntakeRequestDTO where declareNamedSchema = schemaFlat "StaleIntakeRequest"

toDomainStaleIntakeRequest :: StaleIntakeRequestDTO -> StaleIntakeRequest
toDomainStaleIntakeRequest s = StaleIntakeRequest
  { triaged = toDomainTriagedIntakeRequest s.triaged, staleAt = s.staleAt }

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> StaleIntakeRequestDTO
fromDomainStaleIntakeRequest s = StaleIntakeRequestDTO
  { triaged = fromDomainTriagedIntakeRequest s.triaged, staleAt = s.staleAt }

-- ═══════════════════════════════════════════════════════════════════════════
-- CLOSE REASON
-- ═══════════════════════════════════════════════════════════════════════════

data CancellationDTO = CancellationDTO
  { cancelledBy      :: AppointmentPartyDTO
  , cancelledAt      :: UTCTime
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

instance Flat CancellationDTO where
  flatten c =
    [ "cancelledBy" .= c.cancelledBy, "cancelledAt" .= c.cancelledAt
    , "cancellationNote" .= c.cancellationNote ]
  unflatten o = CancellationDTO
    <$> o .: "cancelledBy" <*> o .: "cancelledAt" <*> o .: "cancellationNote"
  shape _ = mconcat <$> sequence
    [ field "cancelledBy" (Proxy @AppointmentPartyDTO)
    , field "cancelledAt" (Proxy @UTCTime)
    , maybeField "cancellationNote" (Proxy @Text)
    ]

instance ToJSON CancellationDTO where toJSON = encodeFlat
instance FromJSON CancellationDTO where parseJSON = decodeFlat "Cancellation"
instance ToSchema CancellationDTO where declareNamedSchema = schemaFlat "Cancellation"

toDomainCancellation :: CancellationDTO -> Cancellation
toDomainCancellation c = Cancellation
  { cancelledBy      = toDomainAppointmentParty c.cancelledBy
  , cancelledAt      = c.cancelledAt
  , cancellationNote = c.cancellationNote
  }

fromDomainCancellation :: Cancellation -> CancellationDTO
fromDomainCancellation c = CancellationDTO
  { cancelledBy      = fromDomainAppointmentParty c.cancelledBy
  , cancelledAt      = c.cancelledAt
  , cancellationNote = c.cancellationNote
  }

newtype AbsenceDTO = AbsenceDTO
  { absentParty :: AppointmentPartyDTO
  }
  deriving (Show, Eq)

instance Flat AbsenceDTO where
  flatten a = ["absentParty" .= a.absentParty]
  unflatten o = AbsenceDTO <$> o .: "absentParty"
  shape _ = field "absentParty" (Proxy @AppointmentPartyDTO)

instance ToJSON AbsenceDTO where toJSON = encodeFlat
instance FromJSON AbsenceDTO where parseJSON = decodeFlat "Absence"
instance ToSchema AbsenceDTO where declareNamedSchema = schemaFlat "Absence"

toDomainAbsence :: AbsenceDTO -> Absence
toDomainAbsence a = Absence { absentParty = toDomainAppointmentParty a.absentParty }

fromDomainAbsence :: Absence -> AbsenceDTO
fromDomainAbsence a = AbsenceDTO { absentParty = fromDomainAppointmentParty a.absentParty }

data CloseReasonDTO
  = CompletedDTO
  | CancelledDTO CancellationDTO
  | NoShowDTO    AbsenceDTO
  deriving (Show, Eq)

instance Flat CloseReasonDTO where
  flatten CompletedDTO     = [tagKey "completed"]
  flatten (CancelledDTO c) = tagKey "cancelled" : flatten c
  flatten (NoShowDTO a)    = tagKey "noShow" : flatten a
  unflatten o = readTag o >>= \t -> case t of
    "completed" -> pure CompletedDTO
    "cancelled" -> CancelledDTO <$> unflatten o
    "noShow"    -> NoShowDTO <$> unflatten o
    _           -> unknownTag "CloseReason" t
  shape _ = sumShape
    [ ("completed", pure mempty)
    , ("cancelled", shape (Proxy @CancellationDTO))
    , ("noShow", shape (Proxy @AbsenceDTO))
    ]

instance ToJSON CloseReasonDTO where toJSON = encodeFlat
instance FromJSON CloseReasonDTO where parseJSON = decodeFlat "CloseReason"
instance ToSchema CloseReasonDTO where declareNamedSchema = schemaFlat "CloseReason"

toDomainCloseReason :: CloseReasonDTO -> CloseReason
toDomainCloseReason CompletedDTO     = Completed
toDomainCloseReason (CancelledDTO c) = Cancelled (toDomainCancellation c)
toDomainCloseReason (NoShowDTO a)    = NoShow (toDomainAbsence a)

fromDomainCloseReason :: CloseReason -> CloseReasonDTO
fromDomainCloseReason Completed     = CompletedDTO
fromDomainCloseReason (Cancelled c) = CancelledDTO (fromDomainCancellation c)
fromDomainCloseReason (NoShow a)    = NoShowDTO (fromDomainAbsence a)

data ClosedIntakeRequestDTO = ClosedIntakeRequestDTO
  { appointed   :: AppointedIntakeRequestDTO
  , closeReason :: CloseReasonDTO
  }
  deriving (Show, Eq)

instance Flat ClosedIntakeRequestDTO where
  flatten c = flatten c.appointed <> ["closeReason" .= c.closeReason]
  unflatten o = ClosedIntakeRequestDTO <$> unflatten o <*> o .: "closeReason"
  shape _ = mconcat <$> sequence
    [ shape (Proxy @AppointedIntakeRequestDTO), field "closeReason" (Proxy @CloseReasonDTO) ]

instance ToJSON ClosedIntakeRequestDTO where toJSON = encodeFlat
instance FromJSON ClosedIntakeRequestDTO where parseJSON = decodeFlat "ClosedIntakeRequest"
instance ToSchema ClosedIntakeRequestDTO where declareNamedSchema = schemaFlat "ClosedIntakeRequest"

toDomainClosedIntakeRequest :: ClosedIntakeRequestDTO -> ClosedIntakeRequest
toDomainClosedIntakeRequest c = ClosedIntakeRequest
  { appointed = toDomainAppointedIntakeRequest c.appointed
  , closeReason = toDomainCloseReason c.closeReason
  }

fromDomainClosedIntakeRequest :: ClosedIntakeRequest -> ClosedIntakeRequestDTO
fromDomainClosedIntakeRequest c = ClosedIntakeRequestDTO
  { appointed = fromDomainAppointedIntakeRequest c.appointed
  , closeReason = fromDomainCloseReason c.closeReason
  }

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST
-- ═══════════════════════════════════════════════════════════════════════════

data IntakeRequestDTO
  = SubmittedDTO SubmittedIntakeRequestDTO
  | RejectedDTO  RejectedIntakeRequestDTO
  | AcceptedDTO  TriagedIntakeRequestDTO
  | AppointedDTO AppointedIntakeRequestDTO
  | WithdrawnDTO WithdrawnIntakeRequestDTO
  | StaleDTO     StaleIntakeRequestDTO
  | ClosedDTO    ClosedIntakeRequestDTO
  deriving (Show, Eq)

instance Flat IntakeRequestDTO where
  flatten (SubmittedDTO s) = tagKey "submitted" : flatten s
  flatten (RejectedDTO r)  = tagKey "rejected" : flatten r
  flatten (AcceptedDTO t)  = tagKey "accepted" : flatten t
  flatten (AppointedDTO a) = tagKey "appointed" : flatten a
  flatten (WithdrawnDTO w) = tagKey "withdrawn" : flatten w
  flatten (StaleDTO s)     = tagKey "stale" : flatten s
  flatten (ClosedDTO c)    = tagKey "closed" : flatten c
  unflatten o = readTag o >>= \t -> case t of
    "submitted" -> SubmittedDTO <$> unflatten o
    "rejected"  -> RejectedDTO <$> unflatten o
    "accepted"  -> AcceptedDTO <$> unflatten o
    "appointed" -> AppointedDTO <$> unflatten o
    "withdrawn" -> WithdrawnDTO <$> unflatten o
    "stale"     -> StaleDTO <$> unflatten o
    "closed"    -> ClosedDTO <$> unflatten o
    _           -> unknownTag "IntakeRequest" t
  shape _ = sumShape
    [ ("submitted", shape (Proxy @SubmittedIntakeRequestDTO))
    , ("rejected", shape (Proxy @RejectedIntakeRequestDTO))
    , ("accepted", shape (Proxy @TriagedIntakeRequestDTO))
    , ("appointed", shape (Proxy @AppointedIntakeRequestDTO))
    , ("withdrawn", shape (Proxy @WithdrawnIntakeRequestDTO))
    , ("stale", shape (Proxy @StaleIntakeRequestDTO))
    , ("closed", shape (Proxy @ClosedIntakeRequestDTO))
    ]

instance ToJSON IntakeRequestDTO where toJSON = encodeFlat
instance FromJSON IntakeRequestDTO where parseJSON = decodeFlat "IntakeRequest"
instance ToSchema IntakeRequestDTO where declareNamedSchema = schemaFlat "IntakeRequest"

toDomainIntakeRequest :: IntakeRequestDTO -> IntakeRequest
toDomainIntakeRequest (SubmittedDTO s) = Submitted (toDomainSubmittedIntakeRequest s)
toDomainIntakeRequest (RejectedDTO r)  = Rejected (toDomainRejectedIntakeRequest r)
toDomainIntakeRequest (AcceptedDTO t)  = Accepted (toDomainTriagedIntakeRequest t)
toDomainIntakeRequest (AppointedDTO a) = Appointed (toDomainAppointedIntakeRequest a)
toDomainIntakeRequest (WithdrawnDTO w) = Withdrawn (toDomainWithdrawnIntakeRequest w)
toDomainIntakeRequest (StaleDTO s)     = Stale (toDomainStaleIntakeRequest s)
toDomainIntakeRequest (ClosedDTO c)    = Closed (toDomainClosedIntakeRequest c)

fromDomainIntakeRequest :: IntakeRequest -> IntakeRequestDTO
fromDomainIntakeRequest (Submitted s) = SubmittedDTO (fromDomainSubmittedIntakeRequest s)
fromDomainIntakeRequest (Rejected r)  = RejectedDTO (fromDomainRejectedIntakeRequest r)
fromDomainIntakeRequest (Accepted t)  = AcceptedDTO (fromDomainTriagedIntakeRequest t)
fromDomainIntakeRequest (Appointed a) = AppointedDTO (fromDomainAppointedIntakeRequest a)
fromDomainIntakeRequest (Withdrawn w) = WithdrawnDTO (fromDomainWithdrawnIntakeRequest w)
fromDomainIntakeRequest (Stale s)     = StaleDTO (fromDomainStaleIntakeRequest s)
fromDomainIntakeRequest (Closed c)    = ClosedDTO (fromDomainClosedIntakeRequest c)

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT / DOCTOR CALENDAR
-- ═══════════════════════════════════════════════════════════════════════════

data AvailableSlotDTO = AvailableSlotDTO
  { id                  :: SlotIdDTO
  , doctorId            :: DoctorIdDTO
  , healthcareServiceId :: HealthcareServiceIdDTO
  , start               :: UTCTime
  , duration            :: DurationDTO
  }
  deriving (Show, Eq)

instance Flat AvailableSlotDTO where
  flatten s =
    [ "id" .= s.id, "doctorId" .= s.doctorId, "healthcareServiceId" .= s.healthcareServiceId
    , "start" .= s.start, "duration" .= s.duration ]
  unflatten o = AvailableSlotDTO
    <$> o .: "id" <*> o .: "doctorId" <*> o .: "healthcareServiceId"
    <*> o .: "start" <*> o .: "duration"
  shape _ = mconcat <$> sequence
    [ field "id" (Proxy @SlotIdDTO)
    , field "doctorId" (Proxy @DoctorIdDTO)
    , field "healthcareServiceId" (Proxy @HealthcareServiceIdDTO)
    , field "start" (Proxy @UTCTime)
    , field "duration" (Proxy @DurationDTO)
    ]

instance ToJSON AvailableSlotDTO where toJSON = encodeFlat
instance FromJSON AvailableSlotDTO where parseJSON = decodeFlat "AvailableSlot"
instance ToSchema AvailableSlotDTO where declareNamedSchema = schemaFlat "AvailableSlot"

toDomainAvailableSlot :: AvailableSlotDTO -> AvailableSlot
toDomainAvailableSlot s = AvailableSlot
  { id                  = toDomainSlotId s.id
  , doctorId            = toDomainDoctorId s.doctorId
  , healthcareServiceId = toDomainHealthcareServiceId s.healthcareServiceId
  , start               = s.start
  , duration            = toDomainDuration s.duration
  }

fromDomainAvailableSlot :: AvailableSlot -> AvailableSlotDTO
fromDomainAvailableSlot s = AvailableSlotDTO
  { id                  = fromDomainSlotId s.id
  , doctorId            = fromDomainDoctorId s.doctorId
  , healthcareServiceId = fromDomainHealthcareServiceId s.healthcareServiceId
  , start               = s.start
  , duration            = fromDomainDuration s.duration
  }

data DoctorCalendarEntryDTO
  = SlotDTO        AvailableSlotDTO
  | AppointmentDTO AppointedIntakeRequestDTO
  deriving (Show, Eq)

instance Flat DoctorCalendarEntryDTO where
  flatten (SlotDTO s)        = tagKey "slot" : flatten s
  flatten (AppointmentDTO a) = tagKey "appointment" : flatten a
  unflatten o = readTag o >>= \t -> case t of
    "slot"        -> SlotDTO <$> unflatten o
    "appointment" -> AppointmentDTO <$> unflatten o
    _             -> unknownTag "DoctorCalendarEntry" t
  shape _ = sumShape
    [ ("slot", shape (Proxy @AvailableSlotDTO))
    , ("appointment", shape (Proxy @AppointedIntakeRequestDTO))
    ]

instance ToJSON DoctorCalendarEntryDTO where toJSON = encodeFlat
instance FromJSON DoctorCalendarEntryDTO where parseJSON = decodeFlat "DoctorCalendarEntry"
instance ToSchema DoctorCalendarEntryDTO where declareNamedSchema = schemaFlat "DoctorCalendarEntry"

toDomainDoctorCalendarEntry :: DoctorCalendarEntryDTO -> DoctorCalendarEntry
toDomainDoctorCalendarEntry (SlotDTO s)        = Slot (toDomainAvailableSlot s)
toDomainDoctorCalendarEntry (AppointmentDTO a) = Appointment (toDomainAppointedIntakeRequest a)

fromDomainDoctorCalendarEntry :: DoctorCalendarEntry -> DoctorCalendarEntryDTO
fromDomainDoctorCalendarEntry (Slot s)        = SlotDTO (fromDomainAvailableSlot s)
fromDomainDoctorCalendarEntry (Appointment a) = AppointmentDTO (fromDomainAppointedIntakeRequest a)

-- ═══════════════════════════════════════════════════════════════════════════
-- REQUEST BODIES
-- One per Service function that takes caller-supplied facts, holding exactly
-- those facts, keyed by the Domain.hs field each lands in. Times the server
-- records are supplied by the handler, never here.
-- ═══════════════════════════════════════════════════════════════════════════

-- createDoctor
newtype CreateDoctorRequest = CreateDoctorRequest
  { name :: Text
  }
  deriving (Show, Eq)

instance Flat CreateDoctorRequest where
  flatten r = ["name" .= r.name]
  unflatten o = CreateDoctorRequest <$> o .: "name"
  shape _ = field "name" (Proxy @Text)

instance ToJSON CreateDoctorRequest where toJSON = encodeFlat
instance FromJSON CreateDoctorRequest where parseJSON = decodeFlat "CreateDoctorRequest"
instance ToSchema CreateDoctorRequest where declareNamedSchema = schemaFlat "CreateDoctorRequest"

-- createPatient
newtype CreatePatientRequest = CreatePatientRequest
  { name :: Text
  }
  deriving (Show, Eq)

instance Flat CreatePatientRequest where
  flatten r = ["name" .= r.name]
  unflatten o = CreatePatientRequest <$> o .: "name"
  shape _ = field "name" (Proxy @Text)

instance ToJSON CreatePatientRequest where toJSON = encodeFlat
instance FromJSON CreatePatientRequest where parseJSON = decodeFlat "CreatePatientRequest"
instance ToSchema CreatePatientRequest where declareNamedSchema = schemaFlat "CreatePatientRequest"

-- createHealthcareService
data CreateHealthcareServiceRequest = CreateHealthcareServiceRequest
  { name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

instance Flat CreateHealthcareServiceRequest where
  flatten r = ["name" .= r.name, "duration" .= r.duration]
  unflatten o = CreateHealthcareServiceRequest <$> o .: "name" <*> o .: "duration"
  shape _ = mconcat <$> sequence
    [ field "name" (Proxy @Text), field "duration" (Proxy @DurationDTO) ]

instance ToJSON CreateHealthcareServiceRequest where toJSON = encodeFlat
instance FromJSON CreateHealthcareServiceRequest where
  parseJSON = decodeFlat "CreateHealthcareServiceRequest"
instance ToSchema CreateHealthcareServiceRequest where
  declareNamedSchema = schemaFlat "CreateHealthcareServiceRequest"

-- submitIntakeRequest (createdAt is supplied by the handler)
data SubmitIntakeRequestRequest = SubmitIntakeRequestRequest
  { patientId :: PatientIdDTO
  , narrative :: Text
  }
  deriving (Show, Eq)

instance Flat SubmitIntakeRequestRequest where
  flatten r = ["patientId" .= r.patientId, "narrative" .= r.narrative]
  unflatten o = SubmitIntakeRequestRequest <$> o .: "patientId" <*> o .: "narrative"
  shape _ = mconcat <$> sequence
    [ field "patientId" (Proxy @PatientIdDTO), field "narrative" (Proxy @Text) ]

instance ToJSON SubmitIntakeRequestRequest where toJSON = encodeFlat
instance FromJSON SubmitIntakeRequestRequest where parseJSON = decodeFlat "SubmitIntakeRequestRequest"
instance ToSchema SubmitIntakeRequestRequest where
  declareNamedSchema = schemaFlat "SubmitIntakeRequestRequest"

-- acceptSubmittedIntakeRequest (triagedAt is supplied by the handler)
data AcceptSubmittedIntakeRequestRequest = AcceptSubmittedIntakeRequestRequest
  { healthcareServiceId :: HealthcareServiceIdDTO
  , priority            :: IntakeRequestPriorityDTO
  , doctorRequirement   :: DoctorRequirementDTO
  }
  deriving (Show, Eq)

instance Flat AcceptSubmittedIntakeRequestRequest where
  flatten r =
    [ "healthcareServiceId" .= r.healthcareServiceId, "priority" .= r.priority
    , "doctorRequirement" .= r.doctorRequirement ]
  unflatten o = AcceptSubmittedIntakeRequestRequest
    <$> o .: "healthcareServiceId" <*> o .: "priority" <*> o .: "doctorRequirement"
  shape _ = mconcat <$> sequence
    [ field "healthcareServiceId" (Proxy @HealthcareServiceIdDTO)
    , field "priority" (Proxy @IntakeRequestPriorityDTO)
    , field "doctorRequirement" (Proxy @DoctorRequirementDTO)
    ]

instance ToJSON AcceptSubmittedIntakeRequestRequest where toJSON = encodeFlat
instance FromJSON AcceptSubmittedIntakeRequestRequest where
  parseJSON = decodeFlat "AcceptSubmittedIntakeRequestRequest"
instance ToSchema AcceptSubmittedIntakeRequestRequest where
  declareNamedSchema = schemaFlat "AcceptSubmittedIntakeRequestRequest"

-- rejectSubmittedIntakeRequest (rejectedAt is supplied by the handler)
newtype RejectSubmittedIntakeRequestRequest = RejectSubmittedIntakeRequestRequest
  { rejectionReason :: Text
  }
  deriving (Show, Eq)

instance Flat RejectSubmittedIntakeRequestRequest where
  flatten r = ["rejectionReason" .= r.rejectionReason]
  unflatten o = RejectSubmittedIntakeRequestRequest <$> o .: "rejectionReason"
  shape _ = field "rejectionReason" (Proxy @Text)

instance ToJSON RejectSubmittedIntakeRequestRequest where toJSON = encodeFlat
instance FromJSON RejectSubmittedIntakeRequestRequest where
  parseJSON = decodeFlat "RejectSubmittedIntakeRequestRequest"
instance ToSchema RejectSubmittedIntakeRequestRequest where
  declareNamedSchema = schemaFlat "RejectSubmittedIntakeRequestRequest"

-- matchAcceptedIntakeRequestToSlot: the slot's id lands in no field, so it
-- takes its ID type's name.
newtype MatchAcceptedIntakeRequestToSlotRequest = MatchAcceptedIntakeRequestToSlotRequest
  { slotId :: SlotIdDTO
  }
  deriving (Show, Eq)

instance Flat MatchAcceptedIntakeRequestToSlotRequest where
  flatten r = ["slotId" .= r.slotId]
  unflatten o = MatchAcceptedIntakeRequestToSlotRequest <$> o .: "slotId"
  shape _ = field "slotId" (Proxy @SlotIdDTO)

instance ToJSON MatchAcceptedIntakeRequestToSlotRequest where toJSON = encodeFlat
instance FromJSON MatchAcceptedIntakeRequestToSlotRequest where
  parseJSON = decodeFlat "MatchAcceptedIntakeRequestToSlotRequest"
instance ToSchema MatchAcceptedIntakeRequestToSlotRequest where
  declareNamedSchema = schemaFlat "MatchAcceptedIntakeRequestToSlotRequest"

-- withdrawIntakeRequest (withdrawnAt is supplied by the handler)
newtype WithdrawIntakeRequestRequest = WithdrawIntakeRequestRequest
  { withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

instance Flat WithdrawIntakeRequestRequest where
  flatten r = ["withdrawalNote" .= r.withdrawalNote]
  unflatten o = WithdrawIntakeRequestRequest <$> o .: "withdrawalNote"
  shape _ = maybeField "withdrawalNote" (Proxy @Text)

instance ToJSON WithdrawIntakeRequestRequest where toJSON = encodeFlat
instance FromJSON WithdrawIntakeRequestRequest where
  parseJSON = decodeFlat "WithdrawIntakeRequestRequest"
instance ToSchema WithdrawIntakeRequestRequest where
  declareNamedSchema = schemaFlat "WithdrawIntakeRequestRequest"

-- closeAppointedIntakeRequest: the caller supplies the CloseReason whole,
-- except the cancellation's time, which the server records.
newtype CloseAppointedIntakeRequestRequest = CloseAppointedIntakeRequestRequest
  { closeReason :: CloseReasonRequest
  }
  deriving (Show, Eq)

instance Flat CloseAppointedIntakeRequestRequest where
  flatten r = ["closeReason" .= r.closeReason]
  unflatten o = CloseAppointedIntakeRequestRequest <$> o .: "closeReason"
  shape _ = field "closeReason" (Proxy @CloseReasonRequest)

instance ToJSON CloseAppointedIntakeRequestRequest where toJSON = encodeFlat
instance FromJSON CloseAppointedIntakeRequestRequest where
  parseJSON = decodeFlat "CloseAppointedIntakeRequestRequest"
instance ToSchema CloseAppointedIntakeRequestRequest where
  declareNamedSchema = schemaFlat "CloseAppointedIntakeRequestRequest"

-- CloseReason without cancelledAt.
data CloseReasonRequest
  = CompletedRequest
  | CancelledRequest CancellationRequest
  | NoShowRequest    AbsenceDTO
  deriving (Show, Eq)

instance Flat CloseReasonRequest where
  flatten CompletedRequest     = [tagKey "completed"]
  flatten (CancelledRequest c) = tagKey "cancelled" : flatten c
  flatten (NoShowRequest a)    = tagKey "noShow" : flatten a
  unflatten o = readTag o >>= \t -> case t of
    "completed" -> pure CompletedRequest
    "cancelled" -> CancelledRequest <$> unflatten o
    "noShow"    -> NoShowRequest <$> unflatten o
    _           -> unknownTag "CloseReasonRequest" t
  shape _ = sumShape
    [ ("completed", pure mempty)
    , ("cancelled", shape (Proxy @CancellationRequest))
    , ("noShow", shape (Proxy @AbsenceDTO))
    ]

instance ToJSON CloseReasonRequest where toJSON = encodeFlat
instance FromJSON CloseReasonRequest where parseJSON = decodeFlat "CloseReasonRequest"
instance ToSchema CloseReasonRequest where declareNamedSchema = schemaFlat "CloseReasonRequest"

-- Cancellation without cancelledAt.
data CancellationRequest = CancellationRequest
  { cancelledBy      :: AppointmentPartyDTO
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

instance Flat CancellationRequest where
  flatten c = ["cancelledBy" .= c.cancelledBy, "cancellationNote" .= c.cancellationNote]
  unflatten o = CancellationRequest <$> o .: "cancelledBy" <*> o .: "cancellationNote"
  shape _ = mconcat <$> sequence
    [ field "cancelledBy" (Proxy @AppointmentPartyDTO)
    , maybeField "cancellationNote" (Proxy @Text)
    ]

instance ToJSON CancellationRequest where toJSON = encodeFlat
instance FromJSON CancellationRequest where parseJSON = decodeFlat "CancellationRequest"
instance ToSchema CancellationRequest where declareNamedSchema = schemaFlat "CancellationRequest"

-- The CloseReason, once the handler has the time the cancellation was
-- recorded.
toDomainCloseReasonRequest :: UTCTime -> CloseReasonRequest -> CloseReason
toDomainCloseReasonRequest _ CompletedRequest = Completed
toDomainCloseReasonRequest cancelledAt (CancelledRequest c) = Cancelled Cancellation
  { cancelledBy      = toDomainAppointmentParty c.cancelledBy
  , cancelledAt
  , cancellationNote = c.cancellationNote
  }
toDomainCloseReasonRequest _ (NoShowRequest a) = NoShow (toDomainAbsence a)

-- createAvailableSlot
data CreateAvailableSlotRequest = CreateAvailableSlotRequest
  { doctorId            :: DoctorIdDTO
  , healthcareServiceId :: HealthcareServiceIdDTO
  , start               :: UTCTime
  }
  deriving (Show, Eq)

instance Flat CreateAvailableSlotRequest where
  flatten r =
    [ "doctorId" .= r.doctorId, "healthcareServiceId" .= r.healthcareServiceId
    , "start" .= r.start ]
  unflatten o = CreateAvailableSlotRequest
    <$> o .: "doctorId" <*> o .: "healthcareServiceId" <*> o .: "start"
  shape _ = mconcat <$> sequence
    [ field "doctorId" (Proxy @DoctorIdDTO)
    , field "healthcareServiceId" (Proxy @HealthcareServiceIdDTO)
    , field "start" (Proxy @UTCTime)
    ]

instance ToJSON CreateAvailableSlotRequest where toJSON = encodeFlat
instance FromJSON CreateAvailableSlotRequest where
  parseJSON = decodeFlat "CreateAvailableSlotRequest"
instance ToSchema CreateAvailableSlotRequest where
  declareNamedSchema = schemaFlat "CreateAvailableSlotRequest"
