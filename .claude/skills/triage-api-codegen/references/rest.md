# API Strategy: REST

`Service.hs`'s 11 mutating operations map almost directly into route design — every one of them mutates, and per `verb-minimalism`/`action-endpoints-not-generic-patch` (`SKILL.md`) every one becomes an action-suffixed `POST`, never `PATCH`. Its 11 read functions (see `commands-vs-queries-naming` in `SKILL.md`) map just as directly to `GET` routes, one per `fetch*` function.

## Mapping

### Commands (mutations)

| `Service.hs` function | HTTP | Route (example) |
|---|---|---|
| `createDoctor :: ConnectionPool -> Text -> IO Doctor` | `POST` | `/doctors` |
| `createPatient :: ConnectionPool -> Text -> IO Patient` | `POST` | `/patients` |
| `createHealthcareService :: ConnectionPool -> Text -> Duration -> IO HealthcareService` | `POST` | `/healthcare-services` |
| `createAvailableSlot :: ConnectionPool -> AvailableSlot -> IO SlotCreationOutcome` | `POST` | `/slots` |
| `submitIntakeRequest :: ConnectionPool -> PatientId -> Text -> DoctorRequirement -> UTCTime -> IO SubmittedIntakeRequest` | `POST` | `/intake-requests` |
| `acceptSubmittedIntakeRequest :: ConnectionPool -> IntakeRequestId -> HealthcareServiceId -> IntakeRequestPriority -> UTCTime -> IO (Either ServiceError TriagedIntakeRequest)` | `POST` | `/intake-requests/:id/accept` |
| `rejectSubmittedIntakeRequest :: ConnectionPool -> IntakeRequestId -> UTCTime -> Text -> IO (Either ServiceError IntakeRequest)` | `POST` | `/intake-requests/:id/reject` |
| `matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)` | (internal — not its own route, see below) | — |
| `matchAcceptedIntakeRequestToSlot :: ConnectionPool -> IntakeRequestId -> AvailableSlot -> IO (Either ServiceError MatchOutcome)` | `POST` | `/intake-requests/:id/match` |
| `reclaimAppointedIntakeRequest :: ConnectionPool -> IntakeRequestId -> IO (Either ServiceError TriagedIntakeRequest)` | `POST` | `/intake-requests/:id/reclaim` — a directly-callable endpoint, per `action-endpoints-not-generic-patch` (`SKILL.md`); not gated behind any higher-level action |
| `closeAppointedIntakeRequest :: ConnectionPool -> IntakeRequestId -> CloseReason -> IO (Either ServiceError IntakeRequest)` | `POST` | `/intake-requests/:id/close` |

All action-suffixed, per `action-endpoints-not-generic-patch` (`SKILL.md`) — never `PATCH /intake-requests/:id` with a state field.

Per `checkwaitlist-not-an-endpoint` (`SKILL.md`), `matchWaitlistToSlot` does **not** get its own route — it runs inside whatever handler creates a new slot:

```
POST /slots → createAvailableSlot → matchWaitlistToSlot → response reflects the resulting
                                                            SlotCreationOutcome/MatchOutcome
```

### Reads (queries)

Route naming mirrors each function's own name, per `commands-vs-queries-naming` (`SKILL.md`): singular `fetch<Noun>` takes an ID path parameter, plural `fetch<Noun>s` lists. Range/filter parameters (`UTCTime` bounds, optional `DoctorId`/`HealthcareServiceId`) are query parameters, not path segments, since none of them identify a single resource.

