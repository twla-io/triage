# triage

A priority-based medical appointment scheduling domain model in Haskell.

## What is it?

`triage` models a medical practice's appointment scheduling system around one
core idea: instead of reserving dedicated emergency slots (which sit idle on
quiet days and waste capacity), every slot is offered to the
highest-priority matching request on the waitlist, ordered by an `Ord`
instance — `Emergency < Urgent < Routine`, FIFO within each tier.

The slot lifecycle is encoded as separate types rather than a status field —
`PendingSlot`, `OfferedSlot`, `AvailableSlot`, `BookedSlot` — so invalid
transitions are compile errors, not runtime guards. Every transition
function is total.

## Provenance, not just types

Each slot lifecycle type goes a step further than the usual "make illegal
states unrepresentable": their constructors aren't exported at all. The
only way to obtain a `BookedSlot` from outside `Domain.hs` is to call
`bookAppointment` or `tryAccept` — and each of those demands an
`AvailableSlot` or an `OfferedSlot` as input, which themselves can only
come from their own single sanctioned producer, all the way back to
`mkPendingSlot`.

The result: holding a `BookedSlot` is a compile-time-enforced proof that
the slot was `Pending`, was legitimately released to `Available`, and was
then booked with a matching `Appointment` — not a convention callers are
trusted to follow, a fact the type system guarantees. The same pattern
seals `OfferedSlot` and `AppointmentRequestWithOffer`: `giveOffer` is the
only place either is constructed, so the two can never be created
separately or out of sync with each other.

Where a guarantee like that genuinely isn't available — `tryAccept`
reconciles two values that were created together but independently
re-fetched, so nothing at the type level can confirm they're still the
matching pair — the function says so honestly with `Maybe`, rather than
assuming.

## The Model

Five core entities: `Service`, `Slot`, `Appointment`, `AppointmentRequest`
(a waitlist registration), and `Patient` (identified only by `PatientId` —
created through a booking, never in isolation).

```haskell
data Slot
  = Pending   PendingSlot
  | Offered   OfferedSlot
  | Available AvailableSlot
  | Booked    BookedSlot

data AppointmentRequest
  = EmergencyRequest AppointmentRequestDetails
  | UrgentRequest    AppointmentRequestDetails
  | RoutineRequest   AppointmentRequestDetails (Maybe DoctorId) DueAt
```

The core protocol:

```haskell
checkWaitlist :: PendingSlot -> [AppointmentRequest] -> UTCTime -> MatchAppointmentRequestResult
```

A pure function — no IO, no DB — that decides who gets a freed slot next.

See `src/Domain.hs` for the full model and the reasoning behind each
design decision, recorded as inline comments at the point where the
decision was made.

## Building

```
cabal build
cabal test
```

## Generating downstream layers

If you're generating a database schema, an API, or a UI from this domain
model — whether by hand or with an AI coding agent — read the relevant
skill under `skills/` first:

- `skills/triage-db-codegen` — database schema conventions
- `skills/triage-api-codegen` — API conventions
- `skills/triage-ui-codegen` — UI/UX conventions

Each separates what's a fixed invariant of the domain model from what's a
genuine architecture choice (e.g. which DB schema shape, REST vs.
event-sourced) — the invariants always apply; the choices should be
confirmed with whoever owns that layer before assuming one.

## Status

Actively evolving alongside conversations with the domain expert (a
practicing doctor). Some plausible-looking rules have been deliberately
left out after being identified as unvalidated — see `src/Domain.hs`'s
comments for examples. Cheaper to add a rule later than to carry
speculative complexity now.

## License

MIT — see `LICENSE`. If circumstances change later, the license can change too; nothing here is locked in permanently.