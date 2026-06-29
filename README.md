# triage

A priority-based medical appointment scheduling domain model in Haskell.

## What is it?

`triage` models a medical practice's appointment scheduling system around one
core idea: instead of reserving dedicated emergency slots (which sit idle on
quiet days and waste capacity), every freed slot is matched directly to the
highest-priority eligible request on the waitlist, ordered by an `Ord`
instance — `Emergency < Urgent < Routine`, FIFO within each tier. A match
commits immediately to a real, booked appointment — there's no intermediate
"offered, awaiting response" state where a slot sits held against one
patient's decision. Capacity should never be withheld from everyone else
waiting on one patient's indecision; if a patient doesn't want what they're
given, cancelling or rescheduling is a deliberate, explicit choice, not an
automatic retry into the same slot.

The slot lifecycle is encoded as separate types rather than a status field —
`PendingSlot`, `AvailableSlot`, `BookedSlot` — so invalid transitions are
compile errors, not runtime guards. Every transition function is total.

## Provenance, not just types

Each slot lifecycle type goes a step further than the usual "make illegal
states unrepresentable": `AvailableSlot` and `BookedSlot`'s constructors
aren't exported at all. The only way to obtain a `BookedSlot` from outside
`Domain.hs` is to call `bookAppointment` (a direct, self-service booking) or
`assignAppointment` (a waitlist match committed directly) — and each of
those demands an `AvailableSlot` or a `PendingSlot` as input, tracing the
chain all the way back to a slot's creation.

The result: holding a `BookedSlot` is a compile-time-enforced proof that the
slot was legitimately released to `Available` (or matched while `Pending`)
and was then booked with a matching `Appointment` — not a convention callers
are trusted to follow, a fact the type system guarantees. The same pattern
seals `OpenAppointment`/`ClosedAppointment`: `bookAppointment`,
`assignAppointment`, and `closeAppointment` are the only places either is
constructed, so a `BookedSlot` can never exist without a matching
`Appointment`, regardless of which path created it.

`PendingSlot` itself is deliberately *not* sealed — it carries no data beyond
a slot's basic details, so there's no invariant left to protect by hiding
its constructor.

## The Model

Six core entities: `Doctor`, `Patient` (both deliberately minimal — `id` and
`name` only, pending a future external system), `Service`, `Slot`,
`AppointmentRequest` (a waitlist registration), and `Appointment`.

```haskell
data Slot
  = Pending   PendingSlot
  | Available AvailableSlot
  | Booked    BookedSlot

data AppointmentRequest
  = EmergencyRequest AppointmentRequestDetails
  | UrgentRequest    AppointmentRequestDetails
  | RoutineRequest   AppointmentRequestDetails (Maybe DoctorId) DueAt
```

The core protocol:

```haskell
checkWaitlist :: PendingSlot -> [AppointmentRequest] -> AppointmentId -> MatchAppointmentRequestResult
```

A pure function — no IO, no DB — that decides who gets a freed slot next and
commits the match directly.

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

- `skills/triage-db-codegen` — database schema and persistence-layer conventions
- `skills/triage-api-codegen` — API conventions
- `skills/triage-ui-codegen` — UI/UX conventions

Each separates fixed invariants of the domain model from genuine architecture
choices — the invariants always apply; the choices should be confirmed with
whoever owns that layer before assuming one.

## Status

Actively evolving alongside conversations with the domain expert (a
practicing doctor). Some plausible-looking rules have been deliberately
left out after being identified as unvalidated — see `src/Domain.hs`'s
comments for examples. Cheaper to add a rule later than to carry
speculative complexity now.

## License

MIT — see `LICENSE`. If circumstances change later, the license can change too; nothing here is locked in permanently.
