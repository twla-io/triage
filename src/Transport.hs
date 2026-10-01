{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DuplicateRecordFields     #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedRecordDot       #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}

-- Derived from src/Domain.hs and src/Service.hs by the triage-api-codegen
-- skill. The wire format: one DTO per Domain.hs type that crosses the wire,
-- one request type per Service function with caller-supplied facts, and
-- one answer type per Service function. Every ToJSON, FromJSON and
-- ToSchema is hand-written, built from one codec per object layout so a
-- key, its schema, its encoding and its decoding are stated once.
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

    -- ── Domain values ────────────────────────────────────────────────────
  , DurationDTO (..)
  , toDomainDuration
  , fromDomainDuration
  , DoctorDTO (..)
  , toDomainDoctor
  , fromDomainDoctor
  , PatientDTO (..)
  , toDomainPatient
  , fromDomainPatient
  , HealthcareServiceDTO (..)
  , toDomainHealthcareService
  , fromDomainHealthcareService
  , DoctorRequirementDTO (..)
  , toDomainDoctorRequirement
  , fromDomainDoctorRequirement
  , MustBeSeenByDTO (..)
  , toDomainMustBeSeenBy
  , fromDomainMustBeSeenBy
  , RoutineWindowDTO (..)        -- holds a RoutineWindow, so mkRoutineWindow has checked it
  , toDomainRoutineWindow
  , fromDomainRoutineWindow
  , RoutineDueDTO (..)
  , toDomainRoutineDue
  , fromDomainRoutineDue
  , IntakeRequestPriorityDTO (..)
  , toDomainIntakeRequestPriority
  , fromDomainIntakeRequestPriority
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
  , WithdrawnIntakeRequestDTO (..)
  , toDomainWithdrawnIntakeRequest
  , fromDomainWithdrawnIntakeRequest
  , WithdrawnFromDTO (..)
  , toDomainWithdrawnFrom
  , fromDomainWithdrawnFrom
  , StaleIntakeRequestDTO (..)
  , toDomainStaleIntakeRequest
  , fromDomainStaleIntakeRequest
  , AppointmentPartyDTO (..)
  , toDomainAppointmentParty
  , fromDomainAppointmentParty
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
  , requestedCloseReason
  , CreateAvailableSlotRequest (..)

    -- ── Answers ──────────────────────────────────────────────────────────
  , Answer (..)
  , Outcomes
  , Ok (..)
  , ServiceErrorDTO (..)
  , TransitionOutcomeDTO (..)
  , MatchOutcomeDTO (..)
  , PriorityMatchOutcomeDTO (..)
  , SlotCreationOutcomeDTO (..)
  , CreateDoctorAnswer
  , CreatePatientAnswer
  , CreateHealthcareServiceAnswer
  , SubmitIntakeRequestAnswer
  , AcceptSubmittedIntakeRequestAnswer
  , RejectSubmittedIntakeRequestAnswer
  , MatchAcceptedIntakeRequestToSlotAnswer
  , WithdrawIntakeRequestAnswer
  , MarkAcceptedIntakeRequestStaleAnswer
  , CloseAppointedIntakeRequestAnswer
  , MatchAvailableSlotByPriorityAnswer
  , CreateAvailableSlotAnswer
  , FetchDoctorAnswer
  , FetchDoctorsAnswer
  , FetchPatientAnswer
  , FetchPatientsAnswer
  , FetchHealthcareServiceAnswer
  , FetchHealthcareServicesAnswer
  , FetchAvailableSlotAnswer
  , FetchIntakeRequestAnswer
  , FetchSubmittedIntakeRequestsAnswer
  , FetchAcceptedIntakeRequestsAnswer
  , FetchAppointedIntakeRequestsAnswer
  , FetchRejectedIntakeRequestsByRejectedAtAnswer
  , FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer
  , FetchStaleIntakeRequestsByStaleAtAnswer
  , FetchClosedIntakeRequestsByStartAnswer
  , FetchDoctorCalendarEntriesOverlappingAnswer
  ) where

import Prelude hiding (id)

import Control.Lens           ((&), (.~), (?~))
import Control.Monad          (ap)
import Data.Aeson             (FromJSON (..), Object, ToJSON (..), Value (..), object, withObject, (.=))
import Data.Aeson.Types       (Pair, Parser, explicitParseField)
import Data.Char              (toLower, toUpper)
import Data.List              (intercalate)
import Data.OpenApi
  ( AdditionalProperties (..), Definitions, Discriminator (..), NamedSchema (..), OpenApiType (..)
  , Reference (..), Referenced (..), Schema, ToParamSchema (..), ToSchema (..)
  , additionalProperties, allOf, declareSchemaRef, discriminator, enum_, format, nullable, oneOf
  , properties, required, type_ )
import Data.OpenApi.Declare   (Declare, declare)
import Data.Proxy             (Proxy (..))
import Data.Text              (Text)
import Data.Time              (UTCTime)
import Data.Traversable       (for)
import Data.Typeable          (Typeable)
import Data.UUID              (UUID)
import GHC.TypeLits           (KnownSymbol, Symbol, symbolVal)
import Web.HttpApiData        (FromHttpApiData (..))

import qualified Data.Aeson.Key             as Key
import qualified Data.Aeson.KeyMap          as KeyMap
import qualified Data.HashMap.Strict.InsOrd as InsOrd
import qualified Data.Text                  as Text

import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- CODECS
-- One object layout: its keys with their schemas, how a value writes them,
-- and how they are read back. A layout has several variants only when it
-- flattens a field whose sum type's cases each carry a stage.
-- ═══════════════════════════════════════════════════════════════════════════

type Defs = Declare (Definitions Schema)

type Props = [(Text, Defs (Referenced Schema))]

-- Reads keys from one object and records which ones it read, so the whole
-- object can be checked for keys nobody asked for.
newtype Fields a = Fields (Object -> Parser (a, [Key.Key]))

instance Functor Fields where
  fmap f (Fields g) = Fields (fmap (\(a, keys) -> (f a, keys)) . g)

instance Applicative Fields where
  pure a = Fields (\_ -> pure (a, []))
  (<*>)  = ap

