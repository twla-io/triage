# Domain model

Read this before working in `src/Domain.hs`. This is the narrative the types
are meant to tell — if code and this doc disagree, that's a bug in one of
them.

## Requests

```
data HealthcareRequest
  = Submitted HealthcareRequestDetails
  | Triaged   TriagedHealthcareRequest
```

A request starts life `Submitted` — patient-provided details only, no
priority yet assigned. Triage (a human or scored decision, not modeled here
yet) produces a `TriagedHealthcareRequest`, which carries a
`HealthcareRequestPriority` and a `UTCTime` deadline.

`TriagedHealthcareRequest` is not a `HealthcareRequestDetails` with extra
fields bolted on — it embeds the submitted details (as its `details` field)
and adds the outcome of triage on top, so "what was originally submitted" is
never lost and "has this been triaged" is a type-level fact, not a nullable
field.

## Priority

```haskell
data HealthcareRequestPriority
  = Emergency EmergencyDue
  | Urgent    UrgentDue
  | Routine   RoutineDue
```

Ordering is fully derived from a hand-written `Ord` instance, not a
tiebreaker chain of separate fields — there's no `requestedAt`/`entryId` in
this type. Tier order (`Emergency < Urgent < Routine`) is structural in the
instance itself: any `Emergency` beats any non-`Emergency`, any `Urgent`
beats any `Routine`. Within a tier, `compare` falls through to the deadline:
`EmergencyDue`/`UrgentDue` derive `Ord` on their `UTCTime`; `RoutineDue` has
its own instance ranking `RoutineWithin < RoutineNotAfter < RoutineNotBefore
< RoutineAnytime`, tighter/earlier constraints first.

The only unresolved case is two requests with a genuinely identical priority
value (same tier, same deadline) — `sortOn` is stable, so that's settled by
input-list order, not by a designed rule. Not currently a problem worth
solving.

## Slots

```
data Slot
  = Available AvailableSlot
  | Booked    BookedSlot
```

Two-state today. `AvailableSlot`/`BookedSlot` carry only what's true in that
state — `BookedSlot` adds the `AppointmentId` it's tied to on top of the
shared `SlotDetails`, rather than that field being hoisted onto `SlotDetails`
itself where it'd be meaningless for an available slot. See
`docs/modeling-principles.md` for why this isn't optional.

## Waitlist matching

```haskell
checkWaitlist
  :: AvailableSlot
  -> AppointmentId
  -> [TriagedHealthcareRequest]
  -> Maybe (BookedSlot, OpenAppointment)
checkWaitlist slot appointmentId =
  listToMaybe
    . mapMaybe (satisfyHealthcareRequest slot appointmentId)
    . sortOn priority
```

Read as: sort the waitlist by priority (using `HealthcareRequestPriority`'s
own `Ord` instance), try to satisfy each in order, take the first success.
The pipeline shape *is* the spec — no separate prose description should be
needed to understand what this does.

## What's deliberately not modeled yet

- Priority *escalation* over time (e.g. a request ages up in priority as its
  deadline approaches). This sounds plausible but has not been validated
  with the doctor — see `docs/decisions.md` open questions. Do not add it
  speculatively.