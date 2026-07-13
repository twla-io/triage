# API Strategy: REST

`Service.hs`'s 11 current operations map almost directly into route design — every one of them mutates (see `commands-vs-queries-naming` in `SKILL.md`), so every one becomes a `POST` or `PATCH`. There are currently no `GET`-worthy reads exposed at the `Service.hs` layer to map here at all.

## Mapping

| `Service.hs` function | HTTP | Route (example) |
|---|---|---|
| `createDoctor :: ConnectionPool -> Text -> IO Doctor` | `POST` | `/doctors` |
| `createPatient :: ConnectionPool -> Text -> IO Patient` | `POST` | `/patients` |
| `createHealthcareService :: ConnectionPool -> Text -> Duration -> IO HealthcareService` | `POST` | `/healthcare-services` |
| `createAvailableSlot :: ConnectionPool -> AvailableSlot -> IO SlotCreationOutcome` | `POST` | `/slots` |
| `submitIntakeRequest :: ConnectionPool -> PatientId -> Text -> DoctorRequirement -> UTCTime -> IO SubmittedIntakeRequest` | `POST` | `/intake-requests` |
| `acceptSubmittedIntakeRequest :: ConnectionPool -> IntakeRequestId -> HealthcareServiceId -> IntakeRequestPriority -> UTCTime -> IO (Either ServiceError TriagedIntakeRequest)` | `POST`/`PATCH` | `/intake-requests/:id/accept` |
| `rejectSubmittedIntakeRequest :: ConnectionPool -> IntakeRequestId -> UTCTime -> Text -> IO (Either ServiceError IntakeRequest)` | `POST`/`PATCH` | `/intake-requests/:id/reject` |
| `matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)` | (internal — not its own route, see below) | — |
| `matchAcceptedIntakeRequestToSlot :: ConnectionPool -> IntakeRequestId -> AvailableSlot -> IO (Either ServiceError MatchOutcome)` | `POST` | `/intake-requests/:id/match` |
| `reclaimAppointedIntakeRequest :: ConnectionPool -> IntakeRequestId -> IO (Either ServiceError TriagedIntakeRequest)` | `POST`/`PATCH` | `/intake-requests/:id/reclaim` — **whether this is exposed directly at all is an open question**, see `SKILL.md` |
| `closeAppointedIntakeRequest :: ConnectionPool -> IntakeRequestId -> CloseReason -> IO (Either ServiceError IntakeRequest)` | `POST`/`PATCH` | `/intake-requests/:id/close` |

Per `checkwaitlist-not-an-endpoint` (`SKILL.md`), `matchWaitlistToSlot` does **not** get its own route — it runs inside whatever handler creates a new slot:

```
POST /slots → createAvailableSlot → matchWaitlistToSlot → response reflects the resulting
                                                            SlotCreationOutcome/MatchOutcome
```

## Request/response shapes

Following `SKILL.md`'s rules:
- IDs are plain UUID strings in JSON bodies, never wrapped (`opaque-uuid-ids`).
- `IntakeRequest`'s six states need a decided wire shape before response bodies for `/intake-requests/:id`-style routes can be written — **not decided**, see `SKILL.md`'s open questions. Don't invent a shape here to unblock this table; the routes above are named and verb-mapped without committing to what their response bodies look like.

## Error and outcome responses

Per `error-vs-outcome-mapping` (`SKILL.md`), the two categories below must map to genuinely different response shapes — but **which** shapes (status codes, envelope format) is not decided here:

- **`ServiceError`** (`PersistenceDecodeError`, `RequestNotFound`, `RequestNotSubmittedAnymore`, `RequestNotAccepted`, `RequestNotYetTriaged`, `RequestNotAppointed`, `RequestAlreadyClosed`) — a caller mistake, a stale precondition, or an infrastructure failure. These are the closest analog to a conventional REST error response, but exactly which HTTP status each constructor maps to (a `404`-shaped one for `RequestNotFound` vs. a `409`-shaped one for the state-mismatch constructors vs. a `5xx`-shaped one for `PersistenceDecodeError` are all plausible, none chosen) is an open question.
- **Outcome types** (`MatchOutcome`'s `Matched`/`NoEligibleRequest`/`RequestIneligible`/`SlotAlreadyClaimed`/`RequestAlreadyClaimed`; `SlotCreationOutcome`'s `SlotCreated`/`SlotConflict`) — legitimate business/concurrency branches, not errors. `NoEligibleRequest` and `SlotConflict` in particular are completely normal outcomes of correct concurrent operation, not failures — whatever status/shape they get should read as "this succeeded, here's what happened," not as an error response. Exact shape not decided.

## When to choose this

Default choice if the team already has a REST API elsewhere, or the consuming clients (mobile app, doctor's web UI) expect conventional REST semantics.