instance Monad Fields where
  Fields g >>= k = Fields $ \o -> do
    (a, keys)  <- g o
    let Fields h = k a
    (b, keys') <- h o
    pure (b, keys ++ keys')

failFields :: String -> Fields a
failFields message = Fields (\_ -> fail message)

readKey :: (Value -> Parser a) -> Text -> Fields a
readKey parse k = Fields $ \o -> (\a -> (a, [Key.fromText k])) <$> explicitParseField parse o (Key.fromText k)

-- A missing key fails in readKey; an unknown one fails here.
exactly :: Fields a -> Object -> Parser a
exactly (Fields g) o = do
  (a, used) <- g o
  case filter (`notElem` used) (KeyMap.keys o) of
    []      -> pure a
    unknown -> fail ("unknown field(s): " <> intercalate ", " (map (Text.unpack . Key.toText) unknown))

data Codec s a = Codec
  { codecVariants :: [(Text, Props)]   -- (schema-name suffix, keys)
  , codecEncode   :: s -> [Pair]
  , codecDecode   :: Fields a
  }

instance Functor (Codec s) where
  fmap f (Codec variants enc dec) = Codec variants enc (fmap f dec)

instance Applicative (Codec s) where
  pure a = Codec [("", [])] (const []) (pure a)
  Codec v1 e1 d1 <*> Codec v2 e2 d2 =
    Codec [ (n1 <> n2, p1 ++ p2) | (n1, p1) <- v1, (n2, p2) <- v2 ] (\s -> e1 s ++ e2 s) (d1 <*> d2)

-- A required key.
key :: forall s a. (ToJSON a, FromJSON a, ToSchema a) => Text -> (s -> a) -> Codec s a
key k get = Codec
  { codecVariants = [("", [(k, declareSchemaRef (Proxy @a))])]
  , codecEncode   = \s -> [Key.fromText k .= get s]
  , codecDecode   = readKey parseJSON k
  }

-- A Maybe field: the key is always present, its value possibly null.
nullableKey :: forall s a. (ToJSON a, FromJSON a, ToSchema a) => Text -> (s -> Maybe a) -> Codec s (Maybe a)
nullableKey k get = Codec
  { codecVariants = [("", [(k, orNull <$> declareSchemaRef (Proxy @a))])]
  , codecEncode   = \s -> [Key.fromText k .= get s]
  , codecDecode   = readKey parseJSON k
  }
  where
    orNull :: Referenced Schema -> Referenced Schema
    orNull (Inline sch) = Inline (sch & nullable ?~ True)
    orNull (Ref ref)    = Inline (mempty & allOf ?~ [Ref ref] & nullable ?~ True)

-- An embedded stage: its keys join the enclosing object.
embed :: (s -> t) -> Codec t a -> Codec s a
embed get (Codec variants enc dec) = Codec variants (enc . get) dec

-- A decoded value refused by a smart constructor is a parse failure.
refine :: (a -> Either String b) -> Codec s a -> Codec s b
refine check (Codec variants enc dec) = Codec variants enc (dec >>= either failFields pure . check)

-- A field whose sum type's cases each carry a stage: the field keeps only
-- {"type": <case>}, and the case's stage joins the enclosing object.
flattenStages :: Text -> (s -> t) -> Sum t -> Codec s t
flattenStages k get s = Codec
  { codecVariants =
      [ (constructor <> suffix, (k, pure (Inline (objectOf [("type", tagSchema [tagOf constructor])]))) : props)
      | Case (CaseOf constructor codec _) <- sumCases s
      , (suffix, props) <- codecVariants codec ]
  , codecEncode = \x ->
      let (tag, pairs) = sumEncode s (get x)
      in (Key.fromText k .= object ["type" .= tag]) : pairs
  , codecDecode = do
      tag <- readKey (withObject "tag" (exactly (readKey parseJSON "type"))) k
      caseFields s tag
  }

-- ═══════════════════════════════════════════════════════════════════════════
-- RECORDS, SUMS, ENUMERATIONS
-- ═══════════════════════════════════════════════════════════════════════════

recordToJSON :: Codec s s -> s -> Value
recordToJSON codec = object . codecEncode codec

recordParseJSON :: Text -> Codec s s -> Value -> Parser s
recordParseJSON typeName codec = withObject (Text.unpack typeName) (exactly (codecDecode codec))

recordSchema :: Text -> Codec s s -> Defs NamedSchema
recordSchema typeName codec =
  NamedSchema (Just typeName) <$> variantsSchema typeName [] (codecVariants codec)

-- One case of a sum type: its constructor's name, its payload's layout,
-- and how the payload becomes the sum.
data CaseOf p s = CaseOf Text (Codec p p) (p -> s)

data Case s = forall p. Case (CaseOf p s)

data Sum s = Sum
  { sumName   :: Text
  , sumCases  :: [Case s]
  , sumEncode :: s -> (Text, [Pair])   -- written by an exhaustive match, using put
  }

put :: CaseOf p s -> p -> (Text, [Pair])
put (CaseOf constructor codec _) p = (tagOf constructor, codecEncode codec p)

caseFields :: Sum s -> Text -> Fields s
caseFields s tag =
  case [ c | c@(Case (CaseOf constructor _ _)) <- sumCases s, tagOf constructor == tag ] of
    [Case (CaseOf _ codec inject)] -> inject <$> codecDecode codec
    _ -> failFields ("unknown " <> Text.unpack (sumName s) <> " type: " <> Text.unpack tag)

sumToJSON :: Sum s -> s -> Value
sumToJSON s x = let (tag, pairs) = sumEncode s x in object (("type" .= tag) : pairs)

sumParseJSON :: Sum s -> Value -> Parser s
sumParseJSON s = withObject (Text.unpack (sumName s)) $
  exactly (readKey parseJSON "type" >>= caseFields s)

-- oneOf one named schema per case, <Type><Constructor>, discriminated by
-- "type". A case whose keys depend on a nested tag is itself a oneOf of its
-- variants; a discriminator can't map to that, so such a sum has none (each
-- case's one-value "type" enum still tells them apart).
sumSchema :: Sum s -> Defs NamedSchema
sumSchema s = do
  members <- for (sumCases s) $ \(Case (CaseOf constructor codec _)) -> do
    let caseName = sumName s <> constructor
        tag      = tagOf constructor
        variants = codecVariants codec
    schema <- variantsSchema caseName [("type", pure (Inline (tagSchema [tag])))] variants
    declare (InsOrd.singleton caseName schema)
    pure ((tag, caseName), length variants > 1)
  let cases = map fst members
      named
        | any snd members = mempty & oneOf ?~ [ Ref (Reference member) | (_, member) <- cases ]
        | otherwise       = discriminated "type" cases
  pure (NamedSchema (Just (sumName s)) named)

-- An enumeration: an object with only "type".
enumToJSON :: (a -> Text) -> a -> Value
enumToJSON constructor x = object ["type" .= tagOf (constructor x)]

enumParseJSON :: (Bounded a, Enum a) => Text -> (a -> Text) -> Value -> Parser a
enumParseJSON typeName constructor = withObject (Text.unpack typeName) $ exactly $ do
  tag <- readKey parseJSON "type"
  case [ x | x <- [minBound .. maxBound], tagOf (constructor x) == tag ] of
    [x] -> pure x
    _   -> failFields ("unknown " <> Text.unpack typeName <> " type: " <> Text.unpack tag)

enumSchema :: forall a. (Bounded a, Enum a) => Text -> (a -> Text) -> Defs NamedSchema
enumSchema typeName constructor = pure . NamedSchema (Just typeName) $
  objectOf [("type", tagSchema [ tagOf (constructor x) | x <- [minBound .. maxBound :: a] ])]

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

tagOf :: Text -> Text
tagOf t = case Text.uncons t of
  Just (c, rest) -> Text.cons (toLower c) rest
  Nothing        -> t

capitalised :: Text -> Text
capitalised t = case Text.uncons t of
  Just (c, rest) -> Text.cons (toUpper c) rest
  Nothing        -> t

tagSchema :: [Text] -> Schema
tagSchema tags = mempty & type_ ?~ OpenApiString & enum_ ?~ map String tags

-- An object with exactly these keys, all required.
objectOf :: [(Text, Schema)] -> Schema
objectOf props = mempty
  & type_                ?~ OpenApiObject
  & properties           .~ InsOrd.fromList [ (k, Inline s) | (k, s) <- props ]
  & required             .~ map fst props
  & additionalProperties ?~ AdditionalPropertiesAllowed False

objectSchema :: Props -> Defs Schema
objectSchema props = do
  schemas <- traverse snd props
  pure $ mempty
    & type_                ?~ OpenApiObject
    & properties           .~ InsOrd.fromList (zip (map fst props) schemas)
    & required             .~ map fst props
    & additionalProperties ?~ AdditionalPropertiesAllowed False

-- A layout with several variants is oneOf one named schema per variant.
variantsSchema :: Text -> Props -> [(Text, Props)] -> Defs Schema
variantsSchema _    prefix [(_, props)] = objectSchema (prefix ++ props)
variantsSchema typeName prefix variants = do
  names <- for variants $ \(suffix, props) -> do
    schema <- objectSchema (prefix ++ props)
    declare (InsOrd.singleton (typeName <> suffix) schema)
    pure (typeName <> suffix)
  pure (mempty & oneOf ?~ map (Ref . Reference) names)

discriminated :: Text -> [(Text, Text)] -> Schema
discriminated property members = mempty
  & oneOf         ?~ [ Ref (Reference member) | (_, member) <- members ]
  & discriminator ?~ Discriminator property
      (InsOrd.fromList [ (tag, "#/components/schemas/" <> member) | (tag, member) <- members ])

-- The schema of a detail that is always null.
nullSchema :: Schema
nullSchema = mempty & nullable ?~ True & enum_ ?~ [Null]

uuidSchema :: Schema
uuidSchema = mempty & type_ ?~ OpenApiString & format ?~ "uuid"

-- ═══════════════════════════════════════════════════════════════════════════
-- IDS
-- A plain UUID string; each ID type keeps its own schema name.
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorIdDTO            = DoctorIdDTO            UUID deriving (Show, Eq)
newtype PatientIdDTO           = PatientIdDTO           UUID deriving (Show, Eq)
newtype HealthcareServiceIdDTO = HealthcareServiceIdDTO UUID deriving (Show, Eq)
newtype IntakeRequestIdDTO     = IntakeRequestIdDTO     UUID deriving (Show, Eq)
newtype SlotIdDTO              = SlotIdDTO              UUID deriving (Show, Eq)

instance ToJSON   DoctorIdDTO where toJSON (DoctorIdDTO u) = toJSON u
instance FromJSON DoctorIdDTO where parseJSON = fmap DoctorIdDTO . parseJSON
instance ToSchema DoctorIdDTO where declareNamedSchema _ = pure (NamedSchema (Just "DoctorId") uuidSchema)
instance ToParamSchema   DoctorIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData DoctorIdDTO where parseUrlPiece = fmap DoctorIdDTO . parseUrlPiece

instance ToJSON   PatientIdDTO where toJSON (PatientIdDTO u) = toJSON u
instance FromJSON PatientIdDTO where parseJSON = fmap PatientIdDTO . parseJSON
instance ToSchema PatientIdDTO where declareNamedSchema _ = pure (NamedSchema (Just "PatientId") uuidSchema)
instance ToParamSchema   PatientIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData PatientIdDTO where parseUrlPiece = fmap PatientIdDTO . parseUrlPiece

instance ToJSON   HealthcareServiceIdDTO where toJSON (HealthcareServiceIdDTO u) = toJSON u
instance FromJSON HealthcareServiceIdDTO where parseJSON = fmap HealthcareServiceIdDTO . parseJSON
instance ToSchema HealthcareServiceIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "HealthcareServiceId") uuidSchema)
instance ToParamSchema   HealthcareServiceIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData HealthcareServiceIdDTO where parseUrlPiece = fmap HealthcareServiceIdDTO . parseUrlPiece

instance ToJSON   IntakeRequestIdDTO where toJSON (IntakeRequestIdDTO u) = toJSON u
instance FromJSON IntakeRequestIdDTO where parseJSON = fmap IntakeRequestIdDTO . parseJSON
instance ToSchema IntakeRequestIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "IntakeRequestId") uuidSchema)
instance ToParamSchema   IntakeRequestIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData IntakeRequestIdDTO where parseUrlPiece = fmap IntakeRequestIdDTO . parseUrlPiece

instance ToJSON   SlotIdDTO where toJSON (SlotIdDTO u) = toJSON u
instance FromJSON SlotIdDTO where parseJSON = fmap SlotIdDTO . parseJSON
instance ToSchema SlotIdDTO where declareNamedSchema _ = pure (NamedSchema (Just "SlotId") uuidSchema)
instance ToParamSchema   SlotIdDTO where toParamSchema _ = uuidSchema
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
-- DURATION (enumeration)
-- ═══════════════════════════════════════════════════════════════════════════

data DurationDTO
  = QuarterOfAnHourDTO
  | HalfAnHourDTO
  | OneHourDTO
  deriving (Show, Eq, Enum, Bounded)

