# API Strategy: REST

Commands map to mutating HTTP verbs; Queries map to `GET`. The Command/Query split from `Domain.hs`'s exports translates almost directly into route design.

## Mapping

| Domain function | HTTP | Route (example) |
|---|---|---|
| `bookAppointment :: AvailableSlot -> AppointmentId -> PatientId -> (BookedSlot, Appointment)` | `POST` | `/slots/:id/book` |
| `declineOffer :: OfferedSlot -> PendingSlot` | `POST` | `/slots/:id/decline` |
| `freeSlot :: BookedSlot -> PendingSlot` (via appointment cancellation) | `POST` | `/appointments/:id/cancel` |
| `matches :: PendingSlot -> AppointmentRequest -> Bool` | `GET` (internal use, not usually its own endpoint) | — |
| `requestId`, `detailsOf`, `priorityOf` | (used internally to build response bodies, not endpoints themselves) | — |

Notice that `checkWaitlist` does **not** get its own route — per the invariant in `SKILL.md`, it's the body of whatever handler responds to "a slot just became free":

```
POST /slots          → create slot → checkWaitlist → atomic write (Offered+Entry, or Available)
POST /appointments/:id/cancel → freeSlot → checkWaitlist → atomic write
```

## Request/response shapes

Following invariant rules from `SKILL.md`:
- IDs are plain UUID strings in JSON bodies, never wrapped.
- A `Slot`'s current state (`Pending`/`Offered`/`Available`/`Booked`) should be represented in the response with a discriminator field (e.g. `"state": "booked"`), mirroring whichever DB strategy was chosen — don't invent a different shape at the API layer than the one chosen for storage, or you've added a translation layer for no reason.

## Error responses

Per the totality invariant, domain transitions themselves don't fail — so REST error responses (4xx) come from boundary conditions, not domain logic:
- `404` — the slot/entry/appointment ID doesn't resolve to anything.
- `409 Conflict` — the resource exists but isn't in the state the operation requires (e.g. `POST /slots/:id/book` on a slot that's already `Booked`). This is the HTTP-level equivalent of "the type wouldn't have allowed this" — surface it as a conflict, not a generic 400.
- `422` — request body failed a smart constructor (e.g. `mkMinutes` rejected the duration).

## When to choose this

Default choice if the team already has a REST API elsewhere, or the consuming clients (mobile app, doctor's web UI) expect conventional REST semantics.
