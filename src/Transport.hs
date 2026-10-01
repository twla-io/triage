{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}

-- Derived from src/Domain.hs and src/Service.hs (triage-api-codegen).
-- The wire format: one DTO per Domain.hs type that crosses the wire, one
-- request type per Service function with caller-supplied facts, and one
-- answer type per Service function. Every schema states exactly what the
-- type's ToJSON produces.
module Transport
  ( -- ── IDs ──────────────────────────────────────────────────────────────
    DoctorIdDTO (..)
  , PatientIdDTO (..)
  , HealthcareServiceIdDTO (..)
  , IntakeRequestIdDTO (..)
  , SlotIdDTO (..)
  , toDomainDoctorId, fromDomainDoctorId
  , toDomainPatientId, fromDomainPatientId
  , toDomainHealthcareServiceId, fromDomainHealthcareServiceId
  , toDomainIntakeRequestId, fromDomainIntakeRequestId
  , toDomainSlotId, fromDomainSlotId

    -- ── DTOs ─────────────────────────────────────────────────────────────
  , DurationDTO (..)
  , toDomainDuration, fromDomainDuration
  , DoctorDTO (..)
  , toDomainDoctor, fromDomainDoctor
  , PatientDTO (..)
  , toDomainPatient, fromDomainPatient
  , HealthcareServiceDTO (..)
  , toDomainHealthcareService, fromDomainHealthcareService
  , DoctorRequirementDTO (..)
  , toDomainDoctorRequirement, fromDomainDoctorRequirement
  , MustBeSeenByDTO (..)
  , toDomainMustBeSeenBy, fromDomainMustBeSeenBy
  , RoutineWindowDTO
  , toDomainRoutineWindow, fromDomainRoutineWindow
  , RoutineDueDTO (..)
  , toDomainRoutineDue, fromDomainRoutineDue
  , IntakeRequestPriorityDTO (..)
  , toDomainIntakeRequestPriority, fromDomainIntakeRequestPriority
  , SubmittedIntakeRequestDTO (..)
  , toDomainSubmittedIntakeRequest, fromDomainSubmittedIntakeRequest
  , RejectedIntakeRequestDTO (..)
  , toDomainRejectedIntakeRequest, fromDomainRejectedIntakeRequest
  , TriagedIntakeRequestDTO (..)
  , toDomainTriagedIntakeRequest, fromDomainTriagedIntakeRequest
  , AppointedIntakeRequestDTO (..)
  , toDomainAppointedIntakeRequest, fromDomainAppointedIntakeRequest
  , WithdrawnIntakeRequestDTO (..)
  , toDomainWithdrawnIntakeRequest, fromDomainWithdrawnIntakeRequest
  , WithdrawnFromDTO (..)
  , toDomainWithdrawnFrom, fromDomainWithdrawnFrom
  , StaleIntakeRequestDTO (..)
  , toDomainStaleIntakeRequest, fromDomainStaleIntakeRequest
  , AppointmentPartyDTO (..)
  , toDomainAppointmentParty, fromDomainAppointmentParty
  , CancellationDTO (..)
  , toDomainCancellation, fromDomainCancellation
  , AbsenceDTO (..)
  , toDomainAbsence, fromDomainAbsence
  , CloseReasonDTO (..)
  , toDomainCloseReason, fromDomainCloseReason
  , ClosedIntakeRequestDTO (..)
  , toDomainClosedIntakeRequest, fromDomainClosedIntakeRequest
  , IntakeRequestDTO (..)
  , toDomainIntakeRequest, fromDomainIntakeRequest
  , AvailableSlotDTO (..)
  , toDomainAvailableSlot, fromDomainAvailableSlot
  , DoctorCalendarEntryDTO (..)
  , toDomainDoctorCalendarEntry, fromDomainDoctorCalendarEntry

    -- ── Requests ─────────────────────────────────────────────────────────
  , CreateDoctorRequest (..)
  , CreatePatientRequest (..)
  , CreateHealthcareServiceRequest (..)
  , SubmitIntakeRequestRequest (..)
  , CreateAvailableSlotRequest (..)
  , AcceptSubmittedIntakeRequestRequest (..)
  , RejectSubmittedIntakeRequestRequest (..)
  , MatchAcceptedIntakeRequestToSlotRequest (..)
  , WithdrawIntakeRequestRequest (..)
  , CloseAppointedIntakeRequestRequest (..)
  , CancellationRequest (..)
  , toDomainCancellationRequest
  , CloseReasonRequest (..)
  , toDomainCloseReasonRequest

    -- ── Answers ──────────────────────────────────────────────────────────
  , Envelope (..)
  , CreateDoctorAnswer (..)
  , CreatePatientAnswer (..)
  , CreateHealthcareServiceAnswer (..)
  , SubmitIntakeRequestAnswer (..)
  , CreateAvailableSlotAnswer (..)
  , AcceptSubmittedIntakeRequestAnswer (..)
  , RejectSubmittedIntakeRequestAnswer (..)
  , MatchAcceptedIntakeRequestToSlotAnswer (..)
  , WithdrawIntakeRequestAnswer (..)
  , MarkAcceptedIntakeRequestStaleAnswer (..)
  , CloseAppointedIntakeRequestAnswer (..)
  , MatchAvailableSlotByPriorityAnswer (..)
  , FetchDoctorAnswer (..)
  , FetchDoctorsAnswer (..)
  , FetchPatientAnswer (..)
  , FetchPatientsAnswer (..)
  , FetchHealthcareServiceAnswer (..)
  , FetchHealthcareServicesAnswer (..)
  , FetchAvailableSlotAnswer (..)
  , FetchIntakeRequestAnswer (..)
  , FetchSubmittedIntakeRequestsAnswer (..)
  , FetchAcceptedIntakeRequestsAnswer (..)
  , FetchAppointedIntakeRequestsAnswer (..)
  , FetchRejectedIntakeRequestsByRejectedAtAnswer (..)
  , FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer (..)
  , FetchStaleIntakeRequestsByStaleAtAnswer (..)
  , FetchClosedIntakeRequestsByStartAnswer (..)
  , FetchDoctorCalendarEntriesOverlappingAnswer (..)
  ) where

import Control.Lens            ((&), (.~), (?~))
import Control.Monad           (forM, unless)
import Data.Aeson
  ( FromJSON (..), Object, ToJSON (..), Value (..), object, withObject, (.:), (.=) )
import Data.Aeson.Types        (Pair, Parser)
import Data.OpenApi
  ( Definitions, Discriminator (..), NamedSchema (..), OpenApiItems (..), OpenApiType (..)
  , Reference (..), Referenced (..), Schema, ToParamSchema (..), ToSchema (..), declareSchemaRef )
import Data.OpenApi.Declare    (Declare, declare)
import Data.Char               (toLower, toUpper)
import Data.Maybe              (fromMaybe)
import Data.Proxy              (Proxy (..))
import Data.Text               (Text)
import Data.Time               (UTCTime)
import Data.UUID               (UUID)
import Web.HttpApiData         (FromHttpApiData (..))

import qualified Data.Aeson.Key             as Key
import qualified Data.Aeson.KeyMap          as KeyMap
import qualified Data.HashMap.Strict.InsOrd as InsOrd
import qualified Data.OpenApi               as O
import qualified Data.Text                  as T

import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

type Decl = Declare (Definitions Schema)

type Props = [(Text, Referenced Schema)]

-- An object with exactly the keys its value encodes to: an unknown key is a
-- parse failure.
strictObject :: String -> (Object -> Parser a) -> (a -> [Pair]) -> Value -> Parser a
strictObject what parse encode = withObject what $ \o -> do
  a <- parse o
  let expected = map fst (encode a)
      unknown  = filter (`notElem` expected) (KeyMap.keys o)
  unless (null unknown) $
    fail ("unknown key(s) in " ++ what ++ ": " ++ show (map Key.toText unknown))
  pure a

tagOf :: Object -> Parser Text
tagOf o = o .: "type"

unknownTag :: String -> Text -> Parser a
unknownTag what tag = fail ("unknown " ++ what ++ " type: " ++ T.unpack tag)

typed :: Text -> [Pair] -> [Pair]
typed tag pairs = ("type" .= tag) : pairs

lowerFirst :: Text -> Text
lowerFirst t = maybe t (\(c, rest) -> T.cons (toLower c) rest) (T.uncons t)

upperFirst :: Text -> Text
upperFirst t = maybe t (\(c, rest) -> T.cons (toUpper c) rest) (T.uncons t)

-- ── Schemas ─────────────────────────────────────────────────────────────────

objectSchema :: Props -> Schema
objectSchema props = mempty
  & O.type_      ?~ OpenApiObject
  & O.properties .~ InsOrd.fromList props
  & O.required   .~ map fst props

enumOf :: [Text] -> Referenced Schema
enumOf tags = Inline $ mempty
  & O.type_ ?~ OpenApiString
  & O.enum_ ?~ map String tags

stringS :: Referenced Schema
stringS = Inline (mempty & O.type_ ?~ OpenApiString)

nullableStringS :: Referenced Schema
nullableStringS = Inline (mempty & O.type_ ?~ OpenApiString & O.nullable ?~ True)

timeS :: Referenced Schema
timeS = Inline (mempty & O.type_ ?~ OpenApiString & O.format ?~ "date-time")

uuidSchema :: Schema
uuidSchema = mempty & O.type_ ?~ OpenApiString & O.format ?~ "uuid"

nullS :: Referenced Schema
nullS = Inline (mempty & O.nullable ?~ True & O.enum_ ?~ [Null])

arrayOf :: Referenced Schema -> Referenced Schema
arrayOf r = Inline (mempty & O.type_ ?~ OpenApiArray & O.items ?~ OpenApiItemsObject r)

ref :: forall a. ToSchema a => Decl (Referenced Schema)
ref = declareSchemaRef (Proxy @a)

field :: Text -> Decl (Referenced Schema) -> Decl (Text, Referenced Schema)
field key = fmap (key,)

plain :: Text -> Referenced Schema -> Decl (Text, Referenced Schema)
plain key s = pure (key, s)

declareNamed :: Text -> Schema -> Decl (Referenced Schema)
declareNamed schemaName s = do
  declare (InsOrd.singleton schemaName s)
  pure (Ref (Reference schemaName))

-- A discriminator maps each tag to its case's schema: tags are not schema names.
schemaRef :: Text -> Text
schemaRef schemaName = "#/components/schemas/" <> schemaName

-- A sum type: one named schema per case, <Type><Constructor>.
sumSchema :: Text -> [(Text, Decl Props)] -> Decl NamedSchema
sumSchema ty cases = do
  refs <- forM cases $ \(ctor, propsD) -> do
    props <- propsD
    declareNamed (ty <> ctor) (objectSchema (("type", enumOf [lowerFirst ctor]) : props))
  pure . NamedSchema (Just ty) $ mempty
    & O.oneOf         ?~ refs
    & O.discriminator ?~ Discriminator "type"
        (InsOrd.fromList [ (lowerFirst ctor, schemaRef (ty <> ctor)) | (ctor, _) <- cases ])

-- An enumeration: one object whose type is an enum of its constructors.
enumerationSchema :: Text -> [Text] -> Decl NamedSchema
enumerationSchema ty ctors =
  pure (NamedSchema (Just ty) (objectSchema [("type", enumOf (map lowerFirst ctors))]))

recordSchema :: Text -> Decl Props -> Decl NamedSchema
recordSchema ty propsD = NamedSchema (Just ty) . objectSchema <$> propsD