durationConstructor :: DurationDTO -> Text
durationConstructor = \case
  QuarterOfAnHourDTO -> "QuarterOfAnHour"
  HalfAnHourDTO      -> "HalfAnHour"
  OneHourDTO         -> "OneHour"

instance ToJSON   DurationDTO where toJSON = enumToJSON durationConstructor
instance FromJSON DurationDTO where parseJSON = enumParseJSON "Duration" durationConstructor
instance ToSchema DurationDTO where declareNamedSchema _ = enumSchema "Duration" durationConstructor

toDomainDuration :: DurationDTO -> Duration
toDomainDuration = \case
  QuarterOfAnHourDTO -> QuarterOfAnHour
  HalfAnHourDTO      -> HalfAnHour
  OneHourDTO         -> OneHour

fromDomainDuration :: Duration -> DurationDTO
fromDomainDuration = \case
  QuarterOfAnHour -> QuarterOfAnHourDTO
  HalfAnHour      -> HalfAnHourDTO
  OneHour         -> OneHourDTO

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT
-- ═══════════════════════════════════════════════════════════════════════════

data DoctorDTO = DoctorDTO
  { id   :: DoctorIdDTO
  , name :: Text
  }
  deriving (Show, Eq)

doctorCodec :: Codec DoctorDTO DoctorDTO
doctorCodec = DoctorDTO <$> key "id" (.id) <*> key "name" (.name)

instance ToJSON   DoctorDTO where toJSON = recordToJSON doctorCodec
instance FromJSON DoctorDTO where parseJSON = recordParseJSON "Doctor" doctorCodec
instance ToSchema DoctorDTO where declareNamedSchema _ = recordSchema "Doctor" doctorCodec

toDomainDoctor :: DoctorDTO -> Doctor
toDomainDoctor d = Doctor { id = toDomainDoctorId d.id, name = d.name }

fromDomainDoctor :: Doctor -> DoctorDTO
fromDomainDoctor d = DoctorDTO { id = fromDomainDoctorId d.id, name = d.name }

data PatientDTO = PatientDTO
  { id   :: PatientIdDTO
  , name :: Text
  }
  deriving (Show, Eq)

patientCodec :: Codec PatientDTO PatientDTO
patientCodec = PatientDTO <$> key "id" (.id) <*> key "name" (.name)

instance ToJSON   PatientDTO where toJSON = recordToJSON patientCodec
instance FromJSON PatientDTO where parseJSON = recordParseJSON "Patient" patientCodec
instance ToSchema PatientDTO where declareNamedSchema _ = recordSchema "Patient" patientCodec

toDomainPatient :: PatientDTO -> Patient
toDomainPatient p = Patient { id = toDomainPatientId p.id, name = p.name }

fromDomainPatient :: Patient -> PatientDTO
fromDomainPatient p = PatientDTO { id = fromDomainPatientId p.id, name = p.name }

-- ═══════════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICE
-- ═══════════════════════════════════════════════════════════════════════════

