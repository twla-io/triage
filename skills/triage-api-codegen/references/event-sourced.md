# API Strategy: Event-Sourced / CQRS

Commands become commands posted to a command handler that validates, runs the pure domain transition, and emits one or more events. Queries read from a separate projection (read model), never from the write-side event log directly.

This matches the CQRS/ES shape already sketched for `triage`'s application layer (`AppM = ReaderT AppEnv (ExceptT AppError IO)`, synchronous in-process event dispatch).

## Mapping

Each Command in `Domain.hs`'s exports corresponds to one application-layer command and one or more events:

| Domain function | Command | Event(s) emitted |
|---|---|---|
| `bookSlot` | `BookSlot SlotId AppointmentId` | `SlotBooked`, `AppointmentOpened` |
| `declineOffer` | `DeclineOffer SlotId AppointmentRequestId` | `OfferDeclined` |
| `checkWaitlist`'s `Matched` result | (internal to the `SlotCreated`/`SlotFreed` handler) | `SlotOffered`, `AppointmentRequestOffered` — **emitted together, same transaction** (this is the atomicity invariant from `SKILL.md`, expressed as "these events are always written in the same append") |
| `checkWaitlist`'s `NoMatch` result | (internal) | `SlotReleased` |

## Read side

Queries (`matches`, `requestId`, `priorityOf`, etc.) are not exposed as commands — they either run inside a command handler's decision logic, or back a **projection**: a denormalized read model rebuilt from the event stream, queried directly by API read endpoints. E.g. an `AvailableSlotsProjection` table, updated by a handler listening for `SlotReleased`/`SlotBooked`, queried directly by `GET /slots?status=available` without touching the event log per-request.

## Atomicity

The invariant "both halves of `Matched` must persist together" is naturally satisfied here: events from one command handler invocation are appended to the event store in one batch, in one transaction, by construction — there's no way to write `SlotOffered` without `AppointmentRequestOffered` in the same handler call. This is one of the reasons CQRS/ES was originally a good fit for this domain's atomicity requirements.

## When to choose this

Best when the doctor or business stakeholders need an audit trail of *what happened and when* (e.g. "why was this patient offered this slot"), or when the team already has event-sourcing infrastructure. Adds real complexity (event versioning, projection rebuilding) that isn't worth it for a small single-practice deployment unless that audit trail is genuinely valued — confirm this is wanted before defaulting to it over REST.