-- ═══════════════════════════════════════════════════════════════════════════
-- IDS — plain UUID strings, each ID type its own named schema
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorIdDTO = DoctorIdDTO UUID deriving (Show, Eq)
newtype PatientIdDTO = PatientIdDTO UUID deriving (Show, Eq)
newtype HealthcareServiceIdDTO = HealthcareServiceIdDTO UUID deriving (Show, Eq)
newtype IntakeRequestIdDTO = IntakeRequestIdDTO UUID deriving (Show, Eq)
newtype SlotIdDTO = SlotIdDTO UUID deriving (Show, Eq)

instance ToJSON DoctorIdDTO where toJSON (DoctorIdDTO u) = toJSON u
instance FromJSON DoctorIdDTO where parseJSON = fmap DoctorIdDTO . parseJSON
instance ToSchema DoctorIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "DoctorId") uuidSchema)
instance ToParamSchema DoctorIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData DoctorIdDTO where parseUrlPiece = fmap DoctorIdDTO . parseUrlPiece

instance ToJSON PatientIdDTO where toJSON (PatientIdDTO u) = toJSON u
instance FromJSON PatientIdDTO where parseJSON = fmap PatientIdDTO . parseJSON
instance ToSchema PatientIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "PatientId") uuidSchema)
instance ToParamSchema PatientIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData PatientIdDTO where parseUrlPiece = fmap PatientIdDTO . parseUrlPiece

instance ToJSON HealthcareServiceIdDTO where toJSON (HealthcareServiceIdDTO u) = toJSON u
instance FromJSON HealthcareServiceIdDTO where parseJSON = fmap HealthcareServiceIdDTO . parseJSON
instance ToSchema HealthcareServiceIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "HealthcareServiceId") uuidSchema)
instance ToParamSchema HealthcareServiceIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData HealthcareServiceIdDTO where
  parseUrlPiece = fmap HealthcareServiceIdDTO . parseUrlPiece

instance ToJSON IntakeRequestIdDTO where toJSON (IntakeRequestIdDTO u) = toJSON u
instance FromJSON IntakeRequestIdDTO where parseJSON = fmap IntakeRequestIdDTO . parseJSON
instance ToSchema IntakeRequestIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "IntakeRequestId") uuidSchema)
instance ToParamSchema IntakeRequestIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData IntakeRequestIdDTO where
  parseUrlPiece = fmap IntakeRequestIdDTO . parseUrlPiece

instance ToJSON SlotIdDTO where toJSON (SlotIdDTO u) = toJSON u
instance FromJSON SlotIdDTO where parseJSON = fmap SlotIdDTO . parseJSON
instance ToSchema SlotIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "SlotId") uuidSchema)
instance ToParamSchema SlotIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData SlotIdDTO where parseUrlPiece = fmap SlotIdDTO . parseUrlPiece

toDomainDoctorId :: DoctorIdDTO -> DoctorId
toDomainDoctorId (DoctorIdDTO u) = DoctorId u

fromDomainDoctorId :: DoctorId -> DoctorIdDTO
fromDomainDoctorId (DoctorId u) = DoctorIdDTO u

toDomainPatientId :: PatientIdDTO -> PatientId
toDomainPatientId (PatientIdDTO u) = PatientId u

fromDomainPatientId :: PatientId -> PatientIdDTO
fromDomainPatientId (PatientId u) = PatientIdDTO u

toDomainHealthcareServiceId :: HealthcareServiceIdDTO -> HealthcareServiceId
toDomainHealthcareServiceId (HealthcareServiceIdDTO u) = HealthcareServiceId u

fromDomainHealthcareServiceId :: HealthcareServiceId -> HealthcareServiceIdDTO
fromDomainHealthcareServiceId (HealthcareServiceId u) = HealthcareServiceIdDTO u

toDomainIntakeRequestId :: IntakeRequestIdDTO -> IntakeRequestId
toDomainIntakeRequestId (IntakeRequestIdDTO u) = IntakeRequestId u

fromDomainIntakeRequestId :: IntakeRequestId -> IntakeRequestIdDTO
fromDomainIntakeRequestId (IntakeRequestId u) = IntakeRequestIdDTO u

toDomainSlotId :: SlotIdDTO -> SlotId
toDomainSlotId (SlotIdDTO u) = SlotId u

fromDomainSlotId :: SlotId -> SlotIdDTO
fromDomainSlotId (SlotId u) = SlotIdDTO u

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION — enumeration
-- ═══════════════════════════════════════════════════════════════════════════

data DurationDTO
  = DurationQuarterOfAnHour
  | DurationHalfAnHour
  | DurationOneHour
  deriving (Show, Eq)

durationPairs :: DurationDTO -> [Pair]
durationPairs = \case
  DurationQuarterOfAnHour -> typed "quarterOfAnHour" []
  DurationHalfAnHour      -> typed "halfAnHour" []
  DurationOneHour         -> typed "oneHour" []

parseDuration :: Object -> Parser DurationDTO
parseDuration o = tagOf o >>= \case
  "quarterOfAnHour" -> pure DurationQuarterOfAnHour
  "halfAnHour"      -> pure DurationHalfAnHour
  "oneHour"         -> pure DurationOneHour
  tag               -> unknownTag "Duration" tag

instance ToJSON DurationDTO where toJSON = object . durationPairs
instance FromJSON DurationDTO where parseJSON = strictObject "Duration" parseDuration durationPairs
instance ToSchema DurationDTO where
  declareNamedSchema _ = enumerationSchema "Duration" ["QuarterOfAnHour", "HalfAnHour", "OneHour"]

toDomainDuration :: DurationDTO -> Duration
toDomainDuration = \case
  DurationQuarterOfAnHour -> QuarterOfAnHour
  DurationHalfAnHour      -> HalfAnHour
  DurationOneHour         -> OneHour

fromDomainDuration :: Duration -> DurationDTO
fromDomainDuration = \case
  QuarterOfAnHour -> DurationQuarterOfAnHour
  HalfAnHour      -> DurationHalfAnHour
  OneHour         -> DurationOneHour

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT / HEALTHCARE SERVICE
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorDTO = DoctorDTO
  { id   :: DoctorIdDTO
  , name :: Text
  }
  deriving (Show, Eq)

doctorPairs :: DoctorDTO -> [Pair]
doctorPairs d = ["id" .= d.id, "name" .= d.name]

parseDoctor :: Object -> Parser DoctorDTO
parseDoctor o = DoctorDTO <$> o .: "id" <*> o .: "name"

doctorProps :: Decl Props
doctorProps = sequence [field "id" (ref @DoctorIdDTO), plain "name" stringS]

instance ToJSON DoctorDTO where toJSON = object . doctorPairs
instance FromJSON DoctorDTO where parseJSON = strictObject "Doctor" parseDoctor doctorPairs
instance ToSchema DoctorDTO where declareNamedSchema _ = recordSchema "Doctor" doctorProps

toDomainDoctor :: DoctorDTO -> Doctor
toDomainDoctor d = Doctor { id = toDomainDoctorId d.id, name = d.name }

fromDomainDoctor :: Doctor -> DoctorDTO
fromDomainDoctor d = DoctorDTO { id = fromDomainDoctorId d.id, name = d.name }

data PatientDTO = PatientDTO
  { id   :: PatientIdDTO
  , name :: Text
  }
  deriving (Show, Eq)

patientPairs :: PatientDTO -> [Pair]
patientPairs p = ["id" .= p.id, "name" .= p.name]

parsePatient :: Object -> Parser PatientDTO
parsePatient o = PatientDTO <$> o .: "id" <*> o .: "name"

patientProps :: Decl Props
patientProps = sequence [field "id" (ref @PatientIdDTO), plain "name" stringS]

instance ToJSON PatientDTO where toJSON = object . patientPairs
instance FromJSON PatientDTO where parseJSON = strictObject "Patient" parsePatient patientPairs
instance ToSchema PatientDTO where declareNamedSchema _ = recordSchema "Patient" patientProps

toDomainPatient :: PatientDTO -> Patient
toDomainPatient p = Patient { id = toDomainPatientId p.id, name = p.name }

fromDomainPatient :: Patient -> PatientDTO
fromDomainPatient p = PatientDTO { id = fromDomainPatientId p.id, name = p.name }