| `Service.hs` function | HTTP | Route (example) |
|---|---|---|
| `fetchDoctor :: ConnectionPool -> DoctorId -> IO (Maybe Doctor)` | `GET` | `/doctors/:id` |
| `fetchPatient :: ConnectionPool -> PatientId -> IO (Maybe Patient)` | `GET` | `/patients/:id` |
| `fetchHealthcareService :: ConnectionPool -> HealthcareServiceId -> IO (Either DecodeError (Maybe HealthcareService))` | `GET` | `/healthcare-services/:id` |
| `fetchDoctors :: ConnectionPool -> IO [Doctor]` | `GET` | `/doctors` |
| `fetchPatients :: ConnectionPool -> IO [Patient]` | `GET` | `/patients` |
| `fetchHealthcareServices :: ConnectionPool -> IO (Either DecodeError [HealthcareService])` | `GET` | `/healthcare-services` |
| `fetchAvailableSlots :: ConnectionPool -> UTCTime -> UTCTime -> Maybe DoctorId -> Maybe HealthcareServiceId -> IO (Either DecodeError [AvailableSlot])` | `GET` | `/slots?start=...&end=...&doctorId=...&healthcareServiceId=...` |
| `fetchIntakeRequest :: ConnectionPool -> IntakeRequestId -> IO (Either DecodeError (Maybe IntakeRequest))` | `GET` | `/intake-requests/:id` (example) |
| `fetchIntakeWaitlist :: ConnectionPool -> IO (Either DecodeError [TriagedIntakeRequest])` | `GET` | `/intake-requests/waitlist` (example) |
| `fetchAppointedIntakeRequests :: ConnectionPool -> UTCTime -> UTCTime -> Maybe DoctorId -> IO (Either DecodeError [AppointedIntakeRequest])` | `GET` | `/intake-requests/appointed?start=...&end=...&doctorId=...` |
| `fetchCalendarView :: ConnectionPool -> UTCTime -> UTCTime -> Maybe DoctorId -> IO (Either DecodeError [CalendarEntry])` | `GET` | `/calendar?start=...&end=...&doctorId=...` |

`CalendarEntry`'s two constructors (`Slot AvailableSlot` / `Appointment AppointedIntakeRequest`) need a wire shape before `/calendar`'s response body can be written — not decided here, same status as the six-state `IntakeRequest` shape below.

## Request/response shapes

Following `SKILL.md`'s rules:
- IDs are plain UUID strings in JSON bodies, never wrapped (`opaque-uuid-ids`).
- `IntakeRequest`'s six states need a decided wire shape before response bodies for `/intake-requests/:id`-style routes can be written — **not decided**, see `SKILL.md`'s open questions. Don't invent a shape here to unblock this table; the routes above are named and verb-mapped without committing to what their response bodies look like.

## Error and outcome responses

Per `error-vs-outcome-mapping` (`SKILL.md`), the wire mapping is decided: four HTTP status codes, each answering a genuinely different question about *where* the request failed or succeeded, not a graded scale of "how wrong."

- **`400`** — malformed before reaching `Service.hs` at all: bad JSON, a field with the wrong type, a missing required field, an ID that isn't even a valid UUID shape.
- **`404`** — the route/path itself doesn't resolve to a known resource shape, decided by the router, before any `Service.hs` call.
- **`200`** — `Service.hs` actually ran and answered. This covers **both** success **and** every `ServiceError`/outcome-type constructor — `PersistenceDecodeError` aside (see `500` below) — discriminated by a field in the response body, never by status code:
  - `ServiceError`'s `RequestNotFound`, `RequestNotSubmittedAnymore`, `RequestNotAccepted`, `RequestNotYetTriaged`, `RequestNotAppointed`, `RequestAlreadyClosed`.
  - `MatchOutcome`'s `Matched`, `NoEligibleRequest`, `RequestIneligible`, `SlotAlreadyClaimed`, `RequestAlreadyClaimed`.
  - `SlotCreationOutcome`'s `SlotCreated`, `SlotConflict`.
- **`500`** — outside the domain's vocabulary entirely: `PersistenceDecodeError`, a DB connection failure, anything genuinely unexpected.

**Worked example — the case most likely to get "fixed" back to the wrong status by default:** `POST /intake-requests/11111111-.../accept` for a well-formed but nonexistent `IntakeRequestId` is a **`200`**, not a `404`. The path resolved fine (`/intake-requests/:id/accept` is a real route), the ID is syntactically valid, and `Service.acceptSubmittedIntakeRequest` genuinely ran `fetchIntakeRequest`, got `Right Nothing`, and returned `Left (RequestNotFound reqId)` — a real domain answer, discriminated in the response body (e.g. `{"outcome": "requestNotFound", "requestId": "..."}`), not signaled via status code. Reserve `404` for when the *route itself* doesn't exist, not for "the resource this well-formed request asked about turned out not to exist" — that distinction is deliberate, not an oversight, per `error-vs-outcome-mapping`.

## When to choose this

Default choice if the team already has a REST API elsewhere, or the consuming clients (mobile app, doctor's web UI) expect conventional REST semantics.
