# API Strategy: Event-Sourced / CQRS

**This is a documented, available option — not the currently favored direction, and not partially adopted anywhere in this codebase.** `docs/decisions.md`'s "Event sourcing: explored, rejected (2026-06)" entry already settled this question, on cost grounds: sealed types already provide most of the benefit event sourcing would add (valid-state-only representation, explicit transitions), and the operational cost — event store, replay, projection maintenance — isn't justified at 2-3 doctor scale. That decision was made independently of API design specifically (it was evaluated for the Slot/AppointmentRequest aggregate, before the current `IntakeRequest` model existed), but nothing since has reopened it. An earlier version of this file described this strategy as matching "the CQRS/ES shape already sketched for `triage`'s application layer (`AppM = ReaderT AppEnv (ExceptT AppError IO)`, ...)" — no such type exists anywhere in this codebase (confirmed by grep across all `.hs` files). That framing is removed here; nothing about this option is already scaffolded or in progress. Revisit only if scale assumptions genuinely change, per `docs/decisions.md`'s own closing note on that entry.

Commands become commands posted to a command handler that validates, runs the pure domain transition, and emits one or more events. Queries read from a separate projection (read model), never from the write-side event log directly.

## Mapping (illustrative, not built)

Each mutating `Service.hs` operation would correspond to one application-layer command and one or more events:

| `Service.hs` function | Command | Event(s) emitted |
|---|---|---|
| `createDoctor` | `CreateDoctor Text` | `DoctorCreated` |
| `createPatient` | `CreatePatient Text` | `PatientCreated` |
| `createHealthcareService` | `CreateHealthcareService Text Duration` | `HealthcareServiceCreated` |
| `submitIntakeRequest` | `SubmitIntakeRequest PatientId Text DoctorRequirement UTCTime` | `IntakeRequestSubmitted` |
| `acceptSubmittedIntakeRequest` | `AcceptSubmittedIntakeRequest IntakeRequestId HealthcareServiceId IntakeRequestPriority UTCTime` | `IntakeRequestAccepted` |
| `rejectSubmittedIntakeRequest` | `RejectSubmittedIntakeRequest IntakeRequestId UTCTime Text` | `IntakeRequestRejected` |
| `createAvailableSlot` → `matchWaitlistToSlot`'s `Matched` outcome | (internal to the `SlotCreated`-triggering handler) | `SlotCreated`, then `IntakeRequestMatched` — **emitted together, same transaction** (mirrors `Persistence.persistMatchedIntakeRequest`'s existing atomicity requirement, expressed as an event-log invariant instead of a transactional one) |
| `createAvailableSlot` → `matchWaitlistToSlot`'s `NoEligibleRequest` outcome | (internal) | `SlotCreated` only |
| `matchAcceptedIntakeRequestToSlot`'s `Matched` outcome | `MatchAcceptedIntakeRequestToSlot IntakeRequestId AvailableSlot` | `IntakeRequestMatched` |
| `reclaimAppointedIntakeRequest` | `ReclaimAppointedIntakeRequest IntakeRequestId` | `IntakeRequestReclaimed` |
| `closeAppointedIntakeRequest` | `CloseAppointedIntakeRequest IntakeRequestId CloseReason` | `IntakeRequestClosed` |

## Read side

There are currently no read operations at the `Service.hs` layer to map to projections at all (see `SKILL.md`'s `commands-vs-queries-naming`) — `fetchIntakeRequest`/`fetchIntakeWaitlist` exist only in `Persistence.hs`. Under this strategy they would back denormalized projections rebuilt from the event stream (e.g. an `IntakeRequestsProjection` table updated by a handler listening for `IntakeRequestSubmitted`/`IntakeRequestAccepted`/`IntakeRequestMatched`/..., queried directly by API read endpoints without touching the event log per-request) — but this is illustrative of the pattern, not a plan being executed.

## Atomicity

The invariant that `persistMatchedIntakeRequest` currently enforces transactionally (the `slots` row deletion and the `intake_requests` state transition must both land or neither does — see `docs/decisions.md`'s "Matching is atomic delete-and-update" entry) would, under this strategy, need to hold at the event-append level instead: `SlotCreated`/`IntakeRequestMatched`-style pairs would need to be appended in one batch, by construction, so there's no way to observe one without the other.

## When to choose this

Best when the doctor or business stakeholders need an audit trail of *what happened and when* (e.g. "why was this patient offered this slot"), or the team already has event-sourcing infrastructure elsewhere. Given the existing rejection in `docs/decisions.md`, choosing this now would mean actively reopening a settled cost/benefit call, not defaulting to a direction already in motion — confirm that's genuinely wanted before picking this over `rest.md`.