data HealthcareServiceDTO = HealthcareServiceDTO
  { id       :: HealthcareServiceIdDTO
  , name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

healthcareServicePairs :: HealthcareServiceDTO -> [Pair]
healthcareServicePairs s = ["id" .= s.id, "name" .= s.name, "duration" .= s.duration]

parseHealthcareService :: Object -> Parser HealthcareServiceDTO
parseHealthcareService o =
  HealthcareServiceDTO <$> o .: "id" <*> o .: "name" <*> o .: "duration"

healthcareServiceProps :: Decl Props
healthcareServiceProps = sequence
  [ field "id" (ref @HealthcareServiceIdDTO)
  , plain "name" stringS
  , field "duration" (ref @DurationDTO)
  ]

instance ToJSON HealthcareServiceDTO where toJSON = object . healthcareServicePairs
instance FromJSON HealthcareServiceDTO where
  parseJSON = strictObject "HealthcareService" parseHealthcareService healthcareServicePairs
instance ToSchema HealthcareServiceDTO where
  declareNamedSchema _ = recordSchema "HealthcareService" healthcareServiceProps

toDomainHealthcareService :: HealthcareServiceDTO -> HealthcareService
toDomainHealthcareService s = HealthcareService
  { id = toDomainHealthcareServiceId s.id, name = s.name, duration = toDomainDuration s.duration }

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceDTO
fromDomainHealthcareService s = HealthcareServiceDTO
  { id = fromDomainHealthcareServiceId s.id, name = s.name, duration = fromDomainDuration s.duration }

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR REQUIREMENT
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorRequirementDTO
  = DoctorRequirementAnyDoctor
  | DoctorRequirementSpecificDoctor DoctorIdDTO
  deriving (Show, Eq)

doctorRequirementPairs :: DoctorRequirementDTO -> [Pair]
doctorRequirementPairs = \case
  DoctorRequirementAnyDoctor        -> typed "anyDoctor" []
  DoctorRequirementSpecificDoctor d -> typed "specificDoctor" ["specificDoctor" .= d]

parseDoctorRequirement :: Object -> Parser DoctorRequirementDTO
parseDoctorRequirement o = tagOf o >>= \case
  "anyDoctor"      -> pure DoctorRequirementAnyDoctor
  "specificDoctor" -> DoctorRequirementSpecificDoctor <$> o .: "specificDoctor"
  tag              -> unknownTag "DoctorRequirement" tag

instance ToJSON DoctorRequirementDTO where toJSON = object . doctorRequirementPairs
instance FromJSON DoctorRequirementDTO where
  parseJSON = strictObject "DoctorRequirement" parseDoctorRequirement doctorRequirementPairs
instance ToSchema DoctorRequirementDTO where
  declareNamedSchema _ = sumSchema "DoctorRequirement"
    [ ("AnyDoctor", pure [])
    , ("SpecificDoctor", sequence [field "specificDoctor" (ref @DoctorIdDTO)])
    ]

toDomainDoctorRequirement :: DoctorRequirementDTO -> DoctorRequirement
toDomainDoctorRequirement = \case
  DoctorRequirementAnyDoctor        -> AnyDoctor
  DoctorRequirementSpecificDoctor d -> SpecificDoctor (toDomainDoctorId d)

fromDomainDoctorRequirement :: DoctorRequirement -> DoctorRequirementDTO
fromDomainDoctorRequirement = \case
  AnyDoctor        -> DoctorRequirementAnyDoctor
  SpecificDoctor d -> DoctorRequirementSpecificDoctor (fromDomainDoctorId d)

-- ═══════════════════════════════════════════════════════════════════════════
-- PRIORITY / DUE CONSTRAINTS
-- ═══════════════════════════════════════════════════════════════════════════

newtype MustBeSeenByDTO = MustBeSeenByDTO UTCTime
  deriving (Show, Eq)

mustBeSeenByPairs :: MustBeSeenByDTO -> [Pair]
mustBeSeenByPairs (MustBeSeenByDTO t) = ["mustBeSeenBy" .= t]

parseMustBeSeenBy :: Object -> Parser MustBeSeenByDTO
parseMustBeSeenBy o = MustBeSeenByDTO <$> o .: "mustBeSeenBy"

mustBeSeenByProps :: Decl Props
mustBeSeenByProps = sequence [plain "mustBeSeenBy" timeS]

instance ToJSON MustBeSeenByDTO where toJSON = object . mustBeSeenByPairs
instance FromJSON MustBeSeenByDTO where
  parseJSON = strictObject "MustBeSeenBy" parseMustBeSeenBy mustBeSeenByPairs
instance ToSchema MustBeSeenByDTO where
  declareNamedSchema _ = recordSchema "MustBeSeenBy" mustBeSeenByProps

toDomainMustBeSeenBy :: MustBeSeenByDTO -> MustBeSeenBy
toDomainMustBeSeenBy (MustBeSeenByDTO t) = MustBeSeenBy t

fromDomainMustBeSeenBy :: MustBeSeenBy -> MustBeSeenByDTO
fromDomainMustBeSeenBy (MustBeSeenBy t) = MustBeSeenByDTO t

-- Sealed: holds a window mkRoutineWindow accepted; decoding goes through it.
newtype RoutineWindowDTO = RoutineWindowDTO RoutineWindow
  deriving (Show, Eq)

routineWindowPairs :: RoutineWindowDTO -> [Pair]
routineWindowPairs (RoutineWindowDTO w) =
  ["routineNotBefore" .= routineNotBefore w, "routineNotAfter" .= routineNotAfter w]

parseRoutineWindow :: Object -> Parser RoutineWindowDTO
parseRoutineWindow o = do
  notBefore <- o .: "routineNotBefore"
  notAfter  <- o .: "routineNotAfter"
  maybe (fail "routineNotBefore is after routineNotAfter") (pure . RoutineWindowDTO)
    (mkRoutineWindow notBefore notAfter)

routineWindowProps :: Decl Props
routineWindowProps = sequence [plain "routineNotBefore" timeS, plain "routineNotAfter" timeS]

instance ToJSON RoutineWindowDTO where toJSON = object . routineWindowPairs
instance FromJSON RoutineWindowDTO where
  parseJSON = strictObject "RoutineWindow" parseRoutineWindow routineWindowPairs
instance ToSchema RoutineWindowDTO where
  declareNamedSchema _ = recordSchema "RoutineWindow" routineWindowProps

toDomainRoutineWindow :: RoutineWindowDTO -> RoutineWindow
toDomainRoutineWindow (RoutineWindowDTO w) = w

fromDomainRoutineWindow :: RoutineWindow -> RoutineWindowDTO
fromDomainRoutineWindow = RoutineWindowDTO

data RoutineDueDTO
  = RoutineDueRoutineAnytime
  | RoutineDueRoutineNotBefore UTCTime
  | RoutineDueRoutineNotAfter UTCTime
  | RoutineDueRoutineWithin RoutineWindowDTO
  deriving (Show, Eq)

routineDuePairs :: RoutineDueDTO -> [Pair]
routineDuePairs = \case
  RoutineDueRoutineAnytime     -> typed "routineAnytime" []
  RoutineDueRoutineNotBefore t -> typed "routineNotBefore" ["routineNotBefore" .= t]
  RoutineDueRoutineNotAfter t  -> typed "routineNotAfter" ["routineNotAfter" .= t]
  RoutineDueRoutineWithin w    -> typed "routineWithin" (routineWindowPairs w)

parseRoutineDue :: Object -> Parser RoutineDueDTO
parseRoutineDue o = tagOf o >>= \case
  "routineAnytime"   -> pure RoutineDueRoutineAnytime
  "routineNotBefore" -> RoutineDueRoutineNotBefore <$> o .: "routineNotBefore"
  "routineNotAfter"  -> RoutineDueRoutineNotAfter <$> o .: "routineNotAfter"
  "routineWithin"    -> RoutineDueRoutineWithin <$> parseRoutineWindow o
  tag                -> unknownTag "RoutineDue" tag

instance ToJSON RoutineDueDTO where toJSON = object . routineDuePairs
instance FromJSON RoutineDueDTO where
  parseJSON = strictObject "RoutineDue" parseRoutineDue routineDuePairs
instance ToSchema RoutineDueDTO where
  declareNamedSchema _ = sumSchema "RoutineDue"
    [ ("RoutineAnytime", pure [])
    , ("RoutineNotBefore", sequence [plain "routineNotBefore" timeS])
    , ("RoutineNotAfter", sequence [plain "routineNotAfter" timeS])
    , ("RoutineWithin", routineWindowProps)
    ]

toDomainRoutineDue :: RoutineDueDTO -> RoutineDue
toDomainRoutineDue = \case
  RoutineDueRoutineAnytime     -> RoutineAnytime
  RoutineDueRoutineNotBefore t -> RoutineNotBefore t
  RoutineDueRoutineNotAfter t  -> RoutineNotAfter t
  RoutineDueRoutineWithin w    -> RoutineWithin (toDomainRoutineWindow w)

fromDomainRoutineDue :: RoutineDue -> RoutineDueDTO
fromDomainRoutineDue = \case
  RoutineAnytime     -> RoutineDueRoutineAnytime
  RoutineNotBefore t -> RoutineDueRoutineNotBefore t
  RoutineNotAfter t  -> RoutineDueRoutineNotAfter t
  RoutineWithin w    -> RoutineDueRoutineWithin (fromDomainRoutineWindow w)

data IntakeRequestPriorityDTO
  = IntakeRequestPriorityEmergency MustBeSeenByDTO
  | IntakeRequestPriorityUrgent MustBeSeenByDTO
  | IntakeRequestPriorityRoutine RoutineDueDTO
  deriving (Show, Eq)

intakeRequestPriorityPairs :: IntakeRequestPriorityDTO -> [Pair]
intakeRequestPriorityPairs = \case
  IntakeRequestPriorityEmergency m -> typed "emergency" (mustBeSeenByPairs m)
  IntakeRequestPriorityUrgent m    -> typed "urgent" (mustBeSeenByPairs m)
  IntakeRequestPriorityRoutine r   -> typed "routine" ["routine" .= r]

parseIntakeRequestPriority :: Object -> Parser IntakeRequestPriorityDTO
parseIntakeRequestPriority o = tagOf o >>= \case
  "emergency" -> IntakeRequestPriorityEmergency <$> parseMustBeSeenBy o
  "urgent"    -> IntakeRequestPriorityUrgent <$> parseMustBeSeenBy o
  "routine"   -> IntakeRequestPriorityRoutine <$> o .: "routine"
  tag         -> unknownTag "IntakeRequestPriority" tag

instance ToJSON IntakeRequestPriorityDTO where toJSON = object . intakeRequestPriorityPairs
instance FromJSON IntakeRequestPriorityDTO where
  parseJSON = strictObject "IntakeRequestPriority" parseIntakeRequestPriority intakeRequestPriorityPairs
instance ToSchema IntakeRequestPriorityDTO where
  declareNamedSchema _ = sumSchema "IntakeRequestPriority"
    [ ("Emergency", mustBeSeenByProps)
    , ("Urgent", mustBeSeenByProps)
    , ("Routine", sequence [field "routine" (ref @RoutineDueDTO)])
    ]

toDomainIntakeRequestPriority :: IntakeRequestPriorityDTO -> IntakeRequestPriority
toDomainIntakeRequestPriority = \case
  IntakeRequestPriorityEmergency m -> Emergency (toDomainMustBeSeenBy m)
  IntakeRequestPriorityUrgent m    -> Urgent (toDomainMustBeSeenBy m)
  IntakeRequestPriorityRoutine r   -> Routine (toDomainRoutineDue r)

fromDomainIntakeRequestPriority :: IntakeRequestPriority -> IntakeRequestPriorityDTO
fromDomainIntakeRequestPriority = \case
  Emergency m -> IntakeRequestPriorityEmergency (fromDomainMustBeSeenBy m)
  Urgent m    -> IntakeRequestPriorityUrgent (fromDomainMustBeSeenBy m)
  Routine r   -> IntakeRequestPriorityRoutine (fromDomainRoutineDue r)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST STAGES — each stage's object carries every field of the
-- stages it embeds
-- ═══════════════════════════════════════════════════════════════════════════

data SubmittedIntakeRequestDTO = SubmittedIntakeRequestDTO
  { id        :: IntakeRequestIdDTO
  , patientId :: PatientIdDTO
  , narrative :: Text
  , createdAt :: UTCTime
  }
  deriving (Show, Eq)

submittedPairs :: SubmittedIntakeRequestDTO -> [Pair]
submittedPairs s =
  [ "id" .= s.id, "patientId" .= s.patientId, "narrative" .= s.narrative, "createdAt" .= s.createdAt ]

parseSubmitted :: Object -> Parser SubmittedIntakeRequestDTO
parseSubmitted o = SubmittedIntakeRequestDTO
  <$> o .: "id" <*> o .: "patientId" <*> o .: "narrative" <*> o .: "createdAt"

submittedProps :: Decl Props
submittedProps = sequence
  [ field "id" (ref @IntakeRequestIdDTO)
  , field "patientId" (ref @PatientIdDTO)
  , plain "narrative" stringS
  , plain "createdAt" timeS
  ]

instance ToJSON SubmittedIntakeRequestDTO where toJSON = object . submittedPairs
instance FromJSON SubmittedIntakeRequestDTO where
  parseJSON = strictObject "SubmittedIntakeRequest" parseSubmitted submittedPairs
instance ToSchema SubmittedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "SubmittedIntakeRequest" submittedProps

toDomainSubmittedIntakeRequest :: SubmittedIntakeRequestDTO -> SubmittedIntakeRequest
toDomainSubmittedIntakeRequest s = SubmittedIntakeRequest
  { id = toDomainIntakeRequestId s.id
  , patientId = toDomainPatientId s.patientId
  , narrative = s.narrative
  , createdAt = s.createdAt
  }

fromDomainSubmittedIntakeRequest :: SubmittedIntakeRequest -> SubmittedIntakeRequestDTO
fromDomainSubmittedIntakeRequest s = SubmittedIntakeRequestDTO
  { id = fromDomainIntakeRequestId s.id
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

rejectedPairs :: RejectedIntakeRequestDTO -> [Pair]
rejectedPairs r =
  submittedPairs r.submitted ++ ["rejectedAt" .= r.rejectedAt, "rejectionReason" .= r.rejectionReason]

parseRejected :: Object -> Parser RejectedIntakeRequestDTO
parseRejected o = RejectedIntakeRequestDTO
  <$> parseSubmitted o <*> o .: "rejectedAt" <*> o .: "rejectionReason"

rejectedProps :: Decl Props
rejectedProps = (++) <$> submittedProps
  <*> sequence [plain "rejectedAt" timeS, plain "rejectionReason" stringS]

instance ToJSON RejectedIntakeRequestDTO where toJSON = object . rejectedPairs
instance FromJSON RejectedIntakeRequestDTO where
  parseJSON = strictObject "RejectedIntakeRequest" parseRejected rejectedPairs
instance ToSchema RejectedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "RejectedIntakeRequest" rejectedProps

toDomainRejectedIntakeRequest :: RejectedIntakeRequestDTO -> RejectedIntakeRequest
toDomainRejectedIntakeRequest r = RejectedIntakeRequest
  { submitted = toDomainSubmittedIntakeRequest r.submitted
  , rejectedAt = r.rejectedAt
  , rejectionReason = r.rejectionReason
  }

fromDomainRejectedIntakeRequest :: RejectedIntakeRequest -> RejectedIntakeRequestDTO
fromDomainRejectedIntakeRequest r = RejectedIntakeRequestDTO
  { submitted = fromDomainSubmittedIntakeRequest r.submitted
  , rejectedAt = r.rejectedAt
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

triagedPairs :: TriagedIntakeRequestDTO -> [Pair]
triagedPairs t = submittedPairs t.submitted ++
  [ "healthcareServiceId" .= t.healthcareServiceId
  , "priority" .= t.priority
  , "doctorRequirement" .= t.doctorRequirement
  , "triagedAt" .= t.triagedAt
  ]

parseTriaged :: Object -> Parser TriagedIntakeRequestDTO
parseTriaged o = TriagedIntakeRequestDTO
  <$> parseSubmitted o
  <*> o .: "healthcareServiceId"
  <*> o .: "priority"
  <*> o .: "doctorRequirement"
  <*> o .: "triagedAt"

triagedProps :: Decl Props
triagedProps = (++) <$> submittedProps <*> sequence
  [ field "healthcareServiceId" (ref @HealthcareServiceIdDTO)
  , field "priority" (ref @IntakeRequestPriorityDTO)
  , field "doctorRequirement" (ref @DoctorRequirementDTO)
  , plain "triagedAt" timeS
  ]

instance ToJSON TriagedIntakeRequestDTO where toJSON = object . triagedPairs
instance FromJSON TriagedIntakeRequestDTO where
  parseJSON = strictObject "TriagedIntakeRequest" parseTriaged triagedPairs
instance ToSchema TriagedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "TriagedIntakeRequest" triagedProps

toDomainTriagedIntakeRequest :: TriagedIntakeRequestDTO -> TriagedIntakeRequest
toDomainTriagedIntakeRequest t = TriagedIntakeRequest
  { submitted = toDomainSubmittedIntakeRequest t.submitted
  , healthcareServiceId = toDomainHealthcareServiceId t.healthcareServiceId
  , priority = toDomainIntakeRequestPriority t.priority
  , doctorRequirement = toDomainDoctorRequirement t.doctorRequirement
  , triagedAt = t.triagedAt
  }

fromDomainTriagedIntakeRequest :: TriagedIntakeRequest -> TriagedIntakeRequestDTO
fromDomainTriagedIntakeRequest t = TriagedIntakeRequestDTO
  { submitted = fromDomainSubmittedIntakeRequest t.submitted
  , healthcareServiceId = fromDomainHealthcareServiceId t.healthcareServiceId
  , priority = fromDomainIntakeRequestPriority t.priority
  , doctorRequirement = fromDomainDoctorRequirement t.doctorRequirement
  , triagedAt = t.triagedAt
  }

data AppointedIntakeRequestDTO = AppointedIntakeRequestDTO
  { triaged  :: TriagedIntakeRequestDTO
  , doctorId :: DoctorIdDTO
  , start    :: UTCTime
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

appointedPairs :: AppointedIntakeRequestDTO -> [Pair]
appointedPairs a = triagedPairs a.triaged ++
  ["doctorId" .= a.doctorId, "start" .= a.start, "duration" .= a.duration]

parseAppointed :: Object -> Parser AppointedIntakeRequestDTO
parseAppointed o = AppointedIntakeRequestDTO
  <$> parseTriaged o <*> o .: "doctorId" <*> o .: "start" <*> o .: "duration"

appointedProps :: Decl Props
appointedProps = (++) <$> triagedProps <*> sequence
  [ field "doctorId" (ref @DoctorIdDTO)
  , plain "start" timeS
  , field "duration" (ref @DurationDTO)
  ]

instance ToJSON AppointedIntakeRequestDTO where toJSON = object . appointedPairs
instance FromJSON AppointedIntakeRequestDTO where
  parseJSON = strictObject "AppointedIntakeRequest" parseAppointed appointedPairs
instance ToSchema AppointedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "AppointedIntakeRequest" appointedProps

toDomainAppointedIntakeRequest :: AppointedIntakeRequestDTO -> AppointedIntakeRequest
toDomainAppointedIntakeRequest a = AppointedIntakeRequest
  { triaged = toDomainTriagedIntakeRequest a.triaged
  , doctorId = toDomainDoctorId a.doctorId
  , start = a.start
  , duration = toDomainDuration a.duration
  }

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> AppointedIntakeRequestDTO
fromDomainAppointedIntakeRequest a = AppointedIntakeRequestDTO
  { triaged = fromDomainTriagedIntakeRequest a.triaged
  , doctorId = fromDomainDoctorId a.doctorId
  , start = a.start
  , duration = fromDomainDuration a.duration
  }

-- ── Withdrawn ───────────────────────────────────────────────────────────────

-- Standalone, a case object with its stage flattened in. Held in
-- WithdrawnIntakeRequest's withdrawnFrom, its stage joins the enclosing
-- object and withdrawnFrom keeps only {"type": <case>}.
data WithdrawnFromDTO
  = WithdrawnFromFromSubmitted SubmittedIntakeRequestDTO
  | WithdrawnFromFromAccepted TriagedIntakeRequestDTO
  deriving (Show, Eq)

withdrawnFromTag :: WithdrawnFromDTO -> Text
withdrawnFromTag = \case
  WithdrawnFromFromSubmitted _ -> "fromSubmitted"
  WithdrawnFromFromAccepted _  -> "fromAccepted"

withdrawnFromStagePairs :: WithdrawnFromDTO -> [Pair]
withdrawnFromStagePairs = \case
  WithdrawnFromFromSubmitted s -> submittedPairs s
  WithdrawnFromFromAccepted t  -> triagedPairs t

parseWithdrawnFromStage :: Text -> Object -> Parser WithdrawnFromDTO
parseWithdrawnFromStage tag o = case tag of
  "fromSubmitted" -> WithdrawnFromFromSubmitted <$> parseSubmitted o
  "fromAccepted"  -> WithdrawnFromFromAccepted <$> parseTriaged o
  _               -> unknownTag "WithdrawnFrom" tag

withdrawnFromPairs :: WithdrawnFromDTO -> [Pair]
withdrawnFromPairs w = typed (withdrawnFromTag w) (withdrawnFromStagePairs w)

instance ToJSON WithdrawnFromDTO where toJSON = object . withdrawnFromPairs
instance FromJSON WithdrawnFromDTO where
  parseJSON = strictObject "WithdrawnFrom" (\o -> tagOf o >>= (`parseWithdrawnFromStage` o)) withdrawnFromPairs
instance ToSchema WithdrawnFromDTO where
  declareNamedSchema _ = sumSchema "WithdrawnFrom"
    [ ("FromSubmitted", submittedProps)
    , ("FromAccepted", triagedProps)
    ]

toDomainWithdrawnFrom :: WithdrawnFromDTO -> WithdrawnFrom
toDomainWithdrawnFrom = \case
  WithdrawnFromFromSubmitted s -> FromSubmitted (toDomainSubmittedIntakeRequest s)
  WithdrawnFromFromAccepted t  -> FromAccepted (toDomainTriagedIntakeRequest t)

fromDomainWithdrawnFrom :: WithdrawnFrom -> WithdrawnFromDTO
fromDomainWithdrawnFrom = \case
  FromSubmitted s -> WithdrawnFromFromSubmitted (fromDomainSubmittedIntakeRequest s)
  FromAccepted t  -> WithdrawnFromFromAccepted (fromDomainTriagedIntakeRequest t)

data WithdrawnIntakeRequestDTO = WithdrawnIntakeRequestDTO
  { withdrawnFrom  :: WithdrawnFromDTO
  , withdrawnAt    :: UTCTime
  , withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

withdrawnPairs :: WithdrawnIntakeRequestDTO -> [Pair]
withdrawnPairs w =
  ("withdrawnFrom" .= object ["type" .= withdrawnFromTag w.withdrawnFrom])
    : withdrawnFromStagePairs w.withdrawnFrom
    ++ ["withdrawnAt" .= w.withdrawnAt, "withdrawalNote" .= w.withdrawalNote]

parseWithdrawn :: Object -> Parser WithdrawnIntakeRequestDTO
parseWithdrawn o = do
  tag  <- o .: "withdrawnFrom" >>= strictObject "withdrawnFrom" tagOf (\t -> ["type" .= t])
  from <- parseWithdrawnFromStage tag o
  WithdrawnIntakeRequestDTO from <$> o .: "withdrawnAt" <*> o .: "withdrawalNote"

-- One variant per WithdrawnFrom case: its keys depend on that nested tag.
withdrawnVariants :: Decl [(Text, Props)]
withdrawnVariants = do
  fromSubmitted <- submittedProps
  fromAccepted  <- triagedProps
  let variant tag stage =
        ("withdrawnFrom", Inline (objectSchema [("type", enumOf [tag])]))
          : stage ++ [("withdrawnAt", timeS), ("withdrawalNote", nullableStringS)]
  pure
    [ ("FromSubmitted", variant "fromSubmitted" fromSubmitted)
    , ("FromAccepted", variant "fromAccepted" fromAccepted)
    ]

instance ToJSON WithdrawnIntakeRequestDTO where toJSON = object . withdrawnPairs
instance FromJSON WithdrawnIntakeRequestDTO where
  parseJSON = strictObject "WithdrawnIntakeRequest" parseWithdrawn withdrawnPairs
instance ToSchema WithdrawnIntakeRequestDTO where
  declareNamedSchema _ = do
    variants <- withdrawnVariants
    refs <- forM variants $ \(inner, props) ->
      declareNamed ("WithdrawnIntakeRequest" <> inner) (objectSchema props)
    pure (NamedSchema (Just "WithdrawnIntakeRequest") (mempty & O.oneOf ?~ refs))

toDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequestDTO -> WithdrawnIntakeRequest
toDomainWithdrawnIntakeRequest w = WithdrawnIntakeRequest
  { withdrawnFrom = toDomainWithdrawnFrom w.withdrawnFrom
  , withdrawnAt = w.withdrawnAt
  , withdrawalNote = w.withdrawalNote
  }

fromDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequest -> WithdrawnIntakeRequestDTO
fromDomainWithdrawnIntakeRequest w = WithdrawnIntakeRequestDTO
  { withdrawnFrom = fromDomainWithdrawnFrom w.withdrawnFrom
  , withdrawnAt = w.withdrawnAt
  , withdrawalNote = w.withdrawalNote
  }

-- ── Stale ───────────────────────────────────────────────────────────────────

data StaleIntakeRequestDTO = StaleIntakeRequestDTO
  { triaged :: TriagedIntakeRequestDTO
  , staleAt :: UTCTime
  }
  deriving (Show, Eq)

stalePairs :: StaleIntakeRequestDTO -> [Pair]
stalePairs s = triagedPairs s.triaged ++ ["staleAt" .= s.staleAt]

parseStale :: Object -> Parser StaleIntakeRequestDTO
parseStale o = StaleIntakeRequestDTO <$> parseTriaged o <*> o .: "staleAt"

staleProps :: Decl Props
staleProps = (++) <$> triagedProps <*> sequence [plain "staleAt" timeS]

instance ToJSON StaleIntakeRequestDTO where toJSON = object . stalePairs
instance FromJSON StaleIntakeRequestDTO where
  parseJSON = strictObject "StaleIntakeRequest" parseStale stalePairs
instance ToSchema StaleIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "StaleIntakeRequest" staleProps

toDomainStaleIntakeRequest :: StaleIntakeRequestDTO -> StaleIntakeRequest
toDomainStaleIntakeRequest s =
  StaleIntakeRequest { triaged = toDomainTriagedIntakeRequest s.triaged, staleAt = s.staleAt }

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> StaleIntakeRequestDTO
fromDomainStaleIntakeRequest s =
  StaleIntakeRequestDTO { triaged = fromDomainTriagedIntakeRequest s.triaged, staleAt = s.staleAt }

-- ── Closing ─────────────────────────────────────────────────────────────────

data AppointmentPartyDTO
  = AppointmentPartyDoctorParty
  | AppointmentPartyPatientParty
  deriving (Show, Eq)

appointmentPartyPairs :: AppointmentPartyDTO -> [Pair]
appointmentPartyPairs = \case
  AppointmentPartyDoctorParty  -> typed "doctorParty" []
  AppointmentPartyPatientParty -> typed "patientParty" []

parseAppointmentParty :: Object -> Parser AppointmentPartyDTO
parseAppointmentParty o = tagOf o >>= \case
  "doctorParty"  -> pure AppointmentPartyDoctorParty
  "patientParty" -> pure AppointmentPartyPatientParty
  tag            -> unknownTag "AppointmentParty" tag

instance ToJSON AppointmentPartyDTO where toJSON = object . appointmentPartyPairs
instance FromJSON AppointmentPartyDTO where
  parseJSON = strictObject "AppointmentParty" parseAppointmentParty appointmentPartyPairs
instance ToSchema AppointmentPartyDTO where
  declareNamedSchema _ = enumerationSchema "AppointmentParty" ["DoctorParty", "PatientParty"]

toDomainAppointmentParty :: AppointmentPartyDTO -> AppointmentParty
toDomainAppointmentParty = \case
  AppointmentPartyDoctorParty  -> DoctorParty
  AppointmentPartyPatientParty -> PatientParty

fromDomainAppointmentParty :: AppointmentParty -> AppointmentPartyDTO
fromDomainAppointmentParty = \case
  DoctorParty  -> AppointmentPartyDoctorParty
  PatientParty -> AppointmentPartyPatientParty

data CancellationDTO = CancellationDTO
  { cancelledBy      :: AppointmentPartyDTO
  , cancelledAt      :: UTCTime
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

cancellationPairs :: CancellationDTO -> [Pair]
cancellationPairs c =
  [ "cancelledBy" .= c.cancelledBy, "cancelledAt" .= c.cancelledAt
  , "cancellationNote" .= c.cancellationNote ]

parseCancellation :: Object -> Parser CancellationDTO
parseCancellation o = CancellationDTO
  <$> o .: "cancelledBy" <*> o .: "cancelledAt" <*> o .: "cancellationNote"

cancellationProps :: Decl Props
cancellationProps = sequence
  [ field "cancelledBy" (ref @AppointmentPartyDTO)
  , plain "cancelledAt" timeS
  , plain "cancellationNote" nullableStringS
  ]

instance ToJSON CancellationDTO where toJSON = object . cancellationPairs
instance FromJSON CancellationDTO where
  parseJSON = strictObject "Cancellation" parseCancellation cancellationPairs
instance ToSchema CancellationDTO where
  declareNamedSchema _ = recordSchema "Cancellation" cancellationProps

toDomainCancellation :: CancellationDTO -> Cancellation
toDomainCancellation c = Cancellation
  { cancelledBy = toDomainAppointmentParty c.cancelledBy
  , cancelledAt = c.cancelledAt
  , cancellationNote = c.cancellationNote
  }

fromDomainCancellation :: Cancellation -> CancellationDTO
fromDomainCancellation c = CancellationDTO
  { cancelledBy = fromDomainAppointmentParty c.cancelledBy
  , cancelledAt = c.cancelledAt
  , cancellationNote = c.cancellationNote
  }

newtype AbsenceDTO = AbsenceDTO
  { absentParty :: AppointmentPartyDTO
  }
  deriving (Show, Eq)

absencePairs :: AbsenceDTO -> [Pair]
absencePairs a = ["absentParty" .= a.absentParty]

parseAbsence :: Object -> Parser AbsenceDTO
parseAbsence o = AbsenceDTO <$> o .: "absentParty"

absenceProps :: Decl Props
absenceProps = sequence [field "absentParty" (ref @AppointmentPartyDTO)]

instance ToJSON AbsenceDTO where toJSON = object . absencePairs
instance FromJSON AbsenceDTO where parseJSON = strictObject "Absence" parseAbsence absencePairs
instance ToSchema AbsenceDTO where declareNamedSchema _ = recordSchema "Absence" absenceProps

toDomainAbsence :: AbsenceDTO -> Absence
toDomainAbsence a = Absence { absentParty = toDomainAppointmentParty a.absentParty }

fromDomainAbsence :: Absence -> AbsenceDTO
fromDomainAbsence a = AbsenceDTO { absentParty = fromDomainAppointmentParty a.absentParty }

data CloseReasonDTO
  = CloseReasonCompleted
  | CloseReasonCancelled CancellationDTO
  | CloseReasonNoShow AbsenceDTO
  deriving (Show, Eq)

closeReasonPairs :: CloseReasonDTO -> [Pair]
closeReasonPairs = \case
  CloseReasonCompleted   -> typed "completed" []
  CloseReasonCancelled c -> typed "cancelled" (cancellationPairs c)
  CloseReasonNoShow a    -> typed "noShow" (absencePairs a)

parseCloseReason :: Object -> Parser CloseReasonDTO
parseCloseReason o = tagOf o >>= \case
  "completed" -> pure CloseReasonCompleted
  "cancelled" -> CloseReasonCancelled <$> parseCancellation o
  "noShow"    -> CloseReasonNoShow <$> parseAbsence o
  tag         -> unknownTag "CloseReason" tag

instance ToJSON CloseReasonDTO where toJSON = object . closeReasonPairs
instance FromJSON CloseReasonDTO where
  parseJSON = strictObject "CloseReason" parseCloseReason closeReasonPairs
instance ToSchema CloseReasonDTO where
  declareNamedSchema _ = sumSchema "CloseReason"
    [ ("Completed", pure [])
    , ("Cancelled", cancellationProps)
    , ("NoShow", absenceProps)
    ]

toDomainCloseReason :: CloseReasonDTO -> CloseReason
toDomainCloseReason = \case
  CloseReasonCompleted   -> Completed
  CloseReasonCancelled c -> Cancelled (toDomainCancellation c)
  CloseReasonNoShow a    -> NoShow (toDomainAbsence a)

fromDomainCloseReason :: CloseReason -> CloseReasonDTO
fromDomainCloseReason = \case
  Completed   -> CloseReasonCompleted
  Cancelled c -> CloseReasonCancelled (fromDomainCancellation c)
  NoShow a    -> CloseReasonNoShow (fromDomainAbsence a)

data ClosedIntakeRequestDTO = ClosedIntakeRequestDTO
  { appointed   :: AppointedIntakeRequestDTO
  , closeReason :: CloseReasonDTO
  }
  deriving (Show, Eq)

closedPairs :: ClosedIntakeRequestDTO -> [Pair]
closedPairs c = appointedPairs c.appointed ++ ["closeReason" .= c.closeReason]

parseClosed :: Object -> Parser ClosedIntakeRequestDTO
parseClosed o = ClosedIntakeRequestDTO <$> parseAppointed o <*> o .: "closeReason"

closedProps :: Decl Props
closedProps = (++) <$> appointedProps <*> sequence [field "closeReason" (ref @CloseReasonDTO)]

instance ToJSON ClosedIntakeRequestDTO where toJSON = object . closedPairs
instance FromJSON ClosedIntakeRequestDTO where
  parseJSON = strictObject "ClosedIntakeRequest" parseClosed closedPairs
instance ToSchema ClosedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "ClosedIntakeRequest" closedProps

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
  = IntakeRequestSubmitted SubmittedIntakeRequestDTO
  | IntakeRequestRejected RejectedIntakeRequestDTO
  | IntakeRequestAccepted TriagedIntakeRequestDTO
  | IntakeRequestAppointed AppointedIntakeRequestDTO
  | IntakeRequestWithdrawn WithdrawnIntakeRequestDTO
  | IntakeRequestStale StaleIntakeRequestDTO
  | IntakeRequestClosed ClosedIntakeRequestDTO
  deriving (Show, Eq)

intakeRequestPairs :: IntakeRequestDTO -> [Pair]
intakeRequestPairs = \case
  IntakeRequestSubmitted s -> typed "submitted" (submittedPairs s)
  IntakeRequestRejected r  -> typed "rejected" (rejectedPairs r)
  IntakeRequestAccepted t  -> typed "accepted" (triagedPairs t)
  IntakeRequestAppointed a -> typed "appointed" (appointedPairs a)
  IntakeRequestWithdrawn w -> typed "withdrawn" (withdrawnPairs w)
  IntakeRequestStale s     -> typed "stale" (stalePairs s)
  IntakeRequestClosed c    -> typed "closed" (closedPairs c)

parseIntakeRequest :: Object -> Parser IntakeRequestDTO
parseIntakeRequest o = tagOf o >>= \case
  "submitted" -> IntakeRequestSubmitted <$> parseSubmitted o
  "rejected"  -> IntakeRequestRejected <$> parseRejected o
  "accepted"  -> IntakeRequestAccepted <$> parseTriaged o
  "appointed" -> IntakeRequestAppointed <$> parseAppointed o
  "withdrawn" -> IntakeRequestWithdrawn <$> parseWithdrawn o
  "stale"     -> IntakeRequestStale <$> parseStale o
  "closed"    -> IntakeRequestClosed <$> parseClosed o
  tag         -> unknownTag "IntakeRequest" tag

instance ToJSON IntakeRequestDTO where toJSON = object . intakeRequestPairs
instance FromJSON IntakeRequestDTO where
  parseJSON = strictObject "IntakeRequest" parseIntakeRequest intakeRequestPairs

-- The Withdrawn case is itself oneOf its variants, so IntakeRequest has no
-- discriminator.
instance ToSchema IntakeRequestDTO where
  declareNamedSchema _ = do
    let tagged ctor props = ("type", enumOf [lowerFirst ctor]) : props
        plainCase ctor propsD = do
          props <- propsD
          declareNamed ("IntakeRequest" <> ctor) (objectSchema (tagged ctor props))
    submittedCase <- plainCase "Submitted" submittedProps
    rejectedCase  <- plainCase "Rejected" rejectedProps
    acceptedCase  <- plainCase "Accepted" triagedProps
    appointedCase <- plainCase "Appointed" appointedProps
    variants  <- withdrawnVariants
    variantRefs <- forM variants $ \(inner, props) ->
      declareNamed ("IntakeRequestWithdrawn" <> inner) (objectSchema (tagged "Withdrawn" props))
    withdrawnCase <- declareNamed "IntakeRequestWithdrawn" (mempty & O.oneOf ?~ variantRefs)
    staleCase     <- plainCase "Stale" staleProps
    closedCase    <- plainCase "Closed" closedProps
    pure . NamedSchema (Just "IntakeRequest") $ mempty
      & O.oneOf ?~ [submittedCase, rejectedCase, acceptedCase, appointedCase, withdrawnCase, staleCase, closedCase]

toDomainIntakeRequest :: IntakeRequestDTO -> IntakeRequest
toDomainIntakeRequest = \case
  IntakeRequestSubmitted s -> Submitted (toDomainSubmittedIntakeRequest s)
  IntakeRequestRejected r  -> Rejected (toDomainRejectedIntakeRequest r)
  IntakeRequestAccepted t  -> Accepted (toDomainTriagedIntakeRequest t)
  IntakeRequestAppointed a -> Appointed (toDomainAppointedIntakeRequest a)
  IntakeRequestWithdrawn w -> Withdrawn (toDomainWithdrawnIntakeRequest w)
  IntakeRequestStale s     -> Stale (toDomainStaleIntakeRequest s)
  IntakeRequestClosed c    -> Closed (toDomainClosedIntakeRequest c)

fromDomainIntakeRequest :: IntakeRequest -> IntakeRequestDTO
fromDomainIntakeRequest = \case
  Submitted s -> IntakeRequestSubmitted (fromDomainSubmittedIntakeRequest s)
  Rejected r  -> IntakeRequestRejected (fromDomainRejectedIntakeRequest r)
  Accepted t  -> IntakeRequestAccepted (fromDomainTriagedIntakeRequest t)
  Appointed a -> IntakeRequestAppointed (fromDomainAppointedIntakeRequest a)
  Withdrawn w -> IntakeRequestWithdrawn (fromDomainWithdrawnIntakeRequest w)
  Stale s     -> IntakeRequestStale (fromDomainStaleIntakeRequest s)
  Closed c    -> IntakeRequestClosed (fromDomainClosedIntakeRequest c)

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

availableSlotPairs :: AvailableSlotDTO -> [Pair]
availableSlotPairs s =
  [ "id" .= s.id, "doctorId" .= s.doctorId, "healthcareServiceId" .= s.healthcareServiceId
  , "start" .= s.start, "duration" .= s.duration ]

parseAvailableSlot :: Object -> Parser AvailableSlotDTO
parseAvailableSlot o = AvailableSlotDTO
  <$> o .: "id" <*> o .: "doctorId" <*> o .: "healthcareServiceId" <*> o .: "start" <*> o .: "duration"

availableSlotProps :: Decl Props
availableSlotProps = sequence
  [ field "id" (ref @SlotIdDTO)
  , field "doctorId" (ref @DoctorIdDTO)
  , field "healthcareServiceId" (ref @HealthcareServiceIdDTO)
  , plain "start" timeS
  , field "duration" (ref @DurationDTO)
  ]

instance ToJSON AvailableSlotDTO where toJSON = object . availableSlotPairs
instance FromJSON AvailableSlotDTO where
  parseJSON = strictObject "AvailableSlot" parseAvailableSlot availableSlotPairs
instance ToSchema AvailableSlotDTO where
  declareNamedSchema _ = recordSchema "AvailableSlot" availableSlotProps

toDomainAvailableSlot :: AvailableSlotDTO -> AvailableSlot
toDomainAvailableSlot s = AvailableSlot
  { id = toDomainSlotId s.id
  , doctorId = toDomainDoctorId s.doctorId
  , healthcareServiceId = toDomainHealthcareServiceId s.healthcareServiceId
  , start = s.start
  , duration = toDomainDuration s.duration
  }

fromDomainAvailableSlot :: AvailableSlot -> AvailableSlotDTO
fromDomainAvailableSlot s = AvailableSlotDTO
  { id = fromDomainSlotId s.id
  , doctorId = fromDomainDoctorId s.doctorId
  , healthcareServiceId = fromDomainHealthcareServiceId s.healthcareServiceId
  , start = s.start
  , duration = fromDomainDuration s.duration
  }

data DoctorCalendarEntryDTO
  = DoctorCalendarEntrySlot AvailableSlotDTO
  | DoctorCalendarEntryAppointment AppointedIntakeRequestDTO
  deriving (Show, Eq)

doctorCalendarEntryPairs :: DoctorCalendarEntryDTO -> [Pair]
doctorCalendarEntryPairs = \case
  DoctorCalendarEntrySlot s        -> typed "slot" (availableSlotPairs s)
  DoctorCalendarEntryAppointment a -> typed "appointment" (appointedPairs a)

parseDoctorCalendarEntry :: Object -> Parser DoctorCalendarEntryDTO
parseDoctorCalendarEntry o = tagOf o >>= \case
  "slot"        -> DoctorCalendarEntrySlot <$> parseAvailableSlot o
  "appointment" -> DoctorCalendarEntryAppointment <$> parseAppointed o
  tag           -> unknownTag "DoctorCalendarEntry" tag

instance ToJSON DoctorCalendarEntryDTO where toJSON = object . doctorCalendarEntryPairs
instance FromJSON DoctorCalendarEntryDTO where
  parseJSON = strictObject "DoctorCalendarEntry" parseDoctorCalendarEntry doctorCalendarEntryPairs
instance ToSchema DoctorCalendarEntryDTO where
  declareNamedSchema _ = sumSchema "DoctorCalendarEntry"
    [ ("Slot", availableSlotProps)
    , ("Appointment", appointedProps)
    ]

toDomainDoctorCalendarEntry :: DoctorCalendarEntryDTO -> DoctorCalendarEntry
toDomainDoctorCalendarEntry = \case
  DoctorCalendarEntrySlot s        -> Slot (toDomainAvailableSlot s)
  DoctorCalendarEntryAppointment a -> Appointment (toDomainAppointedIntakeRequest a)

fromDomainDoctorCalendarEntry :: DoctorCalendarEntry -> DoctorCalendarEntryDTO
fromDomainDoctorCalendarEntry = \case
  Slot s        -> DoctorCalendarEntrySlot (fromDomainAvailableSlot s)
  Appointment a -> DoctorCalendarEntryAppointment (fromDomainAppointedIntakeRequest a)

-- ═══════════════════════════════════════════════════════════════════════════
-- REQUESTS — one per Service function with caller-supplied facts; keys are
-- the Domain.hs fields the values land in
-- ═══════════════════════════════════════════════════════════════════════════

newtype CreateDoctorRequest = CreateDoctorRequest
  { name :: Text
  }
  deriving (Show, Eq)

createDoctorPairs :: CreateDoctorRequest -> [Pair]
createDoctorPairs r = ["name" .= r.name]

instance ToJSON CreateDoctorRequest where toJSON = object . createDoctorPairs
instance FromJSON CreateDoctorRequest where
  parseJSON = strictObject "CreateDoctorRequest" (\o -> CreateDoctorRequest <$> o .: "name") createDoctorPairs
instance ToSchema CreateDoctorRequest where
  declareNamedSchema _ = recordSchema "CreateDoctorRequest" (sequence [plain "name" stringS])

newtype CreatePatientRequest = CreatePatientRequest
  { name :: Text
  }
  deriving (Show, Eq)

createPatientPairs :: CreatePatientRequest -> [Pair]
createPatientPairs r = ["name" .= r.name]

instance ToJSON CreatePatientRequest where toJSON = object . createPatientPairs
instance FromJSON CreatePatientRequest where
  parseJSON = strictObject "CreatePatientRequest" (\o -> CreatePatientRequest <$> o .: "name") createPatientPairs
instance ToSchema CreatePatientRequest where
  declareNamedSchema _ = recordSchema "CreatePatientRequest" (sequence [plain "name" stringS])

data CreateHealthcareServiceRequest = CreateHealthcareServiceRequest
  { name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

createHealthcareServicePairs :: CreateHealthcareServiceRequest -> [Pair]
createHealthcareServicePairs r = ["name" .= r.name, "duration" .= r.duration]

instance ToJSON CreateHealthcareServiceRequest where toJSON = object . createHealthcareServicePairs
instance FromJSON CreateHealthcareServiceRequest where
  parseJSON = strictObject "CreateHealthcareServiceRequest"
    (\o -> CreateHealthcareServiceRequest <$> o .: "name" <*> o .: "duration")
    createHealthcareServicePairs
instance ToSchema CreateHealthcareServiceRequest where
  declareNamedSchema _ = recordSchema "CreateHealthcareServiceRequest" $
    sequence [plain "name" stringS, field "duration" (ref @DurationDTO)]

data SubmitIntakeRequestRequest = SubmitIntakeRequestRequest
  { patientId :: PatientIdDTO
  , narrative :: Text
  }
  deriving (Show, Eq)

submitIntakeRequestPairs :: SubmitIntakeRequestRequest -> [Pair]
submitIntakeRequestPairs r = ["patientId" .= r.patientId, "narrative" .= r.narrative]

instance ToJSON SubmitIntakeRequestRequest where toJSON = object . submitIntakeRequestPairs
instance FromJSON SubmitIntakeRequestRequest where
  parseJSON = strictObject "SubmitIntakeRequestRequest"
    (\o -> SubmitIntakeRequestRequest <$> o .: "patientId" <*> o .: "narrative")
    submitIntakeRequestPairs
instance ToSchema SubmitIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "SubmitIntakeRequestRequest" $
    sequence [field "patientId" (ref @PatientIdDTO), plain "narrative" stringS]

data CreateAvailableSlotRequest = CreateAvailableSlotRequest
  { doctorId            :: DoctorIdDTO
  , healthcareServiceId :: HealthcareServiceIdDTO
  , start               :: UTCTime
  }
  deriving (Show, Eq)

createAvailableSlotPairs :: CreateAvailableSlotRequest -> [Pair]
createAvailableSlotPairs r =
  ["doctorId" .= r.doctorId, "healthcareServiceId" .= r.healthcareServiceId, "start" .= r.start]

instance ToJSON CreateAvailableSlotRequest where toJSON = object . createAvailableSlotPairs
instance FromJSON CreateAvailableSlotRequest where
  parseJSON = strictObject "CreateAvailableSlotRequest"
    (\o -> CreateAvailableSlotRequest <$> o .: "doctorId" <*> o .: "healthcareServiceId" <*> o .: "start")
    createAvailableSlotPairs
instance ToSchema CreateAvailableSlotRequest where
  declareNamedSchema _ = recordSchema "CreateAvailableSlotRequest" $ sequence
    [ field "doctorId" (ref @DoctorIdDTO)
    , field "healthcareServiceId" (ref @HealthcareServiceIdDTO)
    , plain "start" timeS
    ]

data AcceptSubmittedIntakeRequestRequest = AcceptSubmittedIntakeRequestRequest
  { healthcareServiceId :: HealthcareServiceIdDTO
  , priority            :: IntakeRequestPriorityDTO
  , doctorRequirement   :: DoctorRequirementDTO
  }
  deriving (Show, Eq)

acceptSubmittedIntakeRequestPairs :: AcceptSubmittedIntakeRequestRequest -> [Pair]
acceptSubmittedIntakeRequestPairs r =
  [ "healthcareServiceId" .= r.healthcareServiceId
  , "priority" .= r.priority
  , "doctorRequirement" .= r.doctorRequirement
  ]

instance ToJSON AcceptSubmittedIntakeRequestRequest where
  toJSON = object . acceptSubmittedIntakeRequestPairs
instance FromJSON AcceptSubmittedIntakeRequestRequest where
  parseJSON = strictObject "AcceptSubmittedIntakeRequestRequest"
    (\o -> AcceptSubmittedIntakeRequestRequest
      <$> o .: "healthcareServiceId" <*> o .: "priority" <*> o .: "doctorRequirement")
    acceptSubmittedIntakeRequestPairs
instance ToSchema AcceptSubmittedIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "AcceptSubmittedIntakeRequestRequest" $ sequence
    [ field "healthcareServiceId" (ref @HealthcareServiceIdDTO)
    , field "priority" (ref @IntakeRequestPriorityDTO)
    , field "doctorRequirement" (ref @DoctorRequirementDTO)
    ]

newtype RejectSubmittedIntakeRequestRequest = RejectSubmittedIntakeRequestRequest
  { rejectionReason :: Text
  }
  deriving (Show, Eq)

rejectSubmittedIntakeRequestPairs :: RejectSubmittedIntakeRequestRequest -> [Pair]
rejectSubmittedIntakeRequestPairs r = ["rejectionReason" .= r.rejectionReason]

instance ToJSON RejectSubmittedIntakeRequestRequest where
  toJSON = object . rejectSubmittedIntakeRequestPairs
instance FromJSON RejectSubmittedIntakeRequestRequest where
  parseJSON = strictObject "RejectSubmittedIntakeRequestRequest"
    (\o -> RejectSubmittedIntakeRequestRequest <$> o .: "rejectionReason")
    rejectSubmittedIntakeRequestPairs
instance ToSchema RejectSubmittedIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "RejectSubmittedIntakeRequestRequest" $
    sequence [plain "rejectionReason" stringS]

newtype MatchAcceptedIntakeRequestToSlotRequest = MatchAcceptedIntakeRequestToSlotRequest
  { slotId :: SlotIdDTO
  }
  deriving (Show, Eq)

matchAcceptedIntakeRequestToSlotPairs :: MatchAcceptedIntakeRequestToSlotRequest -> [Pair]
matchAcceptedIntakeRequestToSlotPairs r = ["slotId" .= r.slotId]

instance ToJSON MatchAcceptedIntakeRequestToSlotRequest where
  toJSON = object . matchAcceptedIntakeRequestToSlotPairs
instance FromJSON MatchAcceptedIntakeRequestToSlotRequest where
  parseJSON = strictObject "MatchAcceptedIntakeRequestToSlotRequest"
    (\o -> MatchAcceptedIntakeRequestToSlotRequest <$> o .: "slotId")
    matchAcceptedIntakeRequestToSlotPairs
instance ToSchema MatchAcceptedIntakeRequestToSlotRequest where
  declareNamedSchema _ = recordSchema "MatchAcceptedIntakeRequestToSlotRequest" $
    sequence [field "slotId" (ref @SlotIdDTO)]

newtype WithdrawIntakeRequestRequest = WithdrawIntakeRequestRequest
  { withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

withdrawIntakeRequestPairs :: WithdrawIntakeRequestRequest -> [Pair]
withdrawIntakeRequestPairs r = ["withdrawalNote" .= r.withdrawalNote]

instance ToJSON WithdrawIntakeRequestRequest where toJSON = object . withdrawIntakeRequestPairs
instance FromJSON WithdrawIntakeRequestRequest where
  parseJSON = strictObject "WithdrawIntakeRequestRequest"
    (\o -> WithdrawIntakeRequestRequest <$> o .: "withdrawalNote")
    withdrawIntakeRequestPairs
instance ToSchema WithdrawIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "WithdrawIntakeRequestRequest" $
    sequence [plain "withdrawalNote" nullableStringS]

newtype CloseAppointedIntakeRequestRequest = CloseAppointedIntakeRequestRequest
  { closeReason :: CloseReasonRequest
  }
  deriving (Show, Eq)

closeAppointedIntakeRequestPairs :: CloseAppointedIntakeRequestRequest -> [Pair]
closeAppointedIntakeRequestPairs r = ["closeReason" .= r.closeReason]

instance ToJSON CloseAppointedIntakeRequestRequest where
  toJSON = object . closeAppointedIntakeRequestPairs
instance FromJSON CloseAppointedIntakeRequestRequest where
  parseJSON = strictObject "CloseAppointedIntakeRequestRequest"
    (\o -> CloseAppointedIntakeRequestRequest <$> o .: "closeReason")
    closeAppointedIntakeRequestPairs
instance ToSchema CloseAppointedIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "CloseAppointedIntakeRequestRequest" $
    sequence [field "closeReason" (ref @CloseReasonRequest)]

-- ── Request variants: a Domain.hs value without the time the server records ─

-- Cancellation without cancelledAt.
data CancellationRequest = CancellationRequest
  { cancelledBy      :: AppointmentPartyDTO
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

cancellationRequestPairs :: CancellationRequest -> [Pair]
cancellationRequestPairs c = ["cancelledBy" .= c.cancelledBy, "cancellationNote" .= c.cancellationNote]

parseCancellationRequest :: Object -> Parser CancellationRequest
parseCancellationRequest o = CancellationRequest <$> o .: "cancelledBy" <*> o .: "cancellationNote"

cancellationRequestProps :: Decl Props
cancellationRequestProps = sequence
  [ field "cancelledBy" (ref @AppointmentPartyDTO)
  , plain "cancellationNote" nullableStringS
  ]

instance ToJSON CancellationRequest where toJSON = object . cancellationRequestPairs
instance FromJSON CancellationRequest where
  parseJSON = strictObject "CancellationRequest" parseCancellationRequest cancellationRequestPairs
instance ToSchema CancellationRequest where
  declareNamedSchema _ = recordSchema "CancellationRequest" cancellationRequestProps

toDomainCancellationRequest :: UTCTime -> CancellationRequest -> Cancellation
toDomainCancellationRequest at c = Cancellation
  { cancelledBy = toDomainAppointmentParty c.cancelledBy
  , cancelledAt = at
  , cancellationNote = c.cancellationNote
  }

-- CloseReason whose Cancelled case lacks cancelledAt.
data CloseReasonRequest
  = CloseReasonRequestCompleted
  | CloseReasonRequestCancelled CancellationRequest
  | CloseReasonRequestNoShow AbsenceDTO
  deriving (Show, Eq)

closeReasonRequestPairs :: CloseReasonRequest -> [Pair]
closeReasonRequestPairs = \case
  CloseReasonRequestCompleted   -> typed "completed" []
  CloseReasonRequestCancelled c -> typed "cancelled" (cancellationRequestPairs c)
  CloseReasonRequestNoShow a    -> typed "noShow" (absencePairs a)

parseCloseReasonRequest :: Object -> Parser CloseReasonRequest
parseCloseReasonRequest o = tagOf o >>= \case
  "completed" -> pure CloseReasonRequestCompleted
  "cancelled" -> CloseReasonRequestCancelled <$> parseCancellationRequest o
  "noShow"    -> CloseReasonRequestNoShow <$> parseAbsence o
  tag         -> unknownTag "CloseReasonRequest" tag

instance ToJSON CloseReasonRequest where toJSON = object . closeReasonRequestPairs
instance FromJSON CloseReasonRequest where
  parseJSON = strictObject "CloseReasonRequest" parseCloseReasonRequest closeReasonRequestPairs
instance ToSchema CloseReasonRequest where
  declareNamedSchema _ = sumSchema "CloseReasonRequest"
    [ ("Completed", pure [])
    , ("Cancelled", cancellationRequestProps)
    , ("NoShow", absenceProps)
    ]

toDomainCloseReasonRequest :: UTCTime -> CloseReasonRequest -> CloseReason
toDomainCloseReasonRequest at = \case
  CloseReasonRequestCompleted   -> Completed
  CloseReasonRequestCancelled c -> Cancelled (toDomainCancellationRequest at c)
  CloseReasonRequestNoShow a    -> NoShow (toDomainAbsence a)

-- ═══════════════════════════════════════════════════════════════════════════
-- ANSWERS — {"outcome": <tag>, "detail": <payload or null>}, one schema per
-- outcome tag, <Function>Answer<Constructor>
-- ═══════════════════════════════════════════════════════════════════════════

data Envelope = Envelope
  { outcome :: Text
  , detail  :: Value
  }
  deriving (Show, Eq)

instance ToJSON Envelope where
  toJSON e = object ["outcome" .= e.outcome, "detail" .= e.detail]

-- An outcome tag and its detail's schema (Nothing: detail is null).
type AnswerCase = (Text, Decl (Maybe (Referenced Schema)))

envelopeSchema :: Text -> [AnswerCase] -> Decl Schema
envelopeSchema prefix cases = do
  refs <- forM cases $ \(tag, detailD) -> do
    detailS <- detailD
    declareNamed (prefix <> upperFirst tag) $
      objectSchema [("outcome", enumOf [tag]), ("detail", fromMaybe nullS detailS)]
  pure $ mempty
    & O.oneOf         ?~ refs
    & O.discriminator ?~ Discriminator "outcome"
        (InsOrd.fromList [ (tag, schemaRef (prefix <> upperFirst tag)) | (tag, _) <- cases ])

answerSchema :: Text -> [AnswerCase] -> Decl NamedSchema
answerSchema function cases =
  NamedSchema (Just (function <> "Answer")) <$> envelopeSchema (function <> "Answer") cases

detailOf :: Decl (Referenced Schema) -> Decl (Maybe (Referenced Schema))
detailOf = fmap Just

noDetail :: Decl (Maybe (Referenced Schema))
noDetail = pure Nothing

okCase :: Decl (Referenced Schema) -> AnswerCase
okCase s = ("ok", detailOf s)

listOf :: forall a. ToSchema a => Decl (Referenced Schema)
listOf = arrayOf <$> ref @a

-- ── Facts ───────────────────────────────────────────────────────────────────

doctorNotFoundCase, patientNotFoundCase, healthcareServiceNotFoundCase,
  intakeRequestNotFoundCase, intakeRequestInWrongStateCase,
  intakeRequestDoesNotMatchSlotCase :: AnswerCase
doctorNotFoundCase = ("doctorNotFound", detailOf (ref @DoctorIdDTO))
patientNotFoundCase = ("patientNotFound", detailOf (ref @PatientIdDTO))
healthcareServiceNotFoundCase = ("healthcareServiceNotFound", detailOf (ref @HealthcareServiceIdDTO))
intakeRequestNotFoundCase = ("intakeRequestNotFound", detailOf (ref @IntakeRequestIdDTO))
intakeRequestInWrongStateCase = ("intakeRequestInWrongState", detailOf (ref @IntakeRequestDTO))
intakeRequestDoesNotMatchSlotCase = ("intakeRequestDoesNotMatchSlot", noDetail)

-- ── Outcomes ────────────────────────────────────────────────────────────────

transitionOutcomeCases :: Decl (Referenced Schema) -> [AnswerCase]
transitionOutcomeCases transitioned =
  [ ("transitioned", detailOf transitioned)
  , ("movedOn", detailOf (ref @IntakeRequestDTO))
  ]

matchIntakeRequestToSlotOutcomeCases :: [AnswerCase]
matchIntakeRequestToSlotOutcomeCases =
  [ ("intakeRequestMatchedToSlot", detailOf (ref @AppointedIntakeRequestDTO))
  , ("availableSlotConsumed", detailOf (ref @SlotIdDTO))
  , ("intakeRequestMovedOn", detailOf (ref @IntakeRequestDTO))
  ]

-- Nested answer: keeps its own name.
matchIntakeRequestToSlotOutcomeRef :: Decl (Referenced Schema)
matchIntakeRequestToSlotOutcomeRef =
  envelopeSchema "MatchIntakeRequestToSlotOutcome" matchIntakeRequestToSlotOutcomeCases
    >>= declareNamed "MatchIntakeRequestToSlotOutcome"

matchByPriorityOutcomeCases :: [AnswerCase]
matchByPriorityOutcomeCases =
  [ ("noIntakeRequestMatched", noDetail)
  , ("matchIntakeRequestToSlotOutcome", detailOf matchIntakeRequestToSlotOutcomeRef)
  ]

addAvailableSlotOutcomeCases :: [AnswerCase]
addAvailableSlotOutcomeCases =
  [ ("availableSlotAdded", detailOf (ref @AvailableSlotDTO))
  , ("availableSlotOverlapsDoctorCalendar", noDetail)
  ]

-- ── One answer per Service function ─────────────────────────────────────────

newtype CreateDoctorAnswer = CreateDoctorAnswer Envelope deriving (Show, Eq)
instance ToJSON CreateDoctorAnswer where toJSON (CreateDoctorAnswer e) = toJSON e
instance ToSchema CreateDoctorAnswer where
  declareNamedSchema _ = answerSchema "CreateDoctor" [okCase (ref @DoctorDTO)]

newtype CreatePatientAnswer = CreatePatientAnswer Envelope deriving (Show, Eq)
instance ToJSON CreatePatientAnswer where toJSON (CreatePatientAnswer e) = toJSON e
instance ToSchema CreatePatientAnswer where
  declareNamedSchema _ = answerSchema "CreatePatient" [okCase (ref @PatientDTO)]

newtype CreateHealthcareServiceAnswer = CreateHealthcareServiceAnswer Envelope deriving (Show, Eq)
instance ToJSON CreateHealthcareServiceAnswer where toJSON (CreateHealthcareServiceAnswer e) = toJSON e
instance ToSchema CreateHealthcareServiceAnswer where
  declareNamedSchema _ = answerSchema "CreateHealthcareService" [okCase (ref @HealthcareServiceDTO)]

newtype SubmitIntakeRequestAnswer = SubmitIntakeRequestAnswer Envelope deriving (Show, Eq)
instance ToJSON SubmitIntakeRequestAnswer where toJSON (SubmitIntakeRequestAnswer e) = toJSON e
instance ToSchema SubmitIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "SubmitIntakeRequest"
    [okCase (ref @SubmittedIntakeRequestDTO), patientNotFoundCase]

newtype CreateAvailableSlotAnswer = CreateAvailableSlotAnswer Envelope deriving (Show, Eq)
instance ToJSON CreateAvailableSlotAnswer where toJSON (CreateAvailableSlotAnswer e) = toJSON e
instance ToSchema CreateAvailableSlotAnswer where
  declareNamedSchema _ = answerSchema "CreateAvailableSlot" $
    addAvailableSlotOutcomeCases ++ [doctorNotFoundCase, healthcareServiceNotFoundCase]

newtype AcceptSubmittedIntakeRequestAnswer = AcceptSubmittedIntakeRequestAnswer Envelope
  deriving (Show, Eq)
instance ToJSON AcceptSubmittedIntakeRequestAnswer where
  toJSON (AcceptSubmittedIntakeRequestAnswer e) = toJSON e
instance ToSchema AcceptSubmittedIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "AcceptSubmittedIntakeRequest" $
    transitionOutcomeCases (ref @TriagedIntakeRequestDTO)
      ++ [intakeRequestNotFoundCase, healthcareServiceNotFoundCase, doctorNotFoundCase]

newtype RejectSubmittedIntakeRequestAnswer = RejectSubmittedIntakeRequestAnswer Envelope
  deriving (Show, Eq)
instance ToJSON RejectSubmittedIntakeRequestAnswer where
  toJSON (RejectSubmittedIntakeRequestAnswer e) = toJSON e
instance ToSchema RejectSubmittedIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "RejectSubmittedIntakeRequest" $
    transitionOutcomeCases (ref @RejectedIntakeRequestDTO) ++ [intakeRequestNotFoundCase]

newtype MatchAcceptedIntakeRequestToSlotAnswer = MatchAcceptedIntakeRequestToSlotAnswer Envelope
  deriving (Show, Eq)
instance ToJSON MatchAcceptedIntakeRequestToSlotAnswer where
  toJSON (MatchAcceptedIntakeRequestToSlotAnswer e) = toJSON e
instance ToSchema MatchAcceptedIntakeRequestToSlotAnswer where
  declareNamedSchema _ = answerSchema "MatchAcceptedIntakeRequestToSlot" $
    matchIntakeRequestToSlotOutcomeCases
      ++ [ intakeRequestNotFoundCase, intakeRequestInWrongStateCase
         , intakeRequestDoesNotMatchSlotCase ]

newtype WithdrawIntakeRequestAnswer = WithdrawIntakeRequestAnswer Envelope deriving (Show, Eq)
instance ToJSON WithdrawIntakeRequestAnswer where toJSON (WithdrawIntakeRequestAnswer e) = toJSON e
instance ToSchema WithdrawIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "WithdrawIntakeRequest" $
    transitionOutcomeCases (ref @WithdrawnIntakeRequestDTO) ++ [intakeRequestNotFoundCase]

newtype MarkAcceptedIntakeRequestStaleAnswer = MarkAcceptedIntakeRequestStaleAnswer Envelope
  deriving (Show, Eq)
instance ToJSON MarkAcceptedIntakeRequestStaleAnswer where
  toJSON (MarkAcceptedIntakeRequestStaleAnswer e) = toJSON e
instance ToSchema MarkAcceptedIntakeRequestStaleAnswer where
  declareNamedSchema _ = answerSchema "MarkAcceptedIntakeRequestStale" $
    transitionOutcomeCases (ref @StaleIntakeRequestDTO)
      ++ [intakeRequestNotFoundCase, intakeRequestInWrongStateCase]

newtype CloseAppointedIntakeRequestAnswer = CloseAppointedIntakeRequestAnswer Envelope
  deriving (Show, Eq)
instance ToJSON CloseAppointedIntakeRequestAnswer where
  toJSON (CloseAppointedIntakeRequestAnswer e) = toJSON e
instance ToSchema CloseAppointedIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "CloseAppointedIntakeRequest" $
    transitionOutcomeCases (ref @ClosedIntakeRequestDTO)
      ++ [intakeRequestNotFoundCase, intakeRequestInWrongStateCase]

newtype MatchAvailableSlotByPriorityAnswer = MatchAvailableSlotByPriorityAnswer Envelope
  deriving (Show, Eq)
instance ToJSON MatchAvailableSlotByPriorityAnswer where
  toJSON (MatchAvailableSlotByPriorityAnswer e) = toJSON e
instance ToSchema MatchAvailableSlotByPriorityAnswer where
  declareNamedSchema _ = answerSchema "MatchAvailableSlotByPriority" matchByPriorityOutcomeCases

newtype FetchDoctorAnswer = FetchDoctorAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchDoctorAnswer where toJSON (FetchDoctorAnswer e) = toJSON e
instance ToSchema FetchDoctorAnswer where
  declareNamedSchema _ = answerSchema "FetchDoctor" [okCase (ref @DoctorDTO), doctorNotFoundCase]

newtype FetchDoctorsAnswer = FetchDoctorsAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchDoctorsAnswer where toJSON (FetchDoctorsAnswer e) = toJSON e
instance ToSchema FetchDoctorsAnswer where
  declareNamedSchema _ = answerSchema "FetchDoctors" [okCase (listOf @DoctorDTO)]

newtype FetchPatientAnswer = FetchPatientAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchPatientAnswer where toJSON (FetchPatientAnswer e) = toJSON e
instance ToSchema FetchPatientAnswer where
  declareNamedSchema _ = answerSchema "FetchPatient" [okCase (ref @PatientDTO), patientNotFoundCase]

newtype FetchPatientsAnswer = FetchPatientsAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchPatientsAnswer where toJSON (FetchPatientsAnswer e) = toJSON e
instance ToSchema FetchPatientsAnswer where
  declareNamedSchema _ = answerSchema "FetchPatients" [okCase (listOf @PatientDTO)]

newtype FetchHealthcareServiceAnswer = FetchHealthcareServiceAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchHealthcareServiceAnswer where toJSON (FetchHealthcareServiceAnswer e) = toJSON e
instance ToSchema FetchHealthcareServiceAnswer where
  declareNamedSchema _ = answerSchema "FetchHealthcareService"
    [okCase (ref @HealthcareServiceDTO), healthcareServiceNotFoundCase]

newtype FetchHealthcareServicesAnswer = FetchHealthcareServicesAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchHealthcareServicesAnswer where toJSON (FetchHealthcareServicesAnswer e) = toJSON e
instance ToSchema FetchHealthcareServicesAnswer where
  declareNamedSchema _ = answerSchema "FetchHealthcareServices" [okCase (listOf @HealthcareServiceDTO)]

newtype FetchAvailableSlotAnswer = FetchAvailableSlotAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchAvailableSlotAnswer where toJSON (FetchAvailableSlotAnswer e) = toJSON e
instance ToSchema FetchAvailableSlotAnswer where
  declareNamedSchema _ = answerSchema "FetchAvailableSlot"
    [okCase (ref @AvailableSlotDTO), ("availableSlotConsumed", detailOf (ref @SlotIdDTO))]

newtype FetchIntakeRequestAnswer = FetchIntakeRequestAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchIntakeRequestAnswer where toJSON (FetchIntakeRequestAnswer e) = toJSON e
instance ToSchema FetchIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "FetchIntakeRequest"
    [okCase (ref @IntakeRequestDTO), intakeRequestNotFoundCase]

newtype FetchSubmittedIntakeRequestsAnswer = FetchSubmittedIntakeRequestsAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchSubmittedIntakeRequestsAnswer where
  toJSON (FetchSubmittedIntakeRequestsAnswer e) = toJSON e
instance ToSchema FetchSubmittedIntakeRequestsAnswer where
  declareNamedSchema _ = answerSchema "FetchSubmittedIntakeRequests"
    [okCase (listOf @SubmittedIntakeRequestDTO)]

newtype FetchAcceptedIntakeRequestsAnswer = FetchAcceptedIntakeRequestsAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchAcceptedIntakeRequestsAnswer where
  toJSON (FetchAcceptedIntakeRequestsAnswer e) = toJSON e
instance ToSchema FetchAcceptedIntakeRequestsAnswer where
  declareNamedSchema _ = answerSchema "FetchAcceptedIntakeRequests"
    [okCase (listOf @TriagedIntakeRequestDTO)]

newtype FetchAppointedIntakeRequestsAnswer = FetchAppointedIntakeRequestsAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchAppointedIntakeRequestsAnswer where
  toJSON (FetchAppointedIntakeRequestsAnswer e) = toJSON e
instance ToSchema FetchAppointedIntakeRequestsAnswer where
  declareNamedSchema _ = answerSchema "FetchAppointedIntakeRequests"
    [okCase (listOf @AppointedIntakeRequestDTO)]

newtype FetchRejectedIntakeRequestsByRejectedAtAnswer =
  FetchRejectedIntakeRequestsByRejectedAtAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchRejectedIntakeRequestsByRejectedAtAnswer where
  toJSON (FetchRejectedIntakeRequestsByRejectedAtAnswer e) = toJSON e
instance ToSchema FetchRejectedIntakeRequestsByRejectedAtAnswer where
  declareNamedSchema _ = answerSchema "FetchRejectedIntakeRequestsByRejectedAt"
    [okCase (listOf @RejectedIntakeRequestDTO)]

newtype FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer =
  FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer where
  toJSON (FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer e) = toJSON e
instance ToSchema FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer where
  declareNamedSchema _ = answerSchema "FetchWithdrawnIntakeRequestsByWithdrawnAt"
    [okCase (listOf @WithdrawnIntakeRequestDTO)]

newtype FetchStaleIntakeRequestsByStaleAtAnswer = FetchStaleIntakeRequestsByStaleAtAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchStaleIntakeRequestsByStaleAtAnswer where
  toJSON (FetchStaleIntakeRequestsByStaleAtAnswer e) = toJSON e
instance ToSchema FetchStaleIntakeRequestsByStaleAtAnswer where
  declareNamedSchema _ = answerSchema "FetchStaleIntakeRequestsByStaleAt"
    [okCase (listOf @StaleIntakeRequestDTO)]

newtype FetchClosedIntakeRequestsByStartAnswer = FetchClosedIntakeRequestsByStartAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchClosedIntakeRequestsByStartAnswer where
  toJSON (FetchClosedIntakeRequestsByStartAnswer e) = toJSON e
instance ToSchema FetchClosedIntakeRequestsByStartAnswer where
  declareNamedSchema _ = answerSchema "FetchClosedIntakeRequestsByStart"
    [okCase (listOf @ClosedIntakeRequestDTO)]

newtype FetchDoctorCalendarEntriesOverlappingAnswer =
  FetchDoctorCalendarEntriesOverlappingAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchDoctorCalendarEntriesOverlappingAnswer where
  toJSON (FetchDoctorCalendarEntriesOverlappingAnswer e) = toJSON e
instance ToSchema FetchDoctorCalendarEntriesOverlappingAnswer where
  declareNamedSchema _ = answerSchema "FetchDoctorCalendarEntriesOverlapping"
    [okCase (listOf @DoctorCalendarEntryDTO)]
