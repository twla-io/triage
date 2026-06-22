# triage

A priority-based medical appointment scheduling domain model in Haskell.

## What is it?

`triage` models a medical practice's appointment scheduling system around one
core idea: instead of reserving dedicated emergency slots (which sit idle on
quiet days and waste capacity), every slot is offered to the
highest-priority matching patient on a waitlist, ordered by an `Ord`
instance — `Emergency < Urgent < Routine`, FIFO within each tier.

The slot lifecycle is encoded as separate types rather than a status field —
`PendingSlot`, `OfferedSlot`, `AvailableSlot`, `BookedSlot` — so invalid
transitions are compile errors, not runtime guards. Every transition
function is total.

## The Model

Five core entities: `Service`, `Slot`, `Appointment`, `WaitlistEntry`,
and `Patient` (identified only by `PatientId` — created through a booking,
never in isolation).

```haskell
data Slot
  = Pending   PendingSlot
  | Offered   OfferedSlot
  | Available AvailableSlot
  | Booked    BookedSlot

data WaitlistEntry
  = EmergencyEntry WaitlistDetails
  | UrgentEntry    WaitlistDetails (Maybe DoctorId)
  | RoutineEntry   WaitlistDetails (Maybe DoctorId) DueAt
```

The core protocol:

```haskell
checkWaitlist :: PendingSlot -> [WaitlistEntry] -> UTCTime -> WaitlistResult
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