data HealthcareServiceDTO = HealthcareServiceDTO
  { id       :: HealthcareServiceIdDTO
  , name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

healthcareServiceCodec :: Codec HealthcareServiceDTO HealthcareServiceDTO
healthcareServiceCodec = HealthcareServiceDTO
  <$> key "id"       (.id)
  <*> key "name"     (.name)
  <*> key "duration" (.duration)

instance ToJSON   HealthcareServiceDTO where toJSON = recordToJSON healthcareServiceCodec
instance FromJSON HealthcareServiceDTO where
  parseJSON = recordParseJSON "HealthcareService" healthcareServiceCodec
instance ToSchema HealthcareServiceDTO where
  declareNamedSchema _ = recordSchema "HealthcareService" healthcareServiceCodec

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
  = AnyDoctorDTO
  | SpecificDoctorDTO DoctorIdDTO
  deriving (Show, Eq)

doctorRequirementSum :: Sum DoctorRequirementDTO
doctorRequirementSum = Sum "DoctorRequirement" [Case anyDoctor, Case specificDoctor] $ \case
    AnyDoctorDTO        -> put anyDoctor ()
    SpecificDoctorDTO d -> put specificDoctor d
  where
    anyDoctor      = CaseOf "AnyDoctor" (pure ()) (const AnyDoctorDTO)
    specificDoctor = CaseOf "SpecificDoctor" (key "specificDoctor" (\d -> d)) SpecificDoctorDTO

instance ToJSON   DoctorRequirementDTO where toJSON = sumToJSON doctorRequirementSum
instance FromJSON DoctorRequirementDTO where parseJSON = sumParseJSON doctorRequirementSum
instance ToSchema DoctorRequirementDTO where declareNamedSchema _ = sumSchema doctorRequirementSum

toDomainDoctorRequirement :: DoctorRequirementDTO -> DoctorRequirement
toDomainDoctorRequirement = \case
  AnyDoctorDTO        -> AnyDoctor
  SpecificDoctorDTO d -> SpecificDoctor (toDomainDoctorId d)

fromDomainDoctorRequirement :: DoctorRequirement -> DoctorRequirementDTO
fromDomainDoctorRequirement = \case
  AnyDoctor        -> AnyDoctorDTO
  SpecificDoctor d -> SpecificDoctorDTO (fromDomainDoctorId d)

-- ═══════════════════════════════════════════════════════════════════════════
-- PRIORITY / DUE CONSTRAINTS
-- ═══════════════════════════════════════════════════════════════════════════

newtype MustBeSeenByDTO = MustBeSeenByDTO UTCTime
  deriving (Show, Eq)

mustBeSeenByCodec :: Codec MustBeSeenByDTO MustBeSeenByDTO
mustBeSeenByCodec = MustBeSeenByDTO <$> key "mustBeSeenBy" (\(MustBeSeenByDTO t) -> t)

instance ToJSON   MustBeSeenByDTO where toJSON = recordToJSON mustBeSeenByCodec
instance FromJSON MustBeSeenByDTO where parseJSON = recordParseJSON "MustBeSeenBy" mustBeSeenByCodec
instance ToSchema MustBeSeenByDTO where declareNamedSchema _ = recordSchema "MustBeSeenBy" mustBeSeenByCodec

toDomainMustBeSeenBy :: MustBeSeenByDTO -> MustBeSeenBy
toDomainMustBeSeenBy (MustBeSeenByDTO t) = MustBeSeenBy t

fromDomainMustBeSeenBy :: MustBeSeenBy -> MustBeSeenByDTO
fromDomainMustBeSeenBy (MustBeSeenBy t) = MustBeSeenByDTO t

-- Sealed in Domain.hs: decoded only through mkRoutineWindow, so the DTO
-- holds a value that has passed it.
newtype RoutineWindowDTO = RoutineWindowDTO RoutineWindow
  deriving (Show, Eq)

routineWindowCodec :: Codec RoutineWindowDTO RoutineWindowDTO
routineWindowCodec = refine checked $ (,)
  <$> key "routineNotBefore" (\(RoutineWindowDTO w) -> routineNotBefore w)
  <*> key "routineNotAfter"  (\(RoutineWindowDTO w) -> routineNotAfter w)
  where
    checked (notBefore, notAfter) =
      maybe (Left "routineNotBefore must not be after routineNotAfter") (Right . RoutineWindowDTO)
        (mkRoutineWindow notBefore notAfter)

instance ToJSON   RoutineWindowDTO where toJSON = recordToJSON routineWindowCodec
instance FromJSON RoutineWindowDTO where parseJSON = recordParseJSON "RoutineWindow" routineWindowCodec
instance ToSchema RoutineWindowDTO where declareNamedSchema _ = recordSchema "RoutineWindow" routineWindowCodec

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

routineDueSum :: Sum RoutineDueDTO
routineDueSum =
  Sum "RoutineDue" [Case anytime, Case notBefore, Case notAfter, Case within] $ \case
    RoutineAnytimeDTO     -> put anytime ()
    RoutineNotBeforeDTO t -> put notBefore t
    RoutineNotAfterDTO  t -> put notAfter t
    RoutineWithinDTO    w -> put within w
  where
    anytime   = CaseOf "RoutineAnytime" (pure ()) (const RoutineAnytimeDTO)
    notBefore = CaseOf "RoutineNotBefore" (key "routineNotBefore" (\t -> t)) RoutineNotBeforeDTO
    notAfter  = CaseOf "RoutineNotAfter" (key "routineNotAfter" (\t -> t)) RoutineNotAfterDTO
    within    = CaseOf "RoutineWithin" routineWindowCodec RoutineWithinDTO

instance ToJSON   RoutineDueDTO where toJSON = sumToJSON routineDueSum
instance FromJSON RoutineDueDTO where parseJSON = sumParseJSON routineDueSum
instance ToSchema RoutineDueDTO where declareNamedSchema _ = sumSchema routineDueSum

toDomainRoutineDue :: RoutineDueDTO -> RoutineDue
toDomainRoutineDue = \case
  RoutineAnytimeDTO     -> RoutineAnytime
  RoutineNotBeforeDTO t -> RoutineNotBefore t
  RoutineNotAfterDTO  t -> RoutineNotAfter t
  RoutineWithinDTO    w -> RoutineWithin (toDomainRoutineWindow w)

fromDomainRoutineDue :: RoutineDue -> RoutineDueDTO
fromDomainRoutineDue = \case
  RoutineAnytime     -> RoutineAnytimeDTO
  RoutineNotBefore t -> RoutineNotBeforeDTO t
  RoutineNotAfter  t -> RoutineNotAfterDTO t
  RoutineWithin    w -> RoutineWithinDTO (fromDomainRoutineWindow w)

data IntakeRequestPriorityDTO
  = EmergencyDTO MustBeSeenByDTO
  | UrgentDTO    MustBeSeenByDTO
  | RoutineDTO   RoutineDueDTO
  deriving (Show, Eq)

-- Routine's payload is a sum type, so it nests under "routine".
intakeRequestPrioritySum :: Sum IntakeRequestPriorityDTO
intakeRequestPrioritySum =
  Sum "IntakeRequestPriority" [Case emergency, Case urgent, Case routine] $ \case
    EmergencyDTO d -> put emergency d
    UrgentDTO    d -> put urgent d
    RoutineDTO   d -> put routine d
  where
    emergency = CaseOf "Emergency" mustBeSeenByCodec EmergencyDTO
    urgent    = CaseOf "Urgent" mustBeSeenByCodec UrgentDTO
    routine   = CaseOf "Routine" (key "routine" (\d -> d)) RoutineDTO

instance ToJSON   IntakeRequestPriorityDTO where toJSON = sumToJSON intakeRequestPrioritySum
instance FromJSON IntakeRequestPriorityDTO where parseJSON = sumParseJSON intakeRequestPrioritySum
instance ToSchema IntakeRequestPriorityDTO where declareNamedSchema _ = sumSchema intakeRequestPrioritySum

toDomainIntakeRequestPriority :: IntakeRequestPriorityDTO -> IntakeRequestPriority
toDomainIntakeRequestPriority = \case
  EmergencyDTO d -> Emergency (toDomainMustBeSeenBy d)
  UrgentDTO    d -> Urgent (toDomainMustBeSeenBy d)
  RoutineDTO   d -> Routine (toDomainRoutineDue d)

fromDomainIntakeRequestPriority :: IntakeRequestPriority -> IntakeRequestPriorityDTO
fromDomainIntakeRequestPriority = \case
  Emergency d -> EmergencyDTO (fromDomainMustBeSeenBy d)
  Urgent    d -> UrgentDTO (fromDomainMustBeSeenBy d)
  Routine   d -> RoutineDTO (fromDomainRoutineDue d)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST STAGES
-- Each stage's object carries its own keys and every key of the stage it
-- embeds.
-- ═══════════════════════════════════════════════════════════════════════════

data SubmittedIntakeRequestDTO = SubmittedIntakeRequestDTO
  { id        :: IntakeRequestIdDTO
  , patientId :: PatientIdDTO
  , narrative :: Text
  , createdAt :: UTCTime
  }
  deriving (Show, Eq)

submittedIntakeRequestCodec :: Codec SubmittedIntakeRequestDTO SubmittedIntakeRequestDTO
submittedIntakeRequestCodec = SubmittedIntakeRequestDTO
  <$> key "id"        (.id)
  <*> key "patientId" (.patientId)
  <*> key "narrative" (.narrative)
  <*> key "createdAt" (.createdAt)

instance ToJSON   SubmittedIntakeRequestDTO where toJSON = recordToJSON submittedIntakeRequestCodec
instance FromJSON SubmittedIntakeRequestDTO where
  parseJSON = recordParseJSON "SubmittedIntakeRequest" submittedIntakeRequestCodec
instance ToSchema SubmittedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "SubmittedIntakeRequest" submittedIntakeRequestCodec

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

rejectedIntakeRequestCodec :: Codec RejectedIntakeRequestDTO RejectedIntakeRequestDTO
rejectedIntakeRequestCodec = RejectedIntakeRequestDTO
  <$> embed (.submitted) submittedIntakeRequestCodec
  <*> key "rejectedAt"      (.rejectedAt)
  <*> key "rejectionReason" (.rejectionReason)

instance ToJSON   RejectedIntakeRequestDTO where toJSON = recordToJSON rejectedIntakeRequestCodec
instance FromJSON RejectedIntakeRequestDTO where
  parseJSON = recordParseJSON "RejectedIntakeRequest" rejectedIntakeRequestCodec
instance ToSchema RejectedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "RejectedIntakeRequest" rejectedIntakeRequestCodec

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

triagedIntakeRequestCodec :: Codec TriagedIntakeRequestDTO TriagedIntakeRequestDTO
triagedIntakeRequestCodec = TriagedIntakeRequestDTO
  <$> embed (.submitted) submittedIntakeRequestCodec
  <*> key "healthcareServiceId" (.healthcareServiceId)
  <*> key "priority"            (.priority)
  <*> key "doctorRequirement"   (.doctorRequirement)
  <*> key "triagedAt"           (.triagedAt)

instance ToJSON   TriagedIntakeRequestDTO where toJSON = recordToJSON triagedIntakeRequestCodec
instance FromJSON TriagedIntakeRequestDTO where
  parseJSON = recordParseJSON "TriagedIntakeRequest" triagedIntakeRequestCodec
instance ToSchema TriagedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "TriagedIntakeRequest" triagedIntakeRequestCodec

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

appointedIntakeRequestCodec :: Codec AppointedIntakeRequestDTO AppointedIntakeRequestDTO
appointedIntakeRequestCodec = AppointedIntakeRequestDTO
  <$> embed (.triaged) triagedIntakeRequestCodec
  <*> key "doctorId" (.doctorId)
  <*> key "start"    (.start)
  <*> key "duration" (.duration)

instance ToJSON   AppointedIntakeRequestDTO where toJSON = recordToJSON appointedIntakeRequestCodec
instance FromJSON AppointedIntakeRequestDTO where
  parseJSON = recordParseJSON "AppointedIntakeRequest" appointedIntakeRequestCodec
instance ToSchema AppointedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "AppointedIntakeRequest" appointedIntakeRequestCodec

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

-- Each case carries a stage, so where it is a field it is flattened:
-- WithdrawnIntakeRequest keeps {"withdrawnFrom": {"type": …}} and the
-- stage's keys join its object.
data WithdrawnFromDTO
  = FromSubmittedDTO SubmittedIntakeRequestDTO
  | FromAcceptedDTO  TriagedIntakeRequestDTO
  deriving (Show, Eq)

withdrawnFromSum :: Sum WithdrawnFromDTO
withdrawnFromSum = Sum "WithdrawnFrom" [Case fromSubmitted, Case fromAccepted] $ \case
    FromSubmittedDTO s -> put fromSubmitted s
    FromAcceptedDTO  t -> put fromAccepted t
  where
    fromSubmitted = CaseOf "FromSubmitted" submittedIntakeRequestCodec FromSubmittedDTO
    fromAccepted  = CaseOf "FromAccepted" triagedIntakeRequestCodec FromAcceptedDTO

instance ToJSON   WithdrawnFromDTO where toJSON = sumToJSON withdrawnFromSum
instance FromJSON WithdrawnFromDTO where parseJSON = sumParseJSON withdrawnFromSum
instance ToSchema WithdrawnFromDTO where declareNamedSchema _ = sumSchema withdrawnFromSum

toDomainWithdrawnFrom :: WithdrawnFromDTO -> WithdrawnFrom
toDomainWithdrawnFrom = \case
  FromSubmittedDTO s -> FromSubmitted (toDomainSubmittedIntakeRequest s)
  FromAcceptedDTO  t -> FromAccepted (toDomainTriagedIntakeRequest t)

fromDomainWithdrawnFrom :: WithdrawnFrom -> WithdrawnFromDTO
fromDomainWithdrawnFrom = \case
  FromSubmitted s -> FromSubmittedDTO (fromDomainSubmittedIntakeRequest s)
  FromAccepted  t -> FromAcceptedDTO (fromDomainTriagedIntakeRequest t)

data WithdrawnIntakeRequestDTO = WithdrawnIntakeRequestDTO
  { withdrawnFrom  :: WithdrawnFromDTO
  , withdrawnAt    :: UTCTime
  , withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

withdrawnIntakeRequestCodec :: Codec WithdrawnIntakeRequestDTO WithdrawnIntakeRequestDTO
withdrawnIntakeRequestCodec = WithdrawnIntakeRequestDTO
  <$> flattenStages "withdrawnFrom" (.withdrawnFrom) withdrawnFromSum
  <*> key "withdrawnAt"            (.withdrawnAt)
  <*> nullableKey "withdrawalNote" (.withdrawalNote)

instance ToJSON   WithdrawnIntakeRequestDTO where toJSON = recordToJSON withdrawnIntakeRequestCodec
instance FromJSON WithdrawnIntakeRequestDTO where
  parseJSON = recordParseJSON "WithdrawnIntakeRequest" withdrawnIntakeRequestCodec
instance ToSchema WithdrawnIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "WithdrawnIntakeRequest" withdrawnIntakeRequestCodec

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

staleIntakeRequestCodec :: Codec StaleIntakeRequestDTO StaleIntakeRequestDTO
staleIntakeRequestCodec = StaleIntakeRequestDTO
  <$> embed (.triaged) triagedIntakeRequestCodec
  <*> key "staleAt" (.staleAt)

instance ToJSON   StaleIntakeRequestDTO where toJSON = recordToJSON staleIntakeRequestCodec
instance FromJSON StaleIntakeRequestDTO where
  parseJSON = recordParseJSON "StaleIntakeRequest" staleIntakeRequestCodec
instance ToSchema StaleIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "StaleIntakeRequest" staleIntakeRequestCodec

toDomainStaleIntakeRequest :: StaleIntakeRequestDTO -> StaleIntakeRequest
toDomainStaleIntakeRequest s = StaleIntakeRequest
  { triaged = toDomainTriagedIntakeRequest s.triaged, staleAt = s.staleAt }

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> StaleIntakeRequestDTO
fromDomainStaleIntakeRequest s = StaleIntakeRequestDTO
  { triaged = fromDomainTriagedIntakeRequest s.triaged, staleAt = s.staleAt }

-- ═══════════════════════════════════════════════════════════════════════════
-- CLOSING
-- ═══════════════════════════════════════════════════════════════════════════

data AppointmentPartyDTO
  = DoctorPartyDTO
  | PatientPartyDTO
  deriving (Show, Eq, Enum, Bounded)

appointmentPartyConstructor :: AppointmentPartyDTO -> Text
appointmentPartyConstructor = \case
  DoctorPartyDTO  -> "DoctorParty"
  PatientPartyDTO -> "PatientParty"

instance ToJSON   AppointmentPartyDTO where toJSON = enumToJSON appointmentPartyConstructor
instance FromJSON AppointmentPartyDTO where
  parseJSON = enumParseJSON "AppointmentParty" appointmentPartyConstructor
instance ToSchema AppointmentPartyDTO where
  declareNamedSchema _ = enumSchema "AppointmentParty" appointmentPartyConstructor

toDomainAppointmentParty :: AppointmentPartyDTO -> AppointmentParty
toDomainAppointmentParty = \case
  DoctorPartyDTO  -> DoctorParty
  PatientPartyDTO -> PatientParty

fromDomainAppointmentParty :: AppointmentParty -> AppointmentPartyDTO
fromDomainAppointmentParty = \case
  DoctorParty  -> DoctorPartyDTO
  PatientParty -> PatientPartyDTO

data CancellationDTO = CancellationDTO
  { cancelledBy      :: AppointmentPartyDTO
  , cancelledAt      :: UTCTime
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

cancellationCodec :: Codec CancellationDTO CancellationDTO
cancellationCodec = CancellationDTO
  <$> key "cancelledBy"              (.cancelledBy)
  <*> key "cancelledAt"              (.cancelledAt)
  <*> nullableKey "cancellationNote" (.cancellationNote)

instance ToJSON   CancellationDTO where toJSON = recordToJSON cancellationCodec
instance FromJSON CancellationDTO where parseJSON = recordParseJSON "Cancellation" cancellationCodec
instance ToSchema CancellationDTO where declareNamedSchema _ = recordSchema "Cancellation" cancellationCodec

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

absenceCodec :: Codec AbsenceDTO AbsenceDTO
absenceCodec = AbsenceDTO <$> key "absentParty" (.absentParty)

instance ToJSON   AbsenceDTO where toJSON = recordToJSON absenceCodec
instance FromJSON AbsenceDTO where parseJSON = recordParseJSON "Absence" absenceCodec
instance ToSchema AbsenceDTO where declareNamedSchema _ = recordSchema "Absence" absenceCodec

toDomainAbsence :: AbsenceDTO -> Absence
toDomainAbsence a = Absence { absentParty = toDomainAppointmentParty a.absentParty }

fromDomainAbsence :: Absence -> AbsenceDTO
fromDomainAbsence a = AbsenceDTO { absentParty = fromDomainAppointmentParty a.absentParty }

data CloseReasonDTO
  = CompletedDTO
  | CancelledDTO CancellationDTO
  | NoShowDTO    AbsenceDTO
  deriving (Show, Eq)

closeReasonSum :: Sum CloseReasonDTO
closeReasonSum = Sum "CloseReason" [Case completed, Case cancelled, Case noShow] $ \case
    CompletedDTO   -> put completed ()
    CancelledDTO c -> put cancelled c
    NoShowDTO    a -> put noShow a
  where
    completed = CaseOf "Completed" (pure ()) (const CompletedDTO)
    cancelled = CaseOf "Cancelled" cancellationCodec CancelledDTO
    noShow    = CaseOf "NoShow" absenceCodec NoShowDTO

instance ToJSON   CloseReasonDTO where toJSON = sumToJSON closeReasonSum
instance FromJSON CloseReasonDTO where parseJSON = sumParseJSON closeReasonSum
instance ToSchema CloseReasonDTO where declareNamedSchema _ = sumSchema closeReasonSum

toDomainCloseReason :: CloseReasonDTO -> CloseReason
toDomainCloseReason = \case
  CompletedDTO   -> Completed
  CancelledDTO c -> Cancelled (toDomainCancellation c)
  NoShowDTO    a -> NoShow (toDomainAbsence a)

fromDomainCloseReason :: CloseReason -> CloseReasonDTO
fromDomainCloseReason = \case
  Completed   -> CompletedDTO
  Cancelled c -> CancelledDTO (fromDomainCancellation c)
  NoShow    a -> NoShowDTO (fromDomainAbsence a)

data ClosedIntakeRequestDTO = ClosedIntakeRequestDTO
  { appointed   :: AppointedIntakeRequestDTO
  , closeReason :: CloseReasonDTO
  }
  deriving (Show, Eq)

closedIntakeRequestCodec :: Codec ClosedIntakeRequestDTO ClosedIntakeRequestDTO
closedIntakeRequestCodec = ClosedIntakeRequestDTO
  <$> embed (.appointed) appointedIntakeRequestCodec
  <*> key "closeReason" (.closeReason)

instance ToJSON   ClosedIntakeRequestDTO where toJSON = recordToJSON closedIntakeRequestCodec
instance FromJSON ClosedIntakeRequestDTO where
  parseJSON = recordParseJSON "ClosedIntakeRequest" closedIntakeRequestCodec
instance ToSchema ClosedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "ClosedIntakeRequest" closedIntakeRequestCodec

toDomainClosedIntakeRequest :: ClosedIntakeRequestDTO -> ClosedIntakeRequest
toDomainClosedIntakeRequest c = ClosedIntakeRequest
  { appointed = toDomainAppointedIntakeRequest c.appointed, closeReason = toDomainCloseReason c.closeReason }

fromDomainClosedIntakeRequest :: ClosedIntakeRequest -> ClosedIntakeRequestDTO
fromDomainClosedIntakeRequest c = ClosedIntakeRequestDTO
  { appointed = fromDomainAppointedIntakeRequest c.appointed, closeReason = fromDomainCloseReason c.closeReason }

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

intakeRequestSum :: Sum IntakeRequestDTO
intakeRequestSum =
  Sum "IntakeRequest"
    [ Case submittedCase, Case rejectedCase, Case acceptedCase, Case appointedCase
    , Case withdrawnCase, Case staleCase, Case closedCase ] $ \case
    SubmittedDTO r -> put submittedCase r
    RejectedDTO  r -> put rejectedCase r
    AcceptedDTO  r -> put acceptedCase r
    AppointedDTO r -> put appointedCase r
    WithdrawnDTO r -> put withdrawnCase r
    StaleDTO     r -> put staleCase r
    ClosedDTO    r -> put closedCase r
  where
    submittedCase = CaseOf "Submitted" submittedIntakeRequestCodec SubmittedDTO
    rejectedCase  = CaseOf "Rejected" rejectedIntakeRequestCodec RejectedDTO
    acceptedCase  = CaseOf "Accepted" triagedIntakeRequestCodec AcceptedDTO
    appointedCase = CaseOf "Appointed" appointedIntakeRequestCodec AppointedDTO
    withdrawnCase = CaseOf "Withdrawn" withdrawnIntakeRequestCodec WithdrawnDTO
    staleCase     = CaseOf "Stale" staleIntakeRequestCodec StaleDTO
    closedCase    = CaseOf "Closed" closedIntakeRequestCodec ClosedDTO

instance ToJSON   IntakeRequestDTO where toJSON = sumToJSON intakeRequestSum
instance FromJSON IntakeRequestDTO where parseJSON = sumParseJSON intakeRequestSum
instance ToSchema IntakeRequestDTO where declareNamedSchema _ = sumSchema intakeRequestSum

toDomainIntakeRequest :: IntakeRequestDTO -> IntakeRequest
toDomainIntakeRequest = \case
  SubmittedDTO r -> Submitted (toDomainSubmittedIntakeRequest r)
  RejectedDTO  r -> Rejected (toDomainRejectedIntakeRequest r)
  AcceptedDTO  r -> Accepted (toDomainTriagedIntakeRequest r)
  AppointedDTO r -> Appointed (toDomainAppointedIntakeRequest r)
  WithdrawnDTO r -> Withdrawn (toDomainWithdrawnIntakeRequest r)
  StaleDTO     r -> Stale (toDomainStaleIntakeRequest r)
  ClosedDTO    r -> Closed (toDomainClosedIntakeRequest r)

fromDomainIntakeRequest :: IntakeRequest -> IntakeRequestDTO
fromDomainIntakeRequest = \case
  Submitted r -> SubmittedDTO (fromDomainSubmittedIntakeRequest r)
  Rejected  r -> RejectedDTO (fromDomainRejectedIntakeRequest r)
  Accepted  r -> AcceptedDTO (fromDomainTriagedIntakeRequest r)
  Appointed r -> AppointedDTO (fromDomainAppointedIntakeRequest r)
  Withdrawn r -> WithdrawnDTO (fromDomainWithdrawnIntakeRequest r)
  Stale     r -> StaleDTO (fromDomainStaleIntakeRequest r)
  Closed    r -> ClosedDTO (fromDomainClosedIntakeRequest r)

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

availableSlotCodec :: Codec AvailableSlotDTO AvailableSlotDTO
availableSlotCodec = AvailableSlotDTO
  <$> key "id"                  (.id)
  <*> key "doctorId"            (.doctorId)
  <*> key "healthcareServiceId" (.healthcareServiceId)
  <*> key "start"               (.start)
  <*> key "duration"            (.duration)

instance ToJSON   AvailableSlotDTO where toJSON = recordToJSON availableSlotCodec
instance FromJSON AvailableSlotDTO where parseJSON = recordParseJSON "AvailableSlot" availableSlotCodec
instance ToSchema AvailableSlotDTO where declareNamedSchema _ = recordSchema "AvailableSlot" availableSlotCodec

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

doctorCalendarEntrySum :: Sum DoctorCalendarEntryDTO
doctorCalendarEntrySum = Sum "DoctorCalendarEntry" [Case slot, Case appointment] $ \case
    SlotDTO        s -> put slot s
    AppointmentDTO a -> put appointment a
  where
    slot        = CaseOf "Slot" availableSlotCodec SlotDTO
    appointment = CaseOf "Appointment" appointedIntakeRequestCodec AppointmentDTO

instance ToJSON   DoctorCalendarEntryDTO where toJSON = sumToJSON doctorCalendarEntrySum
instance FromJSON DoctorCalendarEntryDTO where parseJSON = sumParseJSON doctorCalendarEntrySum
instance ToSchema DoctorCalendarEntryDTO where declareNamedSchema _ = sumSchema doctorCalendarEntrySum

toDomainDoctorCalendarEntry :: DoctorCalendarEntryDTO -> DoctorCalendarEntry
toDomainDoctorCalendarEntry = \case
  SlotDTO        s -> Slot (toDomainAvailableSlot s)
  AppointmentDTO a -> Appointment (toDomainAppointedIntakeRequest a)

fromDomainDoctorCalendarEntry :: DoctorCalendarEntry -> DoctorCalendarEntryDTO
fromDomainDoctorCalendarEntry = \case
  Slot        s -> SlotDTO (fromDomainAvailableSlot s)
  Appointment a -> AppointmentDTO (fromDomainAppointedIntakeRequest a)

-- ═══════════════════════════════════════════════════════════════════════════
-- REQUEST BODIES
-- Exactly a Service function's caller-supplied facts, keyed by the Domain
-- fields they land in. Times the server records are not among them.
-- ═══════════════════════════════════════════════════════════════════════════

newtype CreateDoctorRequest = CreateDoctorRequest
  { name :: Text
  }
  deriving (Show, Eq)

createDoctorRequestCodec :: Codec CreateDoctorRequest CreateDoctorRequest
createDoctorRequestCodec = CreateDoctorRequest <$> key "name" (.name)

instance ToJSON   CreateDoctorRequest where toJSON = recordToJSON createDoctorRequestCodec
instance FromJSON CreateDoctorRequest where
  parseJSON = recordParseJSON "CreateDoctorRequest" createDoctorRequestCodec
instance ToSchema CreateDoctorRequest where
  declareNamedSchema _ = recordSchema "CreateDoctorRequest" createDoctorRequestCodec

newtype CreatePatientRequest = CreatePatientRequest
  { name :: Text
  }
  deriving (Show, Eq)

createPatientRequestCodec :: Codec CreatePatientRequest CreatePatientRequest
createPatientRequestCodec = CreatePatientRequest <$> key "name" (.name)

instance ToJSON   CreatePatientRequest where toJSON = recordToJSON createPatientRequestCodec
instance FromJSON CreatePatientRequest where
  parseJSON = recordParseJSON "CreatePatientRequest" createPatientRequestCodec
instance ToSchema CreatePatientRequest where
  declareNamedSchema _ = recordSchema "CreatePatientRequest" createPatientRequestCodec

data CreateHealthcareServiceRequest = CreateHealthcareServiceRequest
  { name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

createHealthcareServiceRequestCodec :: Codec CreateHealthcareServiceRequest CreateHealthcareServiceRequest
createHealthcareServiceRequestCodec = CreateHealthcareServiceRequest
  <$> key "name"     (.name)
  <*> key "duration" (.duration)

instance ToJSON   CreateHealthcareServiceRequest where toJSON = recordToJSON createHealthcareServiceRequestCodec
instance FromJSON CreateHealthcareServiceRequest where
  parseJSON = recordParseJSON "CreateHealthcareServiceRequest" createHealthcareServiceRequestCodec
instance ToSchema CreateHealthcareServiceRequest where
  declareNamedSchema _ = recordSchema "CreateHealthcareServiceRequest" createHealthcareServiceRequestCodec

data SubmitIntakeRequestRequest = SubmitIntakeRequestRequest
  { patientId :: PatientIdDTO
  , narrative :: Text
  }
  deriving (Show, Eq)

submitIntakeRequestRequestCodec :: Codec SubmitIntakeRequestRequest SubmitIntakeRequestRequest
submitIntakeRequestRequestCodec = SubmitIntakeRequestRequest
  <$> key "patientId" (.patientId)
  <*> key "narrative" (.narrative)

instance ToJSON   SubmitIntakeRequestRequest where toJSON = recordToJSON submitIntakeRequestRequestCodec
instance FromJSON SubmitIntakeRequestRequest where
  parseJSON = recordParseJSON "SubmitIntakeRequestRequest" submitIntakeRequestRequestCodec
instance ToSchema SubmitIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "SubmitIntakeRequestRequest" submitIntakeRequestRequestCodec

data AcceptSubmittedIntakeRequestRequest = AcceptSubmittedIntakeRequestRequest
  { healthcareServiceId :: HealthcareServiceIdDTO
  , priority            :: IntakeRequestPriorityDTO
  , doctorRequirement   :: DoctorRequirementDTO
  }
  deriving (Show, Eq)

acceptSubmittedIntakeRequestRequestCodec
  :: Codec AcceptSubmittedIntakeRequestRequest AcceptSubmittedIntakeRequestRequest
acceptSubmittedIntakeRequestRequestCodec = AcceptSubmittedIntakeRequestRequest
  <$> key "healthcareServiceId" (.healthcareServiceId)
  <*> key "priority"            (.priority)
  <*> key "doctorRequirement"   (.doctorRequirement)

instance ToJSON   AcceptSubmittedIntakeRequestRequest where
  toJSON = recordToJSON acceptSubmittedIntakeRequestRequestCodec
instance FromJSON AcceptSubmittedIntakeRequestRequest where
  parseJSON = recordParseJSON "AcceptSubmittedIntakeRequestRequest" acceptSubmittedIntakeRequestRequestCodec
instance ToSchema AcceptSubmittedIntakeRequestRequest where
  declareNamedSchema _ =
    recordSchema "AcceptSubmittedIntakeRequestRequest" acceptSubmittedIntakeRequestRequestCodec

newtype RejectSubmittedIntakeRequestRequest = RejectSubmittedIntakeRequestRequest
  { rejectionReason :: Text
  }
  deriving (Show, Eq)

rejectSubmittedIntakeRequestRequestCodec
  :: Codec RejectSubmittedIntakeRequestRequest RejectSubmittedIntakeRequestRequest
rejectSubmittedIntakeRequestRequestCodec =
  RejectSubmittedIntakeRequestRequest <$> key "rejectionReason" (.rejectionReason)

instance ToJSON   RejectSubmittedIntakeRequestRequest where
  toJSON = recordToJSON rejectSubmittedIntakeRequestRequestCodec
instance FromJSON RejectSubmittedIntakeRequestRequest where
  parseJSON = recordParseJSON "RejectSubmittedIntakeRequestRequest" rejectSubmittedIntakeRequestRequestCodec
instance ToSchema RejectSubmittedIntakeRequestRequest where
  declareNamedSchema _ =
    recordSchema "RejectSubmittedIntakeRequestRequest" rejectSubmittedIntakeRequestRequestCodec

-- The slot has no field of its own in the appointment, so its key is its
-- ID type's name.
newtype MatchAcceptedIntakeRequestToSlotRequest = MatchAcceptedIntakeRequestToSlotRequest
  { slotId :: SlotIdDTO
  }
  deriving (Show, Eq)

matchAcceptedIntakeRequestToSlotRequestCodec
  :: Codec MatchAcceptedIntakeRequestToSlotRequest MatchAcceptedIntakeRequestToSlotRequest
matchAcceptedIntakeRequestToSlotRequestCodec =
  MatchAcceptedIntakeRequestToSlotRequest <$> key "slotId" (.slotId)

instance ToJSON   MatchAcceptedIntakeRequestToSlotRequest where
  toJSON = recordToJSON matchAcceptedIntakeRequestToSlotRequestCodec
instance FromJSON MatchAcceptedIntakeRequestToSlotRequest where
  parseJSON =
    recordParseJSON "MatchAcceptedIntakeRequestToSlotRequest" matchAcceptedIntakeRequestToSlotRequestCodec
instance ToSchema MatchAcceptedIntakeRequestToSlotRequest where
  declareNamedSchema _ =
    recordSchema "MatchAcceptedIntakeRequestToSlotRequest" matchAcceptedIntakeRequestToSlotRequestCodec

newtype WithdrawIntakeRequestRequest = WithdrawIntakeRequestRequest
  { withdrawalNote :: Maybe Text
  }
  deriving (Show, Eq)

withdrawIntakeRequestRequestCodec :: Codec WithdrawIntakeRequestRequest WithdrawIntakeRequestRequest
withdrawIntakeRequestRequestCodec =
  WithdrawIntakeRequestRequest <$> nullableKey "withdrawalNote" (.withdrawalNote)

instance ToJSON   WithdrawIntakeRequestRequest where toJSON = recordToJSON withdrawIntakeRequestRequestCodec
instance FromJSON WithdrawIntakeRequestRequest where
  parseJSON = recordParseJSON "WithdrawIntakeRequestRequest" withdrawIntakeRequestRequestCodec
instance ToSchema WithdrawIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "WithdrawIntakeRequestRequest" withdrawIntakeRequestRequestCodec

-- CloseReason as the caller supplies it: Cancellation without cancelledAt,
-- which the handler records.
data CancellationRequest = CancellationRequest
  { cancelledBy      :: AppointmentPartyDTO
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

cancellationRequestCodec :: Codec CancellationRequest CancellationRequest
cancellationRequestCodec = CancellationRequest
  <$> key "cancelledBy"              (.cancelledBy)
  <*> nullableKey "cancellationNote" (.cancellationNote)

instance ToJSON   CancellationRequest where toJSON = recordToJSON cancellationRequestCodec
instance FromJSON CancellationRequest where
  parseJSON = recordParseJSON "CancellationRequest" cancellationRequestCodec
instance ToSchema CancellationRequest where
  declareNamedSchema _ = recordSchema "CancellationRequest" cancellationRequestCodec

data CloseReasonRequest
  = CompletedRequest
  | CancelledRequest CancellationRequest
  | NoShowRequest    AbsenceDTO
  deriving (Show, Eq)

closeReasonRequestSum :: Sum CloseReasonRequest
closeReasonRequestSum =
  Sum "CloseReasonRequest" [Case completed, Case cancelled, Case noShow] $ \case
    CompletedRequest   -> put completed ()
    CancelledRequest c -> put cancelled c
    NoShowRequest    a -> put noShow a
  where
    completed = CaseOf "Completed" (pure ()) (const CompletedRequest)
    cancelled = CaseOf "Cancelled" cancellationRequestCodec CancelledRequest
    noShow    = CaseOf "NoShow" absenceCodec NoShowRequest

instance ToJSON   CloseReasonRequest where toJSON = sumToJSON closeReasonRequestSum
instance FromJSON CloseReasonRequest where parseJSON = sumParseJSON closeReasonRequestSum
instance ToSchema CloseReasonRequest where declareNamedSchema _ = sumSchema closeReasonRequestSum

-- The close reason once the handler has the time of the cancellation.
requestedCloseReason :: UTCTime -> CloseReasonRequest -> CloseReason
requestedCloseReason now = \case
  CompletedRequest   -> Completed
  CancelledRequest c -> Cancelled Cancellation
    { cancelledBy      = toDomainAppointmentParty c.cancelledBy
    , cancelledAt      = now
    , cancellationNote = c.cancellationNote
    }
  NoShowRequest    a -> NoShow (toDomainAbsence a)

newtype CloseAppointedIntakeRequestRequest = CloseAppointedIntakeRequestRequest
  { closeReason :: CloseReasonRequest
  }
  deriving (Show, Eq)

closeAppointedIntakeRequestRequestCodec
  :: Codec CloseAppointedIntakeRequestRequest CloseAppointedIntakeRequestRequest
closeAppointedIntakeRequestRequestCodec =
  CloseAppointedIntakeRequestRequest <$> key "closeReason" (.closeReason)

instance ToJSON   CloseAppointedIntakeRequestRequest where
  toJSON = recordToJSON closeAppointedIntakeRequestRequestCodec
instance FromJSON CloseAppointedIntakeRequestRequest where
  parseJSON = recordParseJSON "CloseAppointedIntakeRequestRequest" closeAppointedIntakeRequestRequestCodec
instance ToSchema CloseAppointedIntakeRequestRequest where
  declareNamedSchema _ =
    recordSchema "CloseAppointedIntakeRequestRequest" closeAppointedIntakeRequestRequestCodec

data CreateAvailableSlotRequest = CreateAvailableSlotRequest
  { doctorId            :: DoctorIdDTO
  , healthcareServiceId :: HealthcareServiceIdDTO
  , start               :: UTCTime
  }
  deriving (Show, Eq)

createAvailableSlotRequestCodec :: Codec CreateAvailableSlotRequest CreateAvailableSlotRequest
createAvailableSlotRequestCodec = CreateAvailableSlotRequest
  <$> key "doctorId"            (.doctorId)
  <*> key "healthcareServiceId" (.healthcareServiceId)
  <*> key "start"               (.start)

instance ToJSON   CreateAvailableSlotRequest where toJSON = recordToJSON createAvailableSlotRequestCodec
instance FromJSON CreateAvailableSlotRequest where
  parseJSON = recordParseJSON "CreateAvailableSlotRequest" createAvailableSlotRequestCodec
instance ToSchema CreateAvailableSlotRequest where
  declareNamedSchema _ = recordSchema "CreateAvailableSlotRequest" createAvailableSlotRequestCodec

-- ═══════════════════════════════════════════════════════════════════════════
-- ANSWERS
-- Every 200 body is {"outcome": <tag>, "detail": <payload or null>}. An
-- answer's schema is oneOf one named schema per tag, <Answer><Constructor>,
-- discriminated by "outcome", so each tag's detail is typed.
-- ═══════════════════════════════════════════════════════════════════════════

-- One outcome: its constructor's name, its detail's schema (Nothing: the
-- detail is null), and how a payload renders as the detail.
data Outcome p = Outcome Text (Maybe (Defs (Referenced Schema))) (p -> Value)

data SomeOutcome = forall p. SomeOutcome (Outcome p)

withDetail :: forall p. (ToJSON p, ToSchema p) => Text -> Outcome p
withDetail constructor = Outcome constructor (Just (declareSchemaRef (Proxy @p))) toJSON

noDetail :: Text -> Outcome ()
noDetail constructor = Outcome constructor Nothing (const Null)

answerWith :: Outcome p -> p -> (Text, Value)
answerWith (Outcome constructor _ render) p = (tagOf constructor, render p)

-- A type whose values are answered as tagged envelopes.
class Outcomes a where
  outcomes  :: Proxy a -> [SomeOutcome]
  outcomeOf :: a -> (Text, Value)

envelope :: Outcomes a => a -> Value
envelope a = let (tag, detail) = outcomeOf a in object ["outcome" .= tag, "detail" .= detail]

envelopeSchema :: Outcomes a => Proxy a -> Text -> Defs NamedSchema
envelopeSchema proxy answerName = do
  members <- for (outcomes proxy) $ \(SomeOutcome (Outcome constructor detail _)) -> do
    let tag      = tagOf constructor
        caseName = answerName <> capitalised constructor
    schema <- objectSchema
      [ ("outcome", pure (Inline (tagSchema [tag])))
      , ("detail",  maybe (pure (Inline nullSchema)) (\d -> d) detail)
      ]
    declare (InsOrd.singleton caseName schema)
    pure (tag, caseName)
  pure (NamedSchema (Just answerName) (discriminated "outcome" members))

-- A Service function's answer, named <Function>Answer.
newtype Answer (name :: Symbol) a = Answer a

instance (KnownSymbol name, Outcomes a) => ToJSON (Answer name a) where
  toJSON (Answer a) = envelope a

instance (KnownSymbol name, Typeable a, Outcomes a) => ToSchema (Answer name a) where
  declareNamedSchema _ = envelopeSchema (Proxy @a) (Text.pack (symbolVal (Proxy @name)))

-- A failure is answered with its ServiceError tag; success with its own.
instance (Outcomes e, Outcomes a) => Outcomes (Either e a) where
  outcomes _ = outcomes (Proxy @a) ++ outcomes (Proxy @e)
  outcomeOf  = either outcomeOf outcomeOf

-- A plain value with no constructor of its own.
newtype Ok a = Ok a
  deriving (Show, Eq)

ok :: forall a. (ToJSON a, ToSchema a) => Outcome a
ok = withDetail "Ok"

instance (ToJSON a, ToSchema a) => Outcomes (Ok a) where
  outcomes _       = [SomeOutcome (ok @a)]
  outcomeOf (Ok a) = answerWith ok a

-- A by-id read of a slot, which is deleted on consumption: Nothing has the
-- same tag as Service's outcome for that fact.
instance Outcomes (Maybe AvailableSlotDTO) where
  outcomes _ = [SomeOutcome (ok @AvailableSlotDTO), SomeOutcome availableSlotConsumed]
  outcomeOf  = \case
    Just slot -> answerWith ok slot
    Nothing   -> answerWith availableSlotConsumed ()

-- Service.ServiceError, without DecodeFailed: that one is a 500.
data ServiceErrorDTO
  = DoctorNotFoundDTO             DoctorIdDTO
  | PatientNotFoundDTO            PatientIdDTO
  | HealthcareServiceNotFoundDTO  HealthcareServiceIdDTO
  | IntakeRequestNotFoundDTO      IntakeRequestIdDTO
  | IntakeRequestInWrongStateDTO  IntakeRequestDTO
  | SlotDoesNotMatchIntakeRequestDTO
  deriving (Show, Eq)

doctorNotFound :: Outcome DoctorIdDTO
doctorNotFound = withDetail "DoctorNotFound"

patientNotFound :: Outcome PatientIdDTO
patientNotFound = withDetail "PatientNotFound"

healthcareServiceNotFound :: Outcome HealthcareServiceIdDTO
healthcareServiceNotFound = withDetail "HealthcareServiceNotFound"

intakeRequestNotFound :: Outcome IntakeRequestIdDTO
intakeRequestNotFound = withDetail "IntakeRequestNotFound"

intakeRequestInWrongState :: Outcome IntakeRequestDTO
intakeRequestInWrongState = withDetail "IntakeRequestInWrongState"

slotDoesNotMatchIntakeRequest :: Outcome ()
slotDoesNotMatchIntakeRequest = noDetail "SlotDoesNotMatchIntakeRequest"

instance Outcomes ServiceErrorDTO where
  outcomes _ =
    [ SomeOutcome doctorNotFound, SomeOutcome patientNotFound, SomeOutcome healthcareServiceNotFound
    , SomeOutcome intakeRequestNotFound, SomeOutcome intakeRequestInWrongState
    , SomeOutcome slotDoesNotMatchIntakeRequest ]
  outcomeOf = \case
    DoctorNotFoundDTO d              -> answerWith doctorNotFound d
    PatientNotFoundDTO p             -> answerWith patientNotFound p
    HealthcareServiceNotFoundDTO s   -> answerWith healthcareServiceNotFound s
    IntakeRequestNotFoundDTO r       -> answerWith intakeRequestNotFound r
    IntakeRequestInWrongStateDTO r   -> answerWith intakeRequestInWrongState r
    SlotDoesNotMatchIntakeRequestDTO -> answerWith slotDoesNotMatchIntakeRequest ()

-- Service.TransitionOutcome.
data TransitionOutcomeDTO a
  = TransitionedDTO a
  | MovedOnDTO      IntakeRequestDTO
  deriving (Show, Eq)

transitioned :: forall a. (ToJSON a, ToSchema a) => Outcome a
transitioned = withDetail "Transitioned"

movedOn :: Outcome IntakeRequestDTO
movedOn = withDetail "MovedOn"

instance (ToJSON a, ToSchema a) => Outcomes (TransitionOutcomeDTO a) where
  outcomes _ = [SomeOutcome (transitioned @a), SomeOutcome movedOn]
  outcomeOf  = \case
    TransitionedDTO a -> answerWith transitioned a
    MovedOnDTO      r -> answerWith movedOn r

-- Service.MatchOutcome. Nested as a detail, it is an envelope of its own.
data MatchOutcomeDTO
  = MatchedDTO               AppointedIntakeRequestDTO
  | AvailableSlotConsumedDTO
  | IntakeRequestMovedOnDTO  IntakeRequestDTO
  deriving (Show, Eq)

matched :: Outcome AppointedIntakeRequestDTO
matched = withDetail "Matched"

availableSlotConsumed :: Outcome ()
availableSlotConsumed = noDetail "AvailableSlotConsumed"

intakeRequestMovedOn :: Outcome IntakeRequestDTO
intakeRequestMovedOn = withDetail "IntakeRequestMovedOn"

instance Outcomes MatchOutcomeDTO where
  outcomes _ = [SomeOutcome matched, SomeOutcome availableSlotConsumed, SomeOutcome intakeRequestMovedOn]
  outcomeOf  = \case
    MatchedDTO a              -> answerWith matched a
    AvailableSlotConsumedDTO  -> answerWith availableSlotConsumed ()
    IntakeRequestMovedOnDTO r -> answerWith intakeRequestMovedOn r

instance ToJSON   MatchOutcomeDTO where toJSON = envelope
instance ToSchema MatchOutcomeDTO where declareNamedSchema _ = envelopeSchema (Proxy @MatchOutcomeDTO) "MatchOutcome"

-- Service.PriorityMatchOutcome.
data PriorityMatchOutcomeDTO
  = NoMatchingIntakeRequestDTO
  | MatchAttemptedDTO MatchOutcomeDTO
  deriving (Show, Eq)

noMatchingIntakeRequest :: Outcome ()
noMatchingIntakeRequest = noDetail "NoMatchingIntakeRequest"

matchAttempted :: Outcome MatchOutcomeDTO
matchAttempted = withDetail "MatchAttempted"

instance Outcomes PriorityMatchOutcomeDTO where
  outcomes _ = [SomeOutcome noMatchingIntakeRequest, SomeOutcome matchAttempted]
  outcomeOf  = \case
    NoMatchingIntakeRequestDTO -> answerWith noMatchingIntakeRequest ()
    MatchAttemptedDTO m        -> answerWith matchAttempted m

-- Service.SlotCreationOutcome.
data SlotCreationOutcomeDTO
  = SlotCreatedDTO AvailableSlotDTO
  | SlotOverlapsDoctorCalendarDTO
  deriving (Show, Eq)

slotCreated :: Outcome AvailableSlotDTO
slotCreated = withDetail "SlotCreated"

slotOverlapsDoctorCalendar :: Outcome ()
slotOverlapsDoctorCalendar = noDetail "SlotOverlapsDoctorCalendar"

instance Outcomes SlotCreationOutcomeDTO where
  outcomes _ = [SomeOutcome slotCreated, SomeOutcome slotOverlapsDoctorCalendar]
  outcomeOf  = \case
    SlotCreatedDTO s              -> answerWith slotCreated s
    SlotOverlapsDoctorCalendarDTO -> answerWith slotOverlapsDoctorCalendar ()

-- One answer per public Service function.
type CreateDoctorAnswer            = Answer "CreateDoctorAnswer" (Ok DoctorDTO)
type CreatePatientAnswer           = Answer "CreatePatientAnswer" (Ok PatientDTO)
type CreateHealthcareServiceAnswer = Answer "CreateHealthcareServiceAnswer" (Ok HealthcareServiceDTO)
type SubmitIntakeRequestAnswer     =
  Answer "SubmitIntakeRequestAnswer" (Either ServiceErrorDTO (Ok SubmittedIntakeRequestDTO))

type AcceptSubmittedIntakeRequestAnswer =
  Answer "AcceptSubmittedIntakeRequestAnswer"
    (Either ServiceErrorDTO (TransitionOutcomeDTO TriagedIntakeRequestDTO))
type RejectSubmittedIntakeRequestAnswer =
  Answer "RejectSubmittedIntakeRequestAnswer"
    (Either ServiceErrorDTO (TransitionOutcomeDTO RejectedIntakeRequestDTO))
type MatchAcceptedIntakeRequestToSlotAnswer =
  Answer "MatchAcceptedIntakeRequestToSlotAnswer" (Either ServiceErrorDTO MatchOutcomeDTO)
type WithdrawIntakeRequestAnswer =
  Answer "WithdrawIntakeRequestAnswer"
    (Either ServiceErrorDTO (TransitionOutcomeDTO WithdrawnIntakeRequestDTO))
type MarkAcceptedIntakeRequestStaleAnswer =
  Answer "MarkAcceptedIntakeRequestStaleAnswer"
    (Either ServiceErrorDTO (TransitionOutcomeDTO StaleIntakeRequestDTO))
type CloseAppointedIntakeRequestAnswer =
  Answer "CloseAppointedIntakeRequestAnswer"
    (Either ServiceErrorDTO (TransitionOutcomeDTO ClosedIntakeRequestDTO))

type MatchAvailableSlotByPriorityAnswer =
  Answer "MatchAvailableSlotByPriorityAnswer" (Either ServiceErrorDTO PriorityMatchOutcomeDTO)
type CreateAvailableSlotAnswer =
  Answer "CreateAvailableSlotAnswer" (Either ServiceErrorDTO SlotCreationOutcomeDTO)

type FetchDoctorAnswer   = Answer "FetchDoctorAnswer" (Either ServiceErrorDTO (Ok DoctorDTO))
type FetchDoctorsAnswer  = Answer "FetchDoctorsAnswer" (Ok [DoctorDTO])
type FetchPatientAnswer  = Answer "FetchPatientAnswer" (Either ServiceErrorDTO (Ok PatientDTO))
type FetchPatientsAnswer = Answer "FetchPatientsAnswer" (Ok [PatientDTO])
type FetchHealthcareServiceAnswer =
  Answer "FetchHealthcareServiceAnswer" (Either ServiceErrorDTO (Ok HealthcareServiceDTO))
type FetchHealthcareServicesAnswer =
  Answer "FetchHealthcareServicesAnswer" (Either ServiceErrorDTO (Ok [HealthcareServiceDTO]))
type FetchAvailableSlotAnswer =
  Answer "FetchAvailableSlotAnswer" (Either ServiceErrorDTO (Maybe AvailableSlotDTO))
type FetchIntakeRequestAnswer =
  Answer "FetchIntakeRequestAnswer" (Either ServiceErrorDTO (Ok IntakeRequestDTO))
type FetchSubmittedIntakeRequestsAnswer =
  Answer "FetchSubmittedIntakeRequestsAnswer" (Either ServiceErrorDTO (Ok [SubmittedIntakeRequestDTO]))
type FetchAcceptedIntakeRequestsAnswer =
  Answer "FetchAcceptedIntakeRequestsAnswer" (Either ServiceErrorDTO (Ok [TriagedIntakeRequestDTO]))
type FetchAppointedIntakeRequestsAnswer =
  Answer "FetchAppointedIntakeRequestsAnswer" (Either ServiceErrorDTO (Ok [AppointedIntakeRequestDTO]))
type FetchRejectedIntakeRequestsByRejectedAtAnswer =
  Answer "FetchRejectedIntakeRequestsByRejectedAtAnswer"
    (Either ServiceErrorDTO (Ok [RejectedIntakeRequestDTO]))
type FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer =
  Answer "FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer"
    (Either ServiceErrorDTO (Ok [WithdrawnIntakeRequestDTO]))
type FetchStaleIntakeRequestsByStaleAtAnswer =
  Answer "FetchStaleIntakeRequestsByStaleAtAnswer" (Either ServiceErrorDTO (Ok [StaleIntakeRequestDTO]))
type FetchClosedIntakeRequestsByStartAnswer =
  Answer "FetchClosedIntakeRequestsByStartAnswer" (Either ServiceErrorDTO (Ok [ClosedIntakeRequestDTO]))
type FetchDoctorCalendarEntriesOverlappingAnswer =
  Answer "FetchDoctorCalendarEntriesOverlappingAnswer"
    (Either ServiceErrorDTO (Ok [DoctorCalendarEntryDTO]))
