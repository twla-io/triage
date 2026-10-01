{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}

-- Derived from src/Domain.hs (every name and shape) and src/Service.hs (the
-- answers' outcomes and facts) by the triage-api-codegen skill.
--
-- Wire format: every sum type is one flat object per case, tagged by
-- "type"; embedded stages are flattened into their case's object; a Maybe
-- field's key is always present (null when absent). Every schema is exactly
-- what ToJSON produces (OpenAPI 3: oneOf per case).
module Transport
  ( -- ── IDs ──────────────────────────────────────────────────────────────
    DoctorIdDTO (..)
  , PatientIdDTO (..)
  , HealthcareServiceIdDTO (..)
  , IntakeRequestIdDTO (..)
  , SlotIdDTO (..)
  , fromDomainDoctorId, toDomainDoctorId
  , fromDomainPatientId, toDomainPatientId
  , fromDomainHealthcareServiceId, toDomainHealthcareServiceId
  , fromDomainIntakeRequestId, toDomainIntakeRequestId
  , fromDomainSlotId, toDomainSlotId

    -- ── Domain DTOs ──────────────────────────────────────────────────────
  , DurationDTO (..)
  , DoctorDTO (..)
  , PatientDTO (..)
  , HealthcareServiceDTO (..)
  , DoctorRequirementDTO (..)
  , MustBeSeenByDTO (..)
  , RoutineWindowDTO (..)
  , RoutineDueDTO (..)
  , IntakeRequestPriorityDTO (..)
  , SubmittedIntakeRequestDTO (..)
  , RejectedIntakeRequestDTO (..)
  , TriagedIntakeRequestDTO (..)
  , AppointedIntakeRequestDTO (..)
  , WithdrawnFromDTO (..)
  , WithdrawnIntakeRequestDTO (..)
  , StaleIntakeRequestDTO (..)
  , AppointmentPartyDTO (..)
  , CancellationDTO (..)
  , AbsenceDTO (..)
  , CloseReasonDTO (..)
  , ClosedIntakeRequestDTO (..)
  , IntakeRequestDTO (..)
  , AvailableSlotDTO (..)
  , DoctorCalendarEntryDTO (..)
  , fromDomainDuration, toDomainDuration
  , fromDomainDoctor, toDomainDoctor
  , fromDomainPatient, toDomainPatient
  , fromDomainHealthcareService, toDomainHealthcareService
  , fromDomainDoctorRequirement, toDomainDoctorRequirement
  , fromDomainMustBeSeenBy, toDomainMustBeSeenBy
  , fromDomainRoutineWindow, toDomainRoutineWindow
  , fromDomainRoutineDue, toDomainRoutineDue
  , fromDomainIntakeRequestPriority, toDomainIntakeRequestPriority
  , fromDomainSubmittedIntakeRequest, toDomainSubmittedIntakeRequest
  , fromDomainRejectedIntakeRequest, toDomainRejectedIntakeRequest
  , fromDomainTriagedIntakeRequest, toDomainTriagedIntakeRequest
  , fromDomainAppointedIntakeRequest, toDomainAppointedIntakeRequest
  , fromDomainWithdrawnFrom, toDomainWithdrawnFrom
  , fromDomainWithdrawnIntakeRequest, toDomainWithdrawnIntakeRequest
  , fromDomainStaleIntakeRequest, toDomainStaleIntakeRequest
  , fromDomainAppointmentParty, toDomainAppointmentParty
  , fromDomainCancellation, toDomainCancellation
  , fromDomainAbsence, toDomainAbsence
  , fromDomainCloseReason, toDomainCloseReason
  , fromDomainClosedIntakeRequest, toDomainClosedIntakeRequest
  , fromDomainIntakeRequest, toDomainIntakeRequest
  , fromDomainAvailableSlot, toDomainAvailableSlot
  , fromDomainDoctorCalendarEntry, toDomainDoctorCalendarEntry

    -- ── Request bodies ───────────────────────────────────────────────────
  , CreateDoctorRequest (..)
  , CreatePatientRequest (..)
  , CreateHealthcareServiceRequest (..)
  , SubmitIntakeRequestRequest (..)
  , AcceptSubmittedIntakeRequestRequest (..)
  , RejectSubmittedIntakeRequestRequest (..)
  , MatchAcceptedIntakeRequestToSlotRequest (..)
  , WithdrawIntakeRequestRequest (..)
  , CancellationRequest (..)
  , CloseReasonRequest (..)
  , CloseAppointedIntakeRequestRequest (..)
  , CreateAvailableSlotRequest (..)
  , toDomainCloseReasonRequest

    -- ── Answers ──────────────────────────────────────────────────────────
  , Envelope
  , Outcome
  , NoDetail (..)
  , answer
    -- outcomes and facts, one tag each
  , ok
  , transitioned
  , movedOn
  , intakeRequestMatchedToSlot
  , availableSlotConsumed
  , intakeRequestMovedOn
  , noIntakeRequestMatched
  , matchIntakeRequestToSlotOutcome
  , availableSlotAdded
  , availableSlotOverlapsDoctorCalendar
  , doctorNotFound
  , patientNotFound
  , healthcareServiceNotFound
  , intakeRequestNotFound
  , intakeRequestInWrongState
  , intakeRequestDoesNotMatchSlot
    -- answer types
  , MatchIntakeRequestToSlotOutcomeDTO (..)
  , CreateDoctorAnswer (..)
  , CreatePatientAnswer (..)
  , CreateHealthcareServiceAnswer (..)
  , SubmitIntakeRequestAnswer (..)
  , AcceptSubmittedIntakeRequestAnswer (..)
  , RejectSubmittedIntakeRequestAnswer (..)
  , MatchAcceptedIntakeRequestToSlotAnswer (..)
  , WithdrawIntakeRequestAnswer (..)
  , MarkAcceptedIntakeRequestStaleAnswer (..)
  , CloseAppointedIntakeRequestAnswer (..)
  , MatchAvailableSlotByPriorityAnswer (..)
  , CreateAvailableSlotAnswer (..)
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

import Prelude hiding (id)

import Control.Lens        ((&), (.~), (?~))
import Control.Monad       (ap, forM, liftM, unless)
import Data.Aeson
  ( FromJSON (..), Object, ToJSON (..), Value (..), object, withObject, withText, (.:), (.=) )
import Data.Aeson.Key      (Key)
import Data.Aeson.Types    (Pair, Parser)
import Data.Char           (toLower, toUpper)
import Data.OpenApi
  ( Definitions, Discriminator (..), NamedSchema (..), OpenApiType (..), Reference (..)
  , Referenced (..), Schema, ToParamSchema (..), ToSchema (..), declareSchemaRef, discriminator
  , enum_, format, nullable, oneOf, properties, required, type_ )
import Data.OpenApi.Declare (Declare, declare)
import Data.Proxy          (Proxy (..))
import Data.Text           (Text)
import Data.Time           (UTCTime)
import Data.UUID           (UUID)
import Servant             (FromHttpApiData (..))

import qualified Data.Aeson.Key             as Key
import qualified Data.Aeson.KeyMap          as KeyMap
import qualified Data.HashMap.Strict.InsOrd as InsOrd
import qualified Data.Text                  as Text
import qualified Data.UUID                  as UUID

import Domain

-- ═══════════════════════════════════════════════════════════════════════════
-- MACHINERY
-- Each shape is written once as three parts that compose when a stage or a
-- payload is flattened into an enclosing object: its key/value pairs (ToJSON),
-- its fields (FromJSON) and its properties (ToSchema).
-- ═══════════════════════════════════════════════════════════════════════════

-- A parser over one object that records the keys it read, so the enclosing
-- object can reject every key nobody read (a 400).
newtype Fields a = Fields (Object -> Parser ([Key], a))

instance Functor Fields where
  fmap = liftM

instance Applicative Fields where
  pure x = Fields (\_ -> pure ([], x))
  (<*>)  = ap

instance Monad Fields where
  Fields p >>= f = Fields $ \o -> do
    (keys, x) <- p o
    let Fields q = f x
    (keys', y) <- q o
    pure (keys <> keys', y)

field :: FromJSON a => Key -> Fields a
field key = Fields (\o -> (\x -> ([key], x)) <$> o .: key)

liftParser :: Parser a -> Fields a
liftParser p = Fields (\_ -> (\x -> ([], x)) <$> p)

-- The whole object: exactly the keys its fields read.
exactly :: String -> Fields a -> Value -> Parser a
exactly name (Fields p) = withObject name $ \o -> do
  (keys, x) <- p o
  let unknown = filter (`notElem` keys) (KeyMap.keys o)
  unless (null unknown) $
    fail ("unknown keys " <> show (map Key.toText unknown) <> " in " <> name)
  pure x

-- A sum's case, by its "type" tag.
cases :: String -> [(Text, Fields a)] -> Fields a
cases name alternatives = do
  tag <- field "type"
  case lookup tag alternatives of
    Just fields -> fields
    Nothing     -> liftParser (fail ("unknown " <> name <> " type " <> show (tag :: Text)))

type Props = [(Text, Declare (Definitions Schema) (Referenced Schema))]

prop :: forall a. ToSchema a => Text -> Props
prop key = [(key, declareSchemaRef (Proxy @a))]

nullableText :: Text -> Props
nullableText key = [(key, pure (Inline (mempty & type_ ?~ OpenApiString & nullable ?~ True)))]

tagProp :: Text -> Props
tagProp tag = [("type", pure (Inline (oneValue tag)))]

oneValue :: Text -> Schema
oneValue v = mempty & type_ ?~ OpenApiString & enum_ ?~ [String v]

-- An object with exactly these keys, all required.
objectSchema :: Props -> Declare (Definitions Schema) Schema
objectSchema props = do
  resolved <- forM props $ \(key, schema) -> (,) key <$> schema
  pure $ mempty
    & type_      ?~ OpenApiObject
    & properties .~ InsOrd.fromList resolved
    & required   .~ map fst resolved

declared :: Text -> Schema -> Declare (Definitions Schema) (Referenced Schema)
declared name schema = do
  declare (InsOrd.singleton name schema)
  pure (Ref (Reference name))

schemaRef :: Text -> Text
schemaRef name = "#/components/schemas/" <> name

-- A sum case: one object, or (when its keys depend on a nested tag) oneOf
-- its variants.
data Case
  = Plain    Text Props
  | Variants Text [(Text, Props)]

-- oneOf one named schema per case, <Type><Constructor>; discriminated by
-- "type" unless a case is itself a oneOf.
sumSchema :: Text -> [Case] -> Declare (Definitions Schema) NamedSchema
sumSchema name alternatives = do
  refs <- forM alternatives $ \case
    Plain tag props -> do
      let caseName = name <> upperFirst tag
      ref <- declared caseName =<< objectSchema (tagProp tag <> props)
      pure (tag, caseName, ref)
    Variants tag variants -> do
      let caseName = name <> upperFirst tag
      variantRefs <- forM variants $ \(inner, props) ->
        declared (caseName <> upperFirst inner) =<< objectSchema (tagProp tag <> props)
      ref <- declared caseName (mempty & oneOf ?~ variantRefs)
      pure (tag, caseName, ref)
  let plain   = all isPlain alternatives
      isPlain = \case Plain {} -> True; Variants {} -> False
      schema  = mempty & oneOf ?~ [ ref | (_, _, ref) <- refs ]
  pure . NamedSchema (Just name) $
    if plain
      then schema & discriminator ?~ Discriminator "type"
             (InsOrd.fromList [ (tag, schemaRef caseName) | (tag, caseName, _) <- refs ])
      else schema

-- A record whose keys depend on a nested tag: oneOf its variants,
-- <Type><InnerConstructor>.
variantsSchema :: Text -> [(Text, Props)] -> Declare (Definitions Schema) NamedSchema
variantsSchema name variants = do
  refs <- forM variants $ \(inner, props) ->
    declared (name <> upperFirst inner) =<< objectSchema props
  pure (NamedSchema (Just name) (mempty & oneOf ?~ refs))

recordSchema :: Text -> Props -> Declare (Definitions Schema) NamedSchema
recordSchema name props = NamedSchema (Just name) <$> objectSchema props

lowerFirst, upperFirst :: Text -> Text
lowerFirst t = maybe t (\(c, rest) -> Text.cons (toLower c) rest) (Text.uncons t)
upperFirst t = maybe t (\(c, rest) -> Text.cons (toUpper c) rest) (Text.uncons t)

-- ── Enumerations: an object with only "type" ───────────────────────────────

enumTag :: Show a => a -> Text
enumTag = lowerFirst . Text.pack . show

enumPairs :: Show a => a -> [Pair]
enumPairs x = ["type" .= enumTag x]

enumFields :: forall a. (Show a, Enum a, Bounded a) => String -> Fields a
enumFields name = cases name [ (enumTag x, pure x) | x <- [minBound .. maxBound :: a] ]

enumSchema :: forall a. (Show a, Enum a, Bounded a) => Text -> Proxy a -> NamedSchema
enumSchema name _ =
  NamedSchema (Just name) $ mempty
    & type_      ?~ OpenApiObject
    & properties .~ InsOrd.fromList
        [ ("type", Inline (mempty & type_ ?~ OpenApiString
                                  & enum_ ?~ [ String (enumTag x) | x <- [minBound .. maxBound :: a] ])) ]
    & required   .~ ["type"]

-- ── IDs: a plain UUID string, one named schema per ID type ─────────────────

uuidSchema :: Schema
uuidSchema = mempty & type_ ?~ OpenApiString & format ?~ "uuid"

parseUUID :: String -> Value -> Parser UUID
parseUUID name = withText name $ \t -> maybe (fail ("invalid " <> name)) pure (UUID.fromText t)

uuidPiece :: Text -> Either Text UUID
uuidPiece t = maybe (Left ("invalid UUID: " <> t)) Right (UUID.fromText t)

-- ═══════════════════════════════════════════════════════════════════════════
-- IDS
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorIdDTO            = DoctorIdDTO            DoctorId            deriving (Show, Eq)
newtype PatientIdDTO           = PatientIdDTO           PatientId           deriving (Show, Eq)
newtype HealthcareServiceIdDTO = HealthcareServiceIdDTO HealthcareServiceId deriving (Show, Eq)
newtype IntakeRequestIdDTO     = IntakeRequestIdDTO     IntakeRequestId     deriving (Show, Eq)
newtype SlotIdDTO              = SlotIdDTO              SlotId              deriving (Show, Eq)

fromDomainDoctorId :: DoctorId -> DoctorIdDTO
fromDomainDoctorId = DoctorIdDTO
toDomainDoctorId :: DoctorIdDTO -> DoctorId
toDomainDoctorId (DoctorIdDTO x) = x

fromDomainPatientId :: PatientId -> PatientIdDTO
fromDomainPatientId = PatientIdDTO
toDomainPatientId :: PatientIdDTO -> PatientId
toDomainPatientId (PatientIdDTO x) = x

fromDomainHealthcareServiceId :: HealthcareServiceId -> HealthcareServiceIdDTO
fromDomainHealthcareServiceId = HealthcareServiceIdDTO
toDomainHealthcareServiceId :: HealthcareServiceIdDTO -> HealthcareServiceId
toDomainHealthcareServiceId (HealthcareServiceIdDTO x) = x

fromDomainIntakeRequestId :: IntakeRequestId -> IntakeRequestIdDTO
fromDomainIntakeRequestId = IntakeRequestIdDTO
toDomainIntakeRequestId :: IntakeRequestIdDTO -> IntakeRequestId
toDomainIntakeRequestId (IntakeRequestIdDTO x) = x

fromDomainSlotId :: SlotId -> SlotIdDTO
fromDomainSlotId = SlotIdDTO
toDomainSlotId :: SlotIdDTO -> SlotId
toDomainSlotId (SlotIdDTO x) = x

instance ToJSON DoctorIdDTO where toJSON (DoctorIdDTO (DoctorId u)) = toJSON (UUID.toText u)
instance FromJSON DoctorIdDTO where parseJSON = fmap (DoctorIdDTO . DoctorId) . parseUUID "DoctorId"
instance ToSchema DoctorIdDTO where declareNamedSchema _ = pure (NamedSchema (Just "DoctorId") uuidSchema)
instance ToParamSchema DoctorIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData DoctorIdDTO where parseUrlPiece = fmap (DoctorIdDTO . DoctorId) . uuidPiece

instance ToJSON PatientIdDTO where toJSON (PatientIdDTO (PatientId u)) = toJSON (UUID.toText u)
instance FromJSON PatientIdDTO where parseJSON = fmap (PatientIdDTO . PatientId) . parseUUID "PatientId"
instance ToSchema PatientIdDTO where declareNamedSchema _ = pure (NamedSchema (Just "PatientId") uuidSchema)
instance ToParamSchema PatientIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData PatientIdDTO where parseUrlPiece = fmap (PatientIdDTO . PatientId) . uuidPiece

instance ToJSON HealthcareServiceIdDTO where
  toJSON (HealthcareServiceIdDTO (HealthcareServiceId u)) = toJSON (UUID.toText u)
instance FromJSON HealthcareServiceIdDTO where
  parseJSON = fmap (HealthcareServiceIdDTO . HealthcareServiceId) . parseUUID "HealthcareServiceId"
instance ToSchema HealthcareServiceIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "HealthcareServiceId") uuidSchema)
instance ToParamSchema HealthcareServiceIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData HealthcareServiceIdDTO where
  parseUrlPiece = fmap (HealthcareServiceIdDTO . HealthcareServiceId) . uuidPiece

instance ToJSON IntakeRequestIdDTO where
  toJSON (IntakeRequestIdDTO (IntakeRequestId u)) = toJSON (UUID.toText u)
instance FromJSON IntakeRequestIdDTO where
  parseJSON = fmap (IntakeRequestIdDTO . IntakeRequestId) . parseUUID "IntakeRequestId"
instance ToSchema IntakeRequestIdDTO where
  declareNamedSchema _ = pure (NamedSchema (Just "IntakeRequestId") uuidSchema)
instance ToParamSchema IntakeRequestIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData IntakeRequestIdDTO where
  parseUrlPiece = fmap (IntakeRequestIdDTO . IntakeRequestId) . uuidPiece

instance ToJSON SlotIdDTO where toJSON (SlotIdDTO (SlotId u)) = toJSON (UUID.toText u)
instance FromJSON SlotIdDTO where parseJSON = fmap (SlotIdDTO . SlotId) . parseUUID "SlotId"
instance ToSchema SlotIdDTO where declareNamedSchema _ = pure (NamedSchema (Just "SlotId") uuidSchema)
instance ToParamSchema SlotIdDTO where toParamSchema _ = uuidSchema
instance FromHttpApiData SlotIdDTO where parseUrlPiece = fmap (SlotIdDTO . SlotId) . uuidPiece

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION
-- ═══════════════════════════════════════════════════════════════════════════

newtype DurationDTO = DurationDTO Duration deriving (Show, Eq)

fromDomainDuration :: Duration -> DurationDTO
fromDomainDuration = DurationDTO
toDomainDuration :: DurationDTO -> Duration
toDomainDuration (DurationDTO x) = x

instance ToJSON DurationDTO where toJSON (DurationDTO d) = object (enumPairs d)
instance FromJSON DurationDTO where parseJSON = fmap DurationDTO . exactly "Duration" (enumFields "Duration")
instance ToSchema DurationDTO where declareNamedSchema _ = pure (enumSchema "Duration" (Proxy @Duration))

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR / PATIENT / HEALTHCARE SERVICE
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorDTO = DoctorDTO Doctor deriving (Show, Eq)

fromDomainDoctor :: Doctor -> DoctorDTO
fromDomainDoctor = DoctorDTO
toDomainDoctor :: DoctorDTO -> Doctor
toDomainDoctor (DoctorDTO x) = x

instance ToJSON DoctorDTO where
  toJSON (DoctorDTO d) = object ["id" .= DoctorIdDTO d.id, "name" .= d.name]
instance FromJSON DoctorDTO where
  parseJSON = exactly "Doctor" $ do
    DoctorIdDTO id <- field "id"
    name           <- field "name"
    pure (DoctorDTO Doctor { id, name })
instance ToSchema DoctorDTO where
  declareNamedSchema _ = recordSchema "Doctor" (prop @DoctorIdDTO "id" <> prop @Text "name")

newtype PatientDTO = PatientDTO Patient deriving (Show, Eq)

fromDomainPatient :: Patient -> PatientDTO
fromDomainPatient = PatientDTO
toDomainPatient :: PatientDTO -> Patient
toDomainPatient (PatientDTO x) = x

instance ToJSON PatientDTO where
  toJSON (PatientDTO p) = object ["id" .= PatientIdDTO p.id, "name" .= p.name]
instance FromJSON PatientDTO where
  parseJSON = exactly "Patient" $ do
    PatientIdDTO id <- field "id"
    name            <- field "name"
    pure (PatientDTO Patient { id, name })
instance ToSchema PatientDTO where
  declareNamedSchema _ = recordSchema "Patient" (prop @PatientIdDTO "id" <> prop @Text "name")

newtype HealthcareServiceDTO = HealthcareServiceDTO HealthcareService deriving (Show, Eq)

fromDomainHealthcareService :: HealthcareService -> HealthcareServiceDTO
fromDomainHealthcareService = HealthcareServiceDTO
toDomainHealthcareService :: HealthcareServiceDTO -> HealthcareService
toDomainHealthcareService (HealthcareServiceDTO x) = x

instance ToJSON HealthcareServiceDTO where
  toJSON (HealthcareServiceDTO s) =
    object [ "id" .= HealthcareServiceIdDTO s.id, "name" .= s.name, "duration" .= DurationDTO s.duration ]
instance FromJSON HealthcareServiceDTO where
  parseJSON = exactly "HealthcareService" $ do
    HealthcareServiceIdDTO id <- field "id"
    name                      <- field "name"
    DurationDTO duration      <- field "duration"
    pure (HealthcareServiceDTO HealthcareService { id, name, duration })
instance ToSchema HealthcareServiceDTO where
  declareNamedSchema _ = recordSchema "HealthcareService" $
    prop @HealthcareServiceIdDTO "id" <> prop @Text "name" <> prop @DurationDTO "duration"

-- ═══════════════════════════════════════════════════════════════════════════
-- DOCTOR REQUIREMENT
-- ═══════════════════════════════════════════════════════════════════════════

newtype DoctorRequirementDTO = DoctorRequirementDTO DoctorRequirement deriving (Show, Eq)

fromDomainDoctorRequirement :: DoctorRequirement -> DoctorRequirementDTO
fromDomainDoctorRequirement = DoctorRequirementDTO
toDomainDoctorRequirement :: DoctorRequirementDTO -> DoctorRequirement
toDomainDoctorRequirement (DoctorRequirementDTO x) = x

instance ToJSON DoctorRequirementDTO where
  toJSON (DoctorRequirementDTO r) = object $ case r of
    AnyDoctor               -> ["type" .= ("anyDoctor" :: Text)]
    SpecificDoctor doctorId -> ["type" .= ("specificDoctor" :: Text), "specificDoctor" .= DoctorIdDTO doctorId]
instance FromJSON DoctorRequirementDTO where
  parseJSON = fmap DoctorRequirementDTO . exactly "DoctorRequirement" (cases "DoctorRequirement"
    [ ("anyDoctor",      pure AnyDoctor)
    , ("specificDoctor", (\(DoctorIdDTO d) -> SpecificDoctor d) <$> field "specificDoctor")
    ])
instance ToSchema DoctorRequirementDTO where
  declareNamedSchema _ = sumSchema "DoctorRequirement"
    [ Plain "anyDoctor"      []
    , Plain "specificDoctor" (prop @DoctorIdDTO "specificDoctor")
    ]

-- ═══════════════════════════════════════════════════════════════════════════
-- PRIORITY / DUE CONSTRAINTS
-- ═══════════════════════════════════════════════════════════════════════════

newtype MustBeSeenByDTO = MustBeSeenByDTO MustBeSeenBy deriving (Show, Eq)

fromDomainMustBeSeenBy :: MustBeSeenBy -> MustBeSeenByDTO
fromDomainMustBeSeenBy = MustBeSeenByDTO
toDomainMustBeSeenBy :: MustBeSeenByDTO -> MustBeSeenBy
toDomainMustBeSeenBy (MustBeSeenByDTO x) = x

mustBeSeenByPairs :: MustBeSeenBy -> [Pair]
mustBeSeenByPairs (MustBeSeenBy t) = ["mustBeSeenBy" .= t]

mustBeSeenByFields :: Fields MustBeSeenBy
mustBeSeenByFields = MustBeSeenBy <$> field "mustBeSeenBy"

mustBeSeenByProps :: Props
mustBeSeenByProps = prop @UTCTime "mustBeSeenBy"

instance ToJSON MustBeSeenByDTO where toJSON (MustBeSeenByDTO m) = object (mustBeSeenByPairs m)
instance FromJSON MustBeSeenByDTO where
  parseJSON = fmap MustBeSeenByDTO . exactly "MustBeSeenBy" mustBeSeenByFields
instance ToSchema MustBeSeenByDTO where
  declareNamedSchema _ = recordSchema "MustBeSeenBy" mustBeSeenByProps

-- Sealed: decoded only through mkRoutineWindow; a refusal is a parse failure.
newtype RoutineWindowDTO = RoutineWindowDTO RoutineWindow deriving (Show, Eq)

fromDomainRoutineWindow :: RoutineWindow -> RoutineWindowDTO
fromDomainRoutineWindow = RoutineWindowDTO
toDomainRoutineWindow :: RoutineWindowDTO -> RoutineWindow
toDomainRoutineWindow (RoutineWindowDTO x) = x

routineWindowPairs :: RoutineWindow -> [Pair]
routineWindowPairs w =
  ["routineNotBefore" .= routineNotBefore w, "routineNotAfter" .= routineNotAfter w]

routineWindowFields :: Fields RoutineWindow
routineWindowFields = do
  notBefore <- field "routineNotBefore"
  notAfter  <- field "routineNotAfter"
  maybe (liftParser (fail "routineNotBefore is after routineNotAfter")) pure
    (mkRoutineWindow notBefore notAfter)

routineWindowProps :: Props
routineWindowProps = prop @UTCTime "routineNotBefore" <> prop @UTCTime "routineNotAfter"

instance ToJSON RoutineWindowDTO where toJSON (RoutineWindowDTO w) = object (routineWindowPairs w)
instance FromJSON RoutineWindowDTO where
  parseJSON = fmap RoutineWindowDTO . exactly "RoutineWindow" routineWindowFields
instance ToSchema RoutineWindowDTO where
  declareNamedSchema _ = recordSchema "RoutineWindow" routineWindowProps

newtype RoutineDueDTO = RoutineDueDTO RoutineDue deriving (Show, Eq)

fromDomainRoutineDue :: RoutineDue -> RoutineDueDTO
fromDomainRoutineDue = RoutineDueDTO
toDomainRoutineDue :: RoutineDueDTO -> RoutineDue
toDomainRoutineDue (RoutineDueDTO x) = x

instance ToJSON RoutineDueDTO where
  toJSON (RoutineDueDTO due) = object $ case due of
    RoutineAnytime     -> ["type" .= ("routineAnytime" :: Text)]
    RoutineNotBefore t -> ["type" .= ("routineNotBefore" :: Text), "routineNotBefore" .= t]
    RoutineNotAfter t  -> ["type" .= ("routineNotAfter" :: Text), "routineNotAfter" .= t]
    RoutineWithin w    -> ("type" .= ("routineWithin" :: Text)) : routineWindowPairs w
instance FromJSON RoutineDueDTO where
  parseJSON = fmap RoutineDueDTO . exactly "RoutineDue" (cases "RoutineDue"
    [ ("routineAnytime",   pure RoutineAnytime)
    , ("routineNotBefore", RoutineNotBefore <$> field "routineNotBefore")
    , ("routineNotAfter",  RoutineNotAfter <$> field "routineNotAfter")
    , ("routineWithin",    RoutineWithin <$> routineWindowFields)
    ])
instance ToSchema RoutineDueDTO where
  declareNamedSchema _ = sumSchema "RoutineDue"
    [ Plain "routineAnytime"   []
    , Plain "routineNotBefore" (prop @UTCTime "routineNotBefore")
    , Plain "routineNotAfter"  (prop @UTCTime "routineNotAfter")
    , Plain "routineWithin"    routineWindowProps
    ]

newtype IntakeRequestPriorityDTO = IntakeRequestPriorityDTO IntakeRequestPriority deriving (Show, Eq)

fromDomainIntakeRequestPriority :: IntakeRequestPriority -> IntakeRequestPriorityDTO
fromDomainIntakeRequestPriority = IntakeRequestPriorityDTO
toDomainIntakeRequestPriority :: IntakeRequestPriorityDTO -> IntakeRequestPriority
toDomainIntakeRequestPriority (IntakeRequestPriorityDTO x) = x

-- Routine's payload is a sum type, so it is nested under "routine".
instance ToJSON IntakeRequestPriorityDTO where
  toJSON (IntakeRequestPriorityDTO p) = object $ case p of
    Emergency m -> ("type" .= ("emergency" :: Text)) : mustBeSeenByPairs m
    Urgent m    -> ("type" .= ("urgent" :: Text)) : mustBeSeenByPairs m
    Routine due -> ["type" .= ("routine" :: Text), "routine" .= RoutineDueDTO due]
instance FromJSON IntakeRequestPriorityDTO where
  parseJSON = fmap IntakeRequestPriorityDTO . exactly "IntakeRequestPriority" (cases "IntakeRequestPriority"
    [ ("emergency", Emergency <$> mustBeSeenByFields)
    , ("urgent",    Urgent <$> mustBeSeenByFields)
    , ("routine",   (\(RoutineDueDTO due) -> Routine due) <$> field "routine")
    ])
instance ToSchema IntakeRequestPriorityDTO where
  declareNamedSchema _ = sumSchema "IntakeRequestPriority"
    [ Plain "emergency" mustBeSeenByProps
    , Plain "urgent"    mustBeSeenByProps
    , Plain "routine"   (prop @RoutineDueDTO "routine")
    ]

-- ═══════════════════════════════════════════════════════════════════════════
-- INTAKE REQUEST STAGES
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Submitted ───────────────────────────────────────────────────────────────

newtype SubmittedIntakeRequestDTO = SubmittedIntakeRequestDTO SubmittedIntakeRequest deriving (Show, Eq)

fromDomainSubmittedIntakeRequest :: SubmittedIntakeRequest -> SubmittedIntakeRequestDTO
fromDomainSubmittedIntakeRequest = SubmittedIntakeRequestDTO
toDomainSubmittedIntakeRequest :: SubmittedIntakeRequestDTO -> SubmittedIntakeRequest
toDomainSubmittedIntakeRequest (SubmittedIntakeRequestDTO x) = x

submittedPairs :: SubmittedIntakeRequest -> [Pair]
submittedPairs s =
  [ "id"        .= IntakeRequestIdDTO s.id
  , "patientId" .= PatientIdDTO s.patientId
  , "narrative" .= s.narrative
  , "createdAt" .= s.createdAt
  ]

submittedFields :: Fields SubmittedIntakeRequest
submittedFields = do
  IntakeRequestIdDTO id  <- field "id"
  PatientIdDTO patientId <- field "patientId"
  narrative              <- field "narrative"
  createdAt              <- field "createdAt"
  pure SubmittedIntakeRequest { id, patientId, narrative, createdAt }

submittedProps :: Props
submittedProps =
  prop @IntakeRequestIdDTO "id" <> prop @PatientIdDTO "patientId"
    <> prop @Text "narrative" <> prop @UTCTime "createdAt"

instance ToJSON SubmittedIntakeRequestDTO where
  toJSON (SubmittedIntakeRequestDTO s) = object (submittedPairs s)
instance FromJSON SubmittedIntakeRequestDTO where
  parseJSON = fmap SubmittedIntakeRequestDTO . exactly "SubmittedIntakeRequest" submittedFields
instance ToSchema SubmittedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "SubmittedIntakeRequest" submittedProps

-- ── Rejected ────────────────────────────────────────────────────────────────

newtype RejectedIntakeRequestDTO = RejectedIntakeRequestDTO RejectedIntakeRequest deriving (Show, Eq)

fromDomainRejectedIntakeRequest :: RejectedIntakeRequest -> RejectedIntakeRequestDTO
fromDomainRejectedIntakeRequest = RejectedIntakeRequestDTO
toDomainRejectedIntakeRequest :: RejectedIntakeRequestDTO -> RejectedIntakeRequest
toDomainRejectedIntakeRequest (RejectedIntakeRequestDTO x) = x

rejectedPairs :: RejectedIntakeRequest -> [Pair]
rejectedPairs r =
  submittedPairs r.submitted
    <> ["rejectedAt" .= r.rejectedAt, "rejectionReason" .= r.rejectionReason]

rejectedFields :: Fields RejectedIntakeRequest
rejectedFields = do
  submitted       <- submittedFields
  rejectedAt      <- field "rejectedAt"
  rejectionReason <- field "rejectionReason"
  pure RejectedIntakeRequest { submitted, rejectedAt, rejectionReason }

rejectedProps :: Props
rejectedProps = submittedProps <> prop @UTCTime "rejectedAt" <> prop @Text "rejectionReason"

instance ToJSON RejectedIntakeRequestDTO where
  toJSON (RejectedIntakeRequestDTO r) = object (rejectedPairs r)
instance FromJSON RejectedIntakeRequestDTO where
  parseJSON = fmap RejectedIntakeRequestDTO . exactly "RejectedIntakeRequest" rejectedFields
instance ToSchema RejectedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "RejectedIntakeRequest" rejectedProps

-- ── Triaged ─────────────────────────────────────────────────────────────────

newtype TriagedIntakeRequestDTO = TriagedIntakeRequestDTO TriagedIntakeRequest deriving (Show, Eq)

fromDomainTriagedIntakeRequest :: TriagedIntakeRequest -> TriagedIntakeRequestDTO
fromDomainTriagedIntakeRequest = TriagedIntakeRequestDTO
toDomainTriagedIntakeRequest :: TriagedIntakeRequestDTO -> TriagedIntakeRequest
toDomainTriagedIntakeRequest (TriagedIntakeRequestDTO x) = x

triagedPairs :: TriagedIntakeRequest -> [Pair]
triagedPairs t =
  submittedPairs t.submitted <>
    [ "healthcareServiceId" .= HealthcareServiceIdDTO t.healthcareServiceId
    , "priority"            .= IntakeRequestPriorityDTO t.priority
    , "doctorRequirement"   .= DoctorRequirementDTO t.doctorRequirement
    , "triagedAt"           .= t.triagedAt
    ]

triagedFields :: Fields TriagedIntakeRequest
triagedFields = do
  submitted                                  <- submittedFields
  HealthcareServiceIdDTO healthcareServiceId <- field "healthcareServiceId"
  IntakeRequestPriorityDTO priority          <- field "priority"
  DoctorRequirementDTO doctorRequirement     <- field "doctorRequirement"
  triagedAt                                  <- field "triagedAt"
  pure TriagedIntakeRequest { submitted, healthcareServiceId, priority, doctorRequirement, triagedAt }

triagedProps :: Props
triagedProps =
  submittedProps
    <> prop @HealthcareServiceIdDTO "healthcareServiceId"
    <> prop @IntakeRequestPriorityDTO "priority"
    <> prop @DoctorRequirementDTO "doctorRequirement"
    <> prop @UTCTime "triagedAt"

instance ToJSON TriagedIntakeRequestDTO where
  toJSON (TriagedIntakeRequestDTO t) = object (triagedPairs t)
instance FromJSON TriagedIntakeRequestDTO where
  parseJSON = fmap TriagedIntakeRequestDTO . exactly "TriagedIntakeRequest" triagedFields
instance ToSchema TriagedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "TriagedIntakeRequest" triagedProps

-- ── Appointed ───────────────────────────────────────────────────────────────

newtype AppointedIntakeRequestDTO = AppointedIntakeRequestDTO AppointedIntakeRequest deriving (Show, Eq)

fromDomainAppointedIntakeRequest :: AppointedIntakeRequest -> AppointedIntakeRequestDTO
fromDomainAppointedIntakeRequest = AppointedIntakeRequestDTO
toDomainAppointedIntakeRequest :: AppointedIntakeRequestDTO -> AppointedIntakeRequest
toDomainAppointedIntakeRequest (AppointedIntakeRequestDTO x) = x

appointedPairs :: AppointedIntakeRequest -> [Pair]
appointedPairs a =
  triagedPairs a.triaged <>
    [ "doctorId" .= DoctorIdDTO a.doctorId
    , "start"    .= a.start
    , "duration" .= DurationDTO a.duration
    ]

appointedFields :: Fields AppointedIntakeRequest
appointedFields = do
  triaged              <- triagedFields
  DoctorIdDTO doctorId <- field "doctorId"
  start                <- field "start"
  DurationDTO duration <- field "duration"
  pure AppointedIntakeRequest { triaged, doctorId, start, duration }

appointedProps :: Props
appointedProps =
  triagedProps <> prop @DoctorIdDTO "doctorId" <> prop @UTCTime "start" <> prop @DurationDTO "duration"

instance ToJSON AppointedIntakeRequestDTO where
  toJSON (AppointedIntakeRequestDTO a) = object (appointedPairs a)
instance FromJSON AppointedIntakeRequestDTO where
  parseJSON = fmap AppointedIntakeRequestDTO . exactly "AppointedIntakeRequest" appointedFields
instance ToSchema AppointedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "AppointedIntakeRequest" appointedProps

-- ── WithdrawnFrom ───────────────────────────────────────────────────────────

newtype WithdrawnFromDTO = WithdrawnFromDTO WithdrawnFrom deriving (Show, Eq)

fromDomainWithdrawnFrom :: WithdrawnFrom -> WithdrawnFromDTO
fromDomainWithdrawnFrom = WithdrawnFromDTO
toDomainWithdrawnFrom :: WithdrawnFromDTO -> WithdrawnFrom
toDomainWithdrawnFrom (WithdrawnFromDTO x) = x

withdrawnFromTag :: WithdrawnFrom -> Text
withdrawnFromTag = \case
  FromSubmitted _ -> "fromSubmitted"
  FromAccepted _  -> "fromAccepted"

-- The stage each case carries.
withdrawnFromStagePairs :: WithdrawnFrom -> [Pair]
withdrawnFromStagePairs = \case
  FromSubmitted s -> submittedPairs s
  FromAccepted t  -> triagedPairs t

withdrawnFromStageFields :: Text -> Fields WithdrawnFrom
withdrawnFromStageFields = \case
  "fromSubmitted" -> FromSubmitted <$> submittedFields
  "fromAccepted"  -> FromAccepted <$> triagedFields
  other           -> liftParser (fail ("unknown WithdrawnFrom type " <> show other))

withdrawnFromStageProps :: [(Text, Props)]
withdrawnFromStageProps = [("fromSubmitted", submittedProps), ("fromAccepted", triagedProps)]

instance ToJSON WithdrawnFromDTO where
  toJSON (WithdrawnFromDTO w) = object (("type" .= withdrawnFromTag w) : withdrawnFromStagePairs w)
instance FromJSON WithdrawnFromDTO where
  parseJSON = fmap WithdrawnFromDTO . exactly "WithdrawnFrom" (field "type" >>= withdrawnFromStageFields)
instance ToSchema WithdrawnFromDTO where
  declareNamedSchema _ =
    sumSchema "WithdrawnFrom" [ Plain tag props | (tag, props) <- withdrawnFromStageProps ]

-- ── Withdrawn ───────────────────────────────────────────────────────────────

-- withdrawnFrom's cases each carry a stage: the stage's fields join the
-- object, and "withdrawnFrom" keeps only {"type": <case>}.
newtype WithdrawnIntakeRequestDTO = WithdrawnIntakeRequestDTO WithdrawnIntakeRequest deriving (Show, Eq)

fromDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequest -> WithdrawnIntakeRequestDTO
fromDomainWithdrawnIntakeRequest = WithdrawnIntakeRequestDTO
toDomainWithdrawnIntakeRequest :: WithdrawnIntakeRequestDTO -> WithdrawnIntakeRequest
toDomainWithdrawnIntakeRequest (WithdrawnIntakeRequestDTO x) = x

withdrawnPairs :: WithdrawnIntakeRequest -> [Pair]
withdrawnPairs w =
  withdrawnFromStagePairs w.withdrawnFrom <>
    [ "withdrawnFrom"  .= object ["type" .= withdrawnFromTag w.withdrawnFrom]
    , "withdrawnAt"    .= w.withdrawnAt
    , "withdrawalNote" .= w.withdrawalNote
    ]

withdrawnFields :: Fields WithdrawnIntakeRequest
withdrawnFields = do
  fromTag        <- field "withdrawnFrom" >>= liftParser . exactly "withdrawnFrom" (field "type")
  withdrawnFrom  <- withdrawnFromStageFields fromTag
  withdrawnAt    <- field "withdrawnAt"
  withdrawalNote <- field "withdrawalNote"
  pure WithdrawnIntakeRequest { withdrawnFrom, withdrawnAt, withdrawalNote }

-- One variant per withdrawnFrom case.
withdrawnVariants :: [(Text, Props)]
withdrawnVariants =
  [ ( fromTag
    , stageProps
        <> [("withdrawnFrom", Inline <$> objectSchema (tagProp fromTag))]
        <> prop @UTCTime "withdrawnAt"
        <> nullableText "withdrawalNote" )
  | (fromTag, stageProps) <- withdrawnFromStageProps ]

instance ToJSON WithdrawnIntakeRequestDTO where
  toJSON (WithdrawnIntakeRequestDTO w) = object (withdrawnPairs w)
instance FromJSON WithdrawnIntakeRequestDTO where
  parseJSON = fmap WithdrawnIntakeRequestDTO . exactly "WithdrawnIntakeRequest" withdrawnFields
instance ToSchema WithdrawnIntakeRequestDTO where
  declareNamedSchema _ = variantsSchema "WithdrawnIntakeRequest" withdrawnVariants

-- ── Stale ───────────────────────────────────────────────────────────────────

newtype StaleIntakeRequestDTO = StaleIntakeRequestDTO StaleIntakeRequest deriving (Show, Eq)

fromDomainStaleIntakeRequest :: StaleIntakeRequest -> StaleIntakeRequestDTO
fromDomainStaleIntakeRequest = StaleIntakeRequestDTO
toDomainStaleIntakeRequest :: StaleIntakeRequestDTO -> StaleIntakeRequest
toDomainStaleIntakeRequest (StaleIntakeRequestDTO x) = x

stalePairs :: StaleIntakeRequest -> [Pair]
stalePairs s = triagedPairs s.triaged <> ["staleAt" .= s.staleAt]

staleFields :: Fields StaleIntakeRequest
staleFields = do
  triaged <- triagedFields
  staleAt <- field "staleAt"
  pure StaleIntakeRequest { triaged, staleAt }

staleProps :: Props
staleProps = triagedProps <> prop @UTCTime "staleAt"

instance ToJSON StaleIntakeRequestDTO where
  toJSON (StaleIntakeRequestDTO s) = object (stalePairs s)
instance FromJSON StaleIntakeRequestDTO where
  parseJSON = fmap StaleIntakeRequestDTO . exactly "StaleIntakeRequest" staleFields
instance ToSchema StaleIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "StaleIntakeRequest" staleProps

-- ── AppointmentParty / Cancellation / Absence / CloseReason ────────────────

newtype AppointmentPartyDTO = AppointmentPartyDTO AppointmentParty deriving (Show, Eq)

fromDomainAppointmentParty :: AppointmentParty -> AppointmentPartyDTO
fromDomainAppointmentParty = AppointmentPartyDTO
toDomainAppointmentParty :: AppointmentPartyDTO -> AppointmentParty
toDomainAppointmentParty (AppointmentPartyDTO x) = x

instance ToJSON AppointmentPartyDTO where toJSON (AppointmentPartyDTO p) = object (enumPairs p)
instance FromJSON AppointmentPartyDTO where
  parseJSON = fmap AppointmentPartyDTO . exactly "AppointmentParty" (enumFields "AppointmentParty")
instance ToSchema AppointmentPartyDTO where
  declareNamedSchema _ = pure (enumSchema "AppointmentParty" (Proxy @AppointmentParty))

newtype CancellationDTO = CancellationDTO Cancellation deriving (Show, Eq)

fromDomainCancellation :: Cancellation -> CancellationDTO
fromDomainCancellation = CancellationDTO
toDomainCancellation :: CancellationDTO -> Cancellation
toDomainCancellation (CancellationDTO x) = x

cancellationPairs :: Cancellation -> [Pair]
cancellationPairs c =
  [ "cancelledBy"      .= AppointmentPartyDTO c.cancelledBy
  , "cancelledAt"      .= c.cancelledAt
  , "cancellationNote" .= c.cancellationNote
  ]

cancellationFields :: Fields Cancellation
cancellationFields = do
  AppointmentPartyDTO cancelledBy <- field "cancelledBy"
  cancelledAt                     <- field "cancelledAt"
  cancellationNote                <- field "cancellationNote"
  pure Cancellation { cancelledBy, cancelledAt, cancellationNote }

cancellationProps :: Props
cancellationProps =
  prop @AppointmentPartyDTO "cancelledBy" <> prop @UTCTime "cancelledAt" <> nullableText "cancellationNote"

instance ToJSON CancellationDTO where toJSON (CancellationDTO c) = object (cancellationPairs c)
instance FromJSON CancellationDTO where
  parseJSON = fmap CancellationDTO . exactly "Cancellation" cancellationFields
instance ToSchema CancellationDTO where
  declareNamedSchema _ = recordSchema "Cancellation" cancellationProps

newtype AbsenceDTO = AbsenceDTO Absence deriving (Show, Eq)

fromDomainAbsence :: Absence -> AbsenceDTO
fromDomainAbsence = AbsenceDTO
toDomainAbsence :: AbsenceDTO -> Absence
toDomainAbsence (AbsenceDTO x) = x

absencePairs :: Absence -> [Pair]
absencePairs a = ["absentParty" .= AppointmentPartyDTO a.absentParty]

absenceFields :: Fields Absence
absenceFields = (\(AppointmentPartyDTO absentParty) -> Absence { absentParty }) <$> field "absentParty"

absenceProps :: Props
absenceProps = prop @AppointmentPartyDTO "absentParty"

instance ToJSON AbsenceDTO where toJSON (AbsenceDTO a) = object (absencePairs a)
instance FromJSON AbsenceDTO where parseJSON = fmap AbsenceDTO . exactly "Absence" absenceFields
instance ToSchema AbsenceDTO where declareNamedSchema _ = recordSchema "Absence" absenceProps

newtype CloseReasonDTO = CloseReasonDTO CloseReason deriving (Show, Eq)

fromDomainCloseReason :: CloseReason -> CloseReasonDTO
fromDomainCloseReason = CloseReasonDTO
toDomainCloseReason :: CloseReasonDTO -> CloseReason
toDomainCloseReason (CloseReasonDTO x) = x

instance ToJSON CloseReasonDTO where
  toJSON (CloseReasonDTO r) = object $ case r of
    Completed   -> ["type" .= ("completed" :: Text)]
    Cancelled c -> ("type" .= ("cancelled" :: Text)) : cancellationPairs c
    NoShow a    -> ("type" .= ("noShow" :: Text)) : absencePairs a
instance FromJSON CloseReasonDTO where
  parseJSON = fmap CloseReasonDTO . exactly "CloseReason" (cases "CloseReason"
    [ ("completed", pure Completed)
    , ("cancelled", Cancelled <$> cancellationFields)
    , ("noShow",    NoShow <$> absenceFields)
    ])
instance ToSchema CloseReasonDTO where
  declareNamedSchema _ = sumSchema "CloseReason"
    [ Plain "completed" []
    , Plain "cancelled" cancellationProps
    , Plain "noShow"    absenceProps
    ]

-- ── Closed ──────────────────────────────────────────────────────────────────

newtype ClosedIntakeRequestDTO = ClosedIntakeRequestDTO ClosedIntakeRequest deriving (Show, Eq)

fromDomainClosedIntakeRequest :: ClosedIntakeRequest -> ClosedIntakeRequestDTO
fromDomainClosedIntakeRequest = ClosedIntakeRequestDTO
toDomainClosedIntakeRequest :: ClosedIntakeRequestDTO -> ClosedIntakeRequest
toDomainClosedIntakeRequest (ClosedIntakeRequestDTO x) = x

closedPairs :: ClosedIntakeRequest -> [Pair]
closedPairs c = appointedPairs c.appointed <> ["closeReason" .= CloseReasonDTO c.closeReason]

closedFields :: Fields ClosedIntakeRequest
closedFields = do
  appointed                  <- appointedFields
  CloseReasonDTO closeReason <- field "closeReason"
  pure ClosedIntakeRequest { appointed, closeReason }

closedProps :: Props
closedProps = appointedProps <> prop @CloseReasonDTO "closeReason"

instance ToJSON ClosedIntakeRequestDTO where
  toJSON (ClosedIntakeRequestDTO c) = object (closedPairs c)
instance FromJSON ClosedIntakeRequestDTO where
  parseJSON = fmap ClosedIntakeRequestDTO . exactly "ClosedIntakeRequest" closedFields
instance ToSchema ClosedIntakeRequestDTO where
  declareNamedSchema _ = recordSchema "ClosedIntakeRequest" closedProps

-- ── IntakeRequest ───────────────────────────────────────────────────────────

newtype IntakeRequestDTO = IntakeRequestDTO IntakeRequest deriving (Show, Eq)

fromDomainIntakeRequest :: IntakeRequest -> IntakeRequestDTO
fromDomainIntakeRequest = IntakeRequestDTO
toDomainIntakeRequest :: IntakeRequestDTO -> IntakeRequest
toDomainIntakeRequest (IntakeRequestDTO x) = x

instance ToJSON IntakeRequestDTO where
  toJSON (IntakeRequestDTO r) = object $ case r of
    Submitted s -> ("type" .= ("submitted" :: Text)) : submittedPairs s
    Rejected x  -> ("type" .= ("rejected" :: Text))  : rejectedPairs x
    Accepted t  -> ("type" .= ("accepted" :: Text))  : triagedPairs t
    Appointed a -> ("type" .= ("appointed" :: Text)) : appointedPairs a
    Withdrawn w -> ("type" .= ("withdrawn" :: Text)) : withdrawnPairs w
    Stale s     -> ("type" .= ("stale" :: Text))     : stalePairs s
    Closed c    -> ("type" .= ("closed" :: Text))    : closedPairs c
instance FromJSON IntakeRequestDTO where
  parseJSON = fmap IntakeRequestDTO . exactly "IntakeRequest" (cases "IntakeRequest"
    [ ("submitted", Submitted <$> submittedFields)
    , ("rejected",  Rejected <$> rejectedFields)
    , ("accepted",  Accepted <$> triagedFields)
    , ("appointed", Appointed <$> appointedFields)
    , ("withdrawn", Withdrawn <$> withdrawnFields)
    , ("stale",     Stale <$> staleFields)
    , ("closed",    Closed <$> closedFields)
    ])
instance ToSchema IntakeRequestDTO where
  declareNamedSchema _ = sumSchema "IntakeRequest"
    [ Plain    "submitted" submittedProps
    , Plain    "rejected"  rejectedProps
    , Plain    "accepted"  triagedProps
    , Plain    "appointed" appointedProps
    , Variants "withdrawn" withdrawnVariants
    , Plain    "stale"     staleProps
    , Plain    "closed"    closedProps
    ]

-- ═══════════════════════════════════════════════════════════════════════════
-- SLOT / DOCTOR CALENDAR
-- ═══════════════════════════════════════════════════════════════════════════

newtype AvailableSlotDTO = AvailableSlotDTO AvailableSlot deriving (Show, Eq)

fromDomainAvailableSlot :: AvailableSlot -> AvailableSlotDTO
fromDomainAvailableSlot = AvailableSlotDTO
toDomainAvailableSlot :: AvailableSlotDTO -> AvailableSlot
toDomainAvailableSlot (AvailableSlotDTO x) = x

slotPairs :: AvailableSlot -> [Pair]
slotPairs s =
  [ "id"                  .= SlotIdDTO s.id
  , "doctorId"            .= DoctorIdDTO s.doctorId
  , "healthcareServiceId" .= HealthcareServiceIdDTO s.healthcareServiceId
  , "start"               .= s.start
  , "duration"            .= DurationDTO s.duration
  ]

slotFields :: Fields AvailableSlot
slotFields = do
  SlotIdDTO id                               <- field "id"
  DoctorIdDTO doctorId                       <- field "doctorId"
  HealthcareServiceIdDTO healthcareServiceId <- field "healthcareServiceId"
  start                                      <- field "start"
  DurationDTO duration                       <- field "duration"
  pure AvailableSlot { id, doctorId, healthcareServiceId, start, duration }

slotProps :: Props
slotProps =
  prop @SlotIdDTO "id" <> prop @DoctorIdDTO "doctorId"
    <> prop @HealthcareServiceIdDTO "healthcareServiceId"
    <> prop @UTCTime "start" <> prop @DurationDTO "duration"

instance ToJSON AvailableSlotDTO where toJSON (AvailableSlotDTO s) = object (slotPairs s)
instance FromJSON AvailableSlotDTO where
  parseJSON = fmap AvailableSlotDTO . exactly "AvailableSlot" slotFields
instance ToSchema AvailableSlotDTO where
  declareNamedSchema _ = recordSchema "AvailableSlot" slotProps

newtype DoctorCalendarEntryDTO = DoctorCalendarEntryDTO DoctorCalendarEntry deriving (Show, Eq)

fromDomainDoctorCalendarEntry :: DoctorCalendarEntry -> DoctorCalendarEntryDTO
fromDomainDoctorCalendarEntry = DoctorCalendarEntryDTO
toDomainDoctorCalendarEntry :: DoctorCalendarEntryDTO -> DoctorCalendarEntry
toDomainDoctorCalendarEntry (DoctorCalendarEntryDTO x) = x

instance ToJSON DoctorCalendarEntryDTO where
  toJSON (DoctorCalendarEntryDTO e) = object $ case e of
    Slot s        -> ("type" .= ("slot" :: Text)) : slotPairs s
    Appointment a -> ("type" .= ("appointment" :: Text)) : appointedPairs a
instance FromJSON DoctorCalendarEntryDTO where
  parseJSON = fmap DoctorCalendarEntryDTO . exactly "DoctorCalendarEntry" (cases "DoctorCalendarEntry"
    [ ("slot",        Slot <$> slotFields)
    , ("appointment", Appointment <$> appointedFields)
    ])
instance ToSchema DoctorCalendarEntryDTO where
  declareNamedSchema _ = sumSchema "DoctorCalendarEntry"
    [ Plain "slot"        slotProps
    , Plain "appointment" appointedProps
    ]

-- ═══════════════════════════════════════════════════════════════════════════
-- REQUEST BODIES
-- Exactly each Service function's caller-supplied facts, under the names of
-- the Domain.hs fields they land in. Times the server records are absent.
-- ═══════════════════════════════════════════════════════════════════════════

newtype CreateDoctorRequest = CreateDoctorRequest { name :: Text } deriving (Show, Eq)

instance ToJSON CreateDoctorRequest where toJSON r = object ["name" .= r.name]
instance FromJSON CreateDoctorRequest where
  parseJSON = exactly "CreateDoctorRequest" (CreateDoctorRequest <$> field "name")
instance ToSchema CreateDoctorRequest where
  declareNamedSchema _ = recordSchema "CreateDoctorRequest" (prop @Text "name")

newtype CreatePatientRequest = CreatePatientRequest { name :: Text } deriving (Show, Eq)

instance ToJSON CreatePatientRequest where toJSON r = object ["name" .= r.name]
instance FromJSON CreatePatientRequest where
  parseJSON = exactly "CreatePatientRequest" (CreatePatientRequest <$> field "name")
instance ToSchema CreatePatientRequest where
  declareNamedSchema _ = recordSchema "CreatePatientRequest" (prop @Text "name")

data CreateHealthcareServiceRequest = CreateHealthcareServiceRequest
  { name     :: Text
  , duration :: DurationDTO
  }
  deriving (Show, Eq)

instance ToJSON CreateHealthcareServiceRequest where
  toJSON r = object ["name" .= r.name, "duration" .= r.duration]
instance FromJSON CreateHealthcareServiceRequest where
  parseJSON = exactly "CreateHealthcareServiceRequest" $
    CreateHealthcareServiceRequest <$> field "name" <*> field "duration"
instance ToSchema CreateHealthcareServiceRequest where
  declareNamedSchema _ =
    recordSchema "CreateHealthcareServiceRequest" (prop @Text "name" <> prop @DurationDTO "duration")

data SubmitIntakeRequestRequest = SubmitIntakeRequestRequest
  { patientId :: PatientIdDTO
  , narrative :: Text
  }
  deriving (Show, Eq)

instance ToJSON SubmitIntakeRequestRequest where
  toJSON r = object ["patientId" .= r.patientId, "narrative" .= r.narrative]
instance FromJSON SubmitIntakeRequestRequest where
  parseJSON = exactly "SubmitIntakeRequestRequest" $
    SubmitIntakeRequestRequest <$> field "patientId" <*> field "narrative"
instance ToSchema SubmitIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "SubmitIntakeRequestRequest" $
    prop @PatientIdDTO "patientId" <> prop @Text "narrative"

data AcceptSubmittedIntakeRequestRequest = AcceptSubmittedIntakeRequestRequest
  { healthcareServiceId :: HealthcareServiceIdDTO
  , priority            :: IntakeRequestPriorityDTO
  , doctorRequirement   :: DoctorRequirementDTO
  }
  deriving (Show, Eq)

instance ToJSON AcceptSubmittedIntakeRequestRequest where
  toJSON r = object
    [ "healthcareServiceId" .= r.healthcareServiceId
    , "priority"            .= r.priority
    , "doctorRequirement"   .= r.doctorRequirement
    ]
instance FromJSON AcceptSubmittedIntakeRequestRequest where
  parseJSON = exactly "AcceptSubmittedIntakeRequestRequest" $
    AcceptSubmittedIntakeRequestRequest
      <$> field "healthcareServiceId" <*> field "priority" <*> field "doctorRequirement"
instance ToSchema AcceptSubmittedIntakeRequestRequest where
  declareNamedSchema _ = recordSchema "AcceptSubmittedIntakeRequestRequest" $
    prop @HealthcareServiceIdDTO "healthcareServiceId"
      <> prop @IntakeRequestPriorityDTO "priority"
      <> prop @DoctorRequirementDTO "doctorRequirement"

newtype RejectSubmittedIntakeRequestRequest = RejectSubmittedIntakeRequestRequest
  { rejectionReason :: Text }
  deriving (Show, Eq)

instance ToJSON RejectSubmittedIntakeRequestRequest where
  toJSON r = object ["rejectionReason" .= r.rejectionReason]
instance FromJSON RejectSubmittedIntakeRequestRequest where
  parseJSON = exactly "RejectSubmittedIntakeRequestRequest" $
    RejectSubmittedIntakeRequestRequest <$> field "rejectionReason"
instance ToSchema RejectSubmittedIntakeRequestRequest where
  declareNamedSchema _ =
    recordSchema "RejectSubmittedIntakeRequestRequest" (prop @Text "rejectionReason")

-- The slot's id lands in no Domain.hs field (the slot is consumed), so it
-- takes its ID type's name.
newtype MatchAcceptedIntakeRequestToSlotRequest = MatchAcceptedIntakeRequestToSlotRequest
  { slotId :: SlotIdDTO }
  deriving (Show, Eq)

instance ToJSON MatchAcceptedIntakeRequestToSlotRequest where
  toJSON r = object ["slotId" .= r.slotId]
instance FromJSON MatchAcceptedIntakeRequestToSlotRequest where
  parseJSON = exactly "MatchAcceptedIntakeRequestToSlotRequest" $
    MatchAcceptedIntakeRequestToSlotRequest <$> field "slotId"
instance ToSchema MatchAcceptedIntakeRequestToSlotRequest where
  declareNamedSchema _ =
    recordSchema "MatchAcceptedIntakeRequestToSlotRequest" (prop @SlotIdDTO "slotId")

newtype WithdrawIntakeRequestRequest = WithdrawIntakeRequestRequest
  { withdrawalNote :: Maybe Text }
  deriving (Show, Eq)

instance ToJSON WithdrawIntakeRequestRequest where
  toJSON r = object ["withdrawalNote" .= r.withdrawalNote]
instance FromJSON WithdrawIntakeRequestRequest where
  parseJSON = exactly "WithdrawIntakeRequestRequest" $
    WithdrawIntakeRequestRequest <$> field "withdrawalNote"
instance ToSchema WithdrawIntakeRequestRequest where
  declareNamedSchema _ =
    recordSchema "WithdrawIntakeRequestRequest" (nullableText "withdrawalNote")

-- Cancellation without cancelledAt, which the server records.
data CancellationRequest = CancellationRequest
  { cancelledBy      :: AppointmentPartyDTO
  , cancellationNote :: Maybe Text
  }
  deriving (Show, Eq)

cancellationRequestPairs :: CancellationRequest -> [Pair]
cancellationRequestPairs c = ["cancelledBy" .= c.cancelledBy, "cancellationNote" .= c.cancellationNote]

cancellationRequestFields :: Fields CancellationRequest
cancellationRequestFields = CancellationRequest <$> field "cancelledBy" <*> field "cancellationNote"

cancellationRequestProps :: Props
cancellationRequestProps = prop @AppointmentPartyDTO "cancelledBy" <> nullableText "cancellationNote"

instance ToJSON CancellationRequest where toJSON = object . cancellationRequestPairs
instance FromJSON CancellationRequest where
  parseJSON = exactly "CancellationRequest" cancellationRequestFields
instance ToSchema CancellationRequest where
  declareNamedSchema _ = recordSchema "CancellationRequest" cancellationRequestProps

-- CloseReason without the time the server records.
data CloseReasonRequest
  = CompletedRequest
  | CancelledRequest CancellationRequest
  | NoShowRequest    AbsenceDTO
  deriving (Show, Eq)

toDomainCloseReasonRequest :: UTCTime -> CloseReasonRequest -> CloseReason
toDomainCloseReasonRequest cancelledAt = \case
  CompletedRequest -> Completed
  CancelledRequest CancellationRequest { cancelledBy = AppointmentPartyDTO cancelledBy, cancellationNote } ->
    Cancelled Cancellation { cancelledBy, cancelledAt, cancellationNote }
  NoShowRequest (AbsenceDTO absence) -> NoShow absence

instance ToJSON CloseReasonRequest where
  toJSON r = object $ case r of
    CompletedRequest                -> ["type" .= ("completed" :: Text)]
    CancelledRequest c              -> ("type" .= ("cancelled" :: Text)) : cancellationRequestPairs c
    NoShowRequest (AbsenceDTO a)    -> ("type" .= ("noShow" :: Text)) : absencePairs a
instance FromJSON CloseReasonRequest where
  parseJSON = exactly "CloseReasonRequest" (cases "CloseReasonRequest"
    [ ("completed", pure CompletedRequest)
    , ("cancelled", CancelledRequest <$> cancellationRequestFields)
    , ("noShow",    NoShowRequest . AbsenceDTO <$> absenceFields)
    ])
instance ToSchema CloseReasonRequest where
  declareNamedSchema _ = sumSchema "CloseReasonRequest"
    [ Plain "completed" []
    , Plain "cancelled" cancellationRequestProps
    , Plain "noShow"    absenceProps
    ]

newtype CloseAppointedIntakeRequestRequest = CloseAppointedIntakeRequestRequest
  { closeReason :: CloseReasonRequest }
  deriving (Show, Eq)

instance ToJSON CloseAppointedIntakeRequestRequest where
  toJSON r = object ["closeReason" .= r.closeReason]
instance FromJSON CloseAppointedIntakeRequestRequest where
  parseJSON = exactly "CloseAppointedIntakeRequestRequest" $
    CloseAppointedIntakeRequestRequest <$> field "closeReason"
instance ToSchema CloseAppointedIntakeRequestRequest where
  declareNamedSchema _ =
    recordSchema "CloseAppointedIntakeRequestRequest" (prop @CloseReasonRequest "closeReason")

data CreateAvailableSlotRequest = CreateAvailableSlotRequest
  { doctorId            :: DoctorIdDTO
  , healthcareServiceId :: HealthcareServiceIdDTO
  , start               :: UTCTime
  }
  deriving (Show, Eq)

instance ToJSON CreateAvailableSlotRequest where
  toJSON r = object
    [ "doctorId" .= r.doctorId, "healthcareServiceId" .= r.healthcareServiceId, "start" .= r.start ]
instance FromJSON CreateAvailableSlotRequest where
  parseJSON = exactly "CreateAvailableSlotRequest" $
    CreateAvailableSlotRequest <$> field "doctorId" <*> field "healthcareServiceId" <*> field "start"
instance ToSchema CreateAvailableSlotRequest where
  declareNamedSchema _ = recordSchema "CreateAvailableSlotRequest" $
    prop @DoctorIdDTO "doctorId" <> prop @HealthcareServiceIdDTO "healthcareServiceId"
      <> prop @UTCTime "start"

-- ═══════════════════════════════════════════════════════════════════════════
-- ANSWERS
-- Every 200 body is {"outcome": <tag>, "detail": <payload or null>}. Each
-- tag is declared once below with its detail's DTO; an answer's schema is
-- oneOf exactly the tags its use case can produce.
-- ═══════════════════════════════════════════════════════════════════════════

data Envelope = Envelope Text Value
  deriving (Show, Eq)

instance ToJSON Envelope where
  toJSON (Envelope tag detail) = object ["outcome" .= tag, "detail" .= detail]

-- An outcome or fact tag, typed by its detail.
newtype Outcome d = Outcome Text

answer :: ToJSON d => Outcome d -> d -> Envelope
answer (Outcome tag) detail = Envelope tag (toJSON detail)

-- The detail of a tag that has no payload: always null.
data NoDetail = NoDetail
  deriving (Show, Eq)

instance ToJSON NoDetail where toJSON NoDetail = Null
instance ToSchema NoDetail where
  declareNamedSchema _ = pure . NamedSchema Nothing $ mempty & nullable ?~ True & enum_ ?~ [Null]

-- ── Tags: an outcome constructor's name, or a fact type's name ─────────────

ok :: Outcome d
ok = Outcome "ok"

transitioned :: Outcome d
transitioned = Outcome "transitioned"

movedOn :: Outcome IntakeRequestDTO
movedOn = Outcome "movedOn"

intakeRequestMatchedToSlot :: Outcome AppointedIntakeRequestDTO
intakeRequestMatchedToSlot = Outcome "intakeRequestMatchedToSlot"

availableSlotConsumed :: Outcome SlotIdDTO
availableSlotConsumed = Outcome "availableSlotConsumed"

intakeRequestMovedOn :: Outcome IntakeRequestDTO
intakeRequestMovedOn = Outcome "intakeRequestMovedOn"

noIntakeRequestMatched :: Outcome NoDetail
noIntakeRequestMatched = Outcome "noIntakeRequestMatched"

matchIntakeRequestToSlotOutcome :: Outcome MatchIntakeRequestToSlotOutcomeDTO
matchIntakeRequestToSlotOutcome = Outcome "matchIntakeRequestToSlotOutcome"

availableSlotAdded :: Outcome AvailableSlotDTO
availableSlotAdded = Outcome "availableSlotAdded"

availableSlotOverlapsDoctorCalendar :: Outcome NoDetail
availableSlotOverlapsDoctorCalendar = Outcome "availableSlotOverlapsDoctorCalendar"

doctorNotFound :: Outcome DoctorIdDTO
doctorNotFound = Outcome "doctorNotFound"

patientNotFound :: Outcome PatientIdDTO
patientNotFound = Outcome "patientNotFound"

healthcareServiceNotFound :: Outcome HealthcareServiceIdDTO
healthcareServiceNotFound = Outcome "healthcareServiceNotFound"

intakeRequestNotFound :: Outcome IntakeRequestIdDTO
intakeRequestNotFound = Outcome "intakeRequestNotFound"

intakeRequestInWrongState :: Outcome IntakeRequestDTO
intakeRequestInWrongState = Outcome "intakeRequestInWrongState"

intakeRequestDoesNotMatchSlot :: Outcome NoDetail
intakeRequestDoesNotMatchSlot = Outcome "intakeRequestDoesNotMatchSlot"

-- ── Answer schemas ──────────────────────────────────────────────────────────

newtype AnswerCase = AnswerCase (Text, Declare (Definitions Schema) (Referenced Schema))

on :: forall d. ToSchema d => Outcome d -> AnswerCase
on (Outcome tag) = AnswerCase (tag, declareSchemaRef (Proxy @d))

-- oneOf one schema per tag, <Answer><Tag>, discriminated by "outcome".
answerSchema :: Text -> [AnswerCase] -> Declare (Definitions Schema) NamedSchema
answerSchema name answerCases = do
  refs <- forM answerCases $ \(AnswerCase (tag, detail)) -> do
    let caseName = name <> upperFirst tag
    s <- objectSchema [("outcome", pure (Inline (oneValue tag))), ("detail", detail)]
    _ <- declared caseName s
    pure (tag, caseName)
  pure . NamedSchema (Just name) $ mempty
    & oneOf ?~ [ Ref (Reference caseName) | (_, caseName) <- refs ]
    & discriminator ?~ Discriminator "outcome"
        (InsOrd.fromList [ (tag, schemaRef caseName) | (tag, caseName) <- refs ])

transitionCases :: forall d. ToSchema d => [AnswerCase]
transitionCases = [on (transitioned :: Outcome d), on movedOn]

matchIntakeRequestToSlotOutcomeCases :: [AnswerCase]
matchIntakeRequestToSlotOutcomeCases = [on intakeRequestMatchedToSlot, on availableSlotConsumed, on intakeRequestMovedOn]

-- ── Answer types, one per Service function ─────────────────────────────────

-- Matching's outcome, nested as the detail of matchIntakeRequestToSlotOutcome.
newtype MatchIntakeRequestToSlotOutcomeDTO = MatchIntakeRequestToSlotOutcomeDTO Envelope deriving (Show, Eq)
instance ToJSON MatchIntakeRequestToSlotOutcomeDTO where toJSON (MatchIntakeRequestToSlotOutcomeDTO e) = toJSON e
instance ToSchema MatchIntakeRequestToSlotOutcomeDTO where
  declareNamedSchema _ = answerSchema "MatchIntakeRequestToSlotOutcome" matchIntakeRequestToSlotOutcomeCases

newtype CreateDoctorAnswer = CreateDoctorAnswer Envelope deriving (Show, Eq)
instance ToJSON CreateDoctorAnswer where toJSON (CreateDoctorAnswer e) = toJSON e
instance ToSchema CreateDoctorAnswer where
  declareNamedSchema _ = answerSchema "CreateDoctorAnswer" [on (ok :: Outcome DoctorDTO)]

newtype CreatePatientAnswer = CreatePatientAnswer Envelope deriving (Show, Eq)
instance ToJSON CreatePatientAnswer where toJSON (CreatePatientAnswer e) = toJSON e
instance ToSchema CreatePatientAnswer where
  declareNamedSchema _ = answerSchema "CreatePatientAnswer" [on (ok :: Outcome PatientDTO)]

newtype CreateHealthcareServiceAnswer = CreateHealthcareServiceAnswer Envelope deriving (Show, Eq)
instance ToJSON CreateHealthcareServiceAnswer where toJSON (CreateHealthcareServiceAnswer e) = toJSON e
instance ToSchema CreateHealthcareServiceAnswer where
  declareNamedSchema _ =
    answerSchema "CreateHealthcareServiceAnswer" [on (ok :: Outcome HealthcareServiceDTO)]

newtype SubmitIntakeRequestAnswer = SubmitIntakeRequestAnswer Envelope deriving (Show, Eq)
instance ToJSON SubmitIntakeRequestAnswer where toJSON (SubmitIntakeRequestAnswer e) = toJSON e
instance ToSchema SubmitIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "SubmitIntakeRequestAnswer"
    [on (ok :: Outcome SubmittedIntakeRequestDTO), on patientNotFound]

newtype AcceptSubmittedIntakeRequestAnswer = AcceptSubmittedIntakeRequestAnswer Envelope
  deriving (Show, Eq)
instance ToJSON AcceptSubmittedIntakeRequestAnswer where
  toJSON (AcceptSubmittedIntakeRequestAnswer e) = toJSON e
instance ToSchema AcceptSubmittedIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "AcceptSubmittedIntakeRequestAnswer" $
    transitionCases @TriagedIntakeRequestDTO
      <> [on intakeRequestNotFound, on healthcareServiceNotFound, on doctorNotFound]

newtype RejectSubmittedIntakeRequestAnswer = RejectSubmittedIntakeRequestAnswer Envelope
  deriving (Show, Eq)
instance ToJSON RejectSubmittedIntakeRequestAnswer where
  toJSON (RejectSubmittedIntakeRequestAnswer e) = toJSON e
instance ToSchema RejectSubmittedIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "RejectSubmittedIntakeRequestAnswer" $
    transitionCases @RejectedIntakeRequestDTO <> [on intakeRequestNotFound]

newtype MatchAcceptedIntakeRequestToSlotAnswer = MatchAcceptedIntakeRequestToSlotAnswer Envelope
  deriving (Show, Eq)
instance ToJSON MatchAcceptedIntakeRequestToSlotAnswer where
  toJSON (MatchAcceptedIntakeRequestToSlotAnswer e) = toJSON e
instance ToSchema MatchAcceptedIntakeRequestToSlotAnswer where
  declareNamedSchema _ = answerSchema "MatchAcceptedIntakeRequestToSlotAnswer" $
    matchIntakeRequestToSlotOutcomeCases
      <> [on intakeRequestNotFound, on intakeRequestInWrongState, on intakeRequestDoesNotMatchSlot]

newtype WithdrawIntakeRequestAnswer = WithdrawIntakeRequestAnswer Envelope deriving (Show, Eq)
instance ToJSON WithdrawIntakeRequestAnswer where toJSON (WithdrawIntakeRequestAnswer e) = toJSON e
instance ToSchema WithdrawIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "WithdrawIntakeRequestAnswer" $
    transitionCases @WithdrawnIntakeRequestDTO <> [on intakeRequestNotFound]

newtype MarkAcceptedIntakeRequestStaleAnswer = MarkAcceptedIntakeRequestStaleAnswer Envelope
  deriving (Show, Eq)
instance ToJSON MarkAcceptedIntakeRequestStaleAnswer where
  toJSON (MarkAcceptedIntakeRequestStaleAnswer e) = toJSON e
instance ToSchema MarkAcceptedIntakeRequestStaleAnswer where
  declareNamedSchema _ = answerSchema "MarkAcceptedIntakeRequestStaleAnswer" $
    transitionCases @StaleIntakeRequestDTO <> [on intakeRequestNotFound, on intakeRequestInWrongState]

newtype CloseAppointedIntakeRequestAnswer = CloseAppointedIntakeRequestAnswer Envelope
  deriving (Show, Eq)
instance ToJSON CloseAppointedIntakeRequestAnswer where
  toJSON (CloseAppointedIntakeRequestAnswer e) = toJSON e
instance ToSchema CloseAppointedIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "CloseAppointedIntakeRequestAnswer" $
    transitionCases @ClosedIntakeRequestDTO <> [on intakeRequestNotFound, on intakeRequestInWrongState]

newtype MatchAvailableSlotByPriorityAnswer = MatchAvailableSlotByPriorityAnswer Envelope
  deriving (Show, Eq)
instance ToJSON MatchAvailableSlotByPriorityAnswer where
  toJSON (MatchAvailableSlotByPriorityAnswer e) = toJSON e
instance ToSchema MatchAvailableSlotByPriorityAnswer where
  declareNamedSchema _ = answerSchema "MatchAvailableSlotByPriorityAnswer"
    [on noIntakeRequestMatched, on matchIntakeRequestToSlotOutcome]

newtype CreateAvailableSlotAnswer = CreateAvailableSlotAnswer Envelope deriving (Show, Eq)
instance ToJSON CreateAvailableSlotAnswer where toJSON (CreateAvailableSlotAnswer e) = toJSON e
instance ToSchema CreateAvailableSlotAnswer where
  declareNamedSchema _ = answerSchema "CreateAvailableSlotAnswer"
    [on availableSlotAdded, on availableSlotOverlapsDoctorCalendar, on doctorNotFound, on healthcareServiceNotFound]

newtype FetchDoctorAnswer = FetchDoctorAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchDoctorAnswer where toJSON (FetchDoctorAnswer e) = toJSON e
instance ToSchema FetchDoctorAnswer where
  declareNamedSchema _ = answerSchema "FetchDoctorAnswer" [on (ok :: Outcome DoctorDTO), on doctorNotFound]

newtype FetchDoctorsAnswer = FetchDoctorsAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchDoctorsAnswer where toJSON (FetchDoctorsAnswer e) = toJSON e
instance ToSchema FetchDoctorsAnswer where
  declareNamedSchema _ = answerSchema "FetchDoctorsAnswer" [on (ok :: Outcome [DoctorDTO])]

newtype FetchPatientAnswer = FetchPatientAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchPatientAnswer where toJSON (FetchPatientAnswer e) = toJSON e
instance ToSchema FetchPatientAnswer where
  declareNamedSchema _ =
    answerSchema "FetchPatientAnswer" [on (ok :: Outcome PatientDTO), on patientNotFound]

newtype FetchPatientsAnswer = FetchPatientsAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchPatientsAnswer where toJSON (FetchPatientsAnswer e) = toJSON e
instance ToSchema FetchPatientsAnswer where
  declareNamedSchema _ = answerSchema "FetchPatientsAnswer" [on (ok :: Outcome [PatientDTO])]

newtype FetchHealthcareServiceAnswer = FetchHealthcareServiceAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchHealthcareServiceAnswer where toJSON (FetchHealthcareServiceAnswer e) = toJSON e
instance ToSchema FetchHealthcareServiceAnswer where
  declareNamedSchema _ = answerSchema "FetchHealthcareServiceAnswer"
    [on (ok :: Outcome HealthcareServiceDTO), on healthcareServiceNotFound]

newtype FetchHealthcareServicesAnswer = FetchHealthcareServicesAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchHealthcareServicesAnswer where toJSON (FetchHealthcareServicesAnswer e) = toJSON e
instance ToSchema FetchHealthcareServicesAnswer where
  declareNamedSchema _ =
    answerSchema "FetchHealthcareServicesAnswer" [on (ok :: Outcome [HealthcareServiceDTO])]

newtype FetchAvailableSlotAnswer = FetchAvailableSlotAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchAvailableSlotAnswer where toJSON (FetchAvailableSlotAnswer e) = toJSON e
instance ToSchema FetchAvailableSlotAnswer where
  declareNamedSchema _ = answerSchema "FetchAvailableSlotAnswer"
    [on (ok :: Outcome AvailableSlotDTO), on availableSlotConsumed]

newtype FetchIntakeRequestAnswer = FetchIntakeRequestAnswer Envelope deriving (Show, Eq)
instance ToJSON FetchIntakeRequestAnswer where toJSON (FetchIntakeRequestAnswer e) = toJSON e
instance ToSchema FetchIntakeRequestAnswer where
  declareNamedSchema _ = answerSchema "FetchIntakeRequestAnswer"
    [on (ok :: Outcome IntakeRequestDTO), on intakeRequestNotFound]

newtype FetchSubmittedIntakeRequestsAnswer = FetchSubmittedIntakeRequestsAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchSubmittedIntakeRequestsAnswer where
  toJSON (FetchSubmittedIntakeRequestsAnswer e) = toJSON e
instance ToSchema FetchSubmittedIntakeRequestsAnswer where
  declareNamedSchema _ = answerSchema "FetchSubmittedIntakeRequestsAnswer"
    [on (ok :: Outcome [SubmittedIntakeRequestDTO])]

newtype FetchAcceptedIntakeRequestsAnswer = FetchAcceptedIntakeRequestsAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchAcceptedIntakeRequestsAnswer where
  toJSON (FetchAcceptedIntakeRequestsAnswer e) = toJSON e
instance ToSchema FetchAcceptedIntakeRequestsAnswer where
  declareNamedSchema _ = answerSchema "FetchAcceptedIntakeRequestsAnswer"
    [on (ok :: Outcome [TriagedIntakeRequestDTO])]

newtype FetchAppointedIntakeRequestsAnswer = FetchAppointedIntakeRequestsAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchAppointedIntakeRequestsAnswer where
  toJSON (FetchAppointedIntakeRequestsAnswer e) = toJSON e
instance ToSchema FetchAppointedIntakeRequestsAnswer where
  declareNamedSchema _ = answerSchema "FetchAppointedIntakeRequestsAnswer"
    [on (ok :: Outcome [AppointedIntakeRequestDTO])]

newtype FetchRejectedIntakeRequestsByRejectedAtAnswer =
  FetchRejectedIntakeRequestsByRejectedAtAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchRejectedIntakeRequestsByRejectedAtAnswer where
  toJSON (FetchRejectedIntakeRequestsByRejectedAtAnswer e) = toJSON e
instance ToSchema FetchRejectedIntakeRequestsByRejectedAtAnswer where
  declareNamedSchema _ = answerSchema "FetchRejectedIntakeRequestsByRejectedAtAnswer"
    [on (ok :: Outcome [RejectedIntakeRequestDTO])]

newtype FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer =
  FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer where
  toJSON (FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer e) = toJSON e
instance ToSchema FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer where
  declareNamedSchema _ = answerSchema "FetchWithdrawnIntakeRequestsByWithdrawnAtAnswer"
    [on (ok :: Outcome [WithdrawnIntakeRequestDTO])]

newtype FetchStaleIntakeRequestsByStaleAtAnswer = FetchStaleIntakeRequestsByStaleAtAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchStaleIntakeRequestsByStaleAtAnswer where
  toJSON (FetchStaleIntakeRequestsByStaleAtAnswer e) = toJSON e
instance ToSchema FetchStaleIntakeRequestsByStaleAtAnswer where
  declareNamedSchema _ = answerSchema "FetchStaleIntakeRequestsByStaleAtAnswer"
    [on (ok :: Outcome [StaleIntakeRequestDTO])]

newtype FetchClosedIntakeRequestsByStartAnswer = FetchClosedIntakeRequestsByStartAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchClosedIntakeRequestsByStartAnswer where
  toJSON (FetchClosedIntakeRequestsByStartAnswer e) = toJSON e
instance ToSchema FetchClosedIntakeRequestsByStartAnswer where
  declareNamedSchema _ = answerSchema "FetchClosedIntakeRequestsByStartAnswer"
    [on (ok :: Outcome [ClosedIntakeRequestDTO])]

newtype FetchDoctorCalendarEntriesOverlappingAnswer =
  FetchDoctorCalendarEntriesOverlappingAnswer Envelope
  deriving (Show, Eq)
instance ToJSON FetchDoctorCalendarEntriesOverlappingAnswer where
  toJSON (FetchDoctorCalendarEntriesOverlappingAnswer e) = toJSON e
instance ToSchema FetchDoctorCalendarEntriesOverlappingAnswer where
  declareNamedSchema _ = answerSchema "FetchDoctorCalendarEntriesOverlappingAnswer"
    [on (ok :: Outcome [DoctorCalendarEntryDTO])]
