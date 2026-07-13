# Domain model

Read this before working in `src/Domain.hs`. This is the narrative the types
are meant to tell — if code and this doc disagree, that's a bug in one of
them.

## Intake requests

```haskell
data IntakeRequest
  = Submitted SubmittedIntakeRequest
  | Rejected  SubmittedIntakeRequest UTCTime Text
  | Accepted  TriagedIntakeRequest
  | Appointed AppointedIntakeRequest
  | Withdrawn WithdrawnIntakeRequest
  | Closed    AppointedIntakeRequest CloseReason
```

`IntakeRequest` is the narrow front-door path from a patient's raw ask to a
single appointment — not a general "appointment" aggregate, and not two
separate things. Earlier revisions of this model kept a request and its
appointment as two separate aggregates (with two separate identities); once
that relationship was confirmed 1:1 permanently, the split stopped earning
its keep. A request's whole lifecycle — submitted through
appointed/closed/withdrawn/rejected — is one sum type under one identity,
`IntakeRequestId`, carried on `SubmittedIntakeRequest` and never reassigned
to anything else.

The six constructors trace out the paths a request can actually take:

- `Submitted -> Accepted` — a triager (doctor or qualified assistant)
  assigns a service and a priority.
- `Accepted -> Appointed` — the request is matched to a slot (see "Waitlist
  matching" below).
- `Appointed -> Closed` — the appointment concludes, tagged with *why*
  (`CloseReason`).
- `Submitted -> Rejected` — the request never gets triaged at all.
- `Submitted -> Withdrawn` or `Accepted -> Withdrawn` — the patient or
  doctor pulls the request before an appointment exists.

`Rejected`, `Withdrawn`, and `Closed` are all permanently terminal — nothing
transitions back out of any of them. A displaced or redisplaced patient
(bumped from a slot, or reassignment fails) always becomes a brand new
`IntakeRequest` with a new `IntakeRequestId`, never a reopening of a
terminal one.

### Each stage embeds the one before it

```haskell
data SubmittedIntakeRequest = SubmittedIntakeRequest
  { id                :: IntakeRequestId
  , patientId         :: PatientId
  , narrative         :: Text
  , doctorRequirement :: DoctorRequirement
  , createdAt         :: UTCTime
  }

data TriagedIntakeRequest = TriagedIntakeRequest
  { submitted           :: SubmittedIntakeRequest
  , healthcareServiceId :: HealthcareServiceId
  , priority             :: IntakeRequestPriority
  , triagedAt            :: UTCTime
  }

data AppointedIntakeRequest = AppointedIntakeRequest
  { triaged  :: TriagedIntakeRequest
  , doctorId :: DoctorId
  , start    :: UTCTime
  , duration :: Duration
  }
```

`SubmittedIntakeRequest` *is* the base record — there is no separate
"Details" type underneath it holding the same fields a second way.
`TriagedIntakeRequest` embeds the submitted request whole (`submitted`) and
adds only what triage itself contributes; `AppointedIntakeRequest` embeds
the triaged request whole (`triaged`) and adds only what matching itself
contributes (the doctor/time/duration the request got matched to). Each
layer adds only its own stage's facts — no type duplicates a fact another
type already owns, so "what was originally submitted" is never lost and
"has this been triaged / appointed" is a type-level fact, not a nullable
field. See `docs/modeling-principles.md`'s "Embed previous state, don't
duplicate fields" for the general version of this rule.

### Withdrawal has two cases, not three

```haskell
data WithdrawnIntakeRequest
  = WithdrawnFromSubmitted SubmittedIntakeRequest UTCTime (Maybe Text)
  | WithdrawnFromAccepted  TriagedIntakeRequest   UTCTime (Maybe Text)
```

Withdrawal only exists as a concept *before* an appointment exists. There is
no `WithdrawnFromAppointed` — once a request is `Appointed`, ending it is
always `Closed (Cancelled ByPatient ...)` instead. A hypothetical
`WithdrawnFromAppointed` would assert the identical fact `Closed`/`Cancelled`
already does: same precondition type (`AppointedIntakeRequest`), same
timestamp, "who ended it" already answered by `AppointmentParty`. True
redundancy, not two real cases.

### CloseReason is a separate axis from lifecycle stage

```haskell
data AppointmentParty
  = ByDoctor
  | ByPatient

data CloseReason
  = Completed
  | Cancelled AppointmentParty UTCTime (Maybe Text)
  | NoShow    AppointmentParty
```

`CloseReason` stays nested under `Closed` (`Closed AppointedIntakeRequest
CloseReason`), deliberately not flattened into top-level `IntakeRequest`
constructors of their own (`Completed`/`Cancelled`/`NoShow` as siblings of
`Appointed`). "Why a closed appointment ended" is orthogonal to "what
lifecycle stage this request is in," and flattening would mix those two
axes at one level.

`Cancelled`'s `UTCTime` records *when the cancellation occurred* — distinct
from the appointment's own scheduled time (embedded via
`AppointedIntakeRequest`) and not validated against it structurally;
whether something is `Cancelled` versus `NoShow` is entirely the booking
manager's judgment call, recorded as given. The trailing `Maybe Text` on
`Cancelled` is an optional free-text note, the same shape `Rejected` and
`Withdrawn` each carry for their own reason/note. `AppointmentParty`
(`ByDoctor`/`ByPatient`) exists to avoid colliding with the real
`Doctor`/`Patient` entity types elsewhere in the module.

## Priority

```haskell
data IntakeRequestPriority
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

`RoutineDue`'s `RoutineWithin` case is the only sealed constructor in the
entire module — export it and any caller could build a `RoutineWithin` with
`from > to`, a range that can never match anything. `mkRoutineWithin :: UTCTime
-> UTCTime -> Maybe RoutineDue` is the only way to construct one, and
enforces `from <= to`. Nothing else in `Domain.hs` currently needs sealing
(see `CLAUDE.md`'s "Sealing in Domain.hs" section for the full statement of
that rule). Because the constructor is hidden, a caller that already holds a
valid `RoutineDue` and needs to read its bounds back out — Persistence,
encoding one for storage — can't pattern-match on it directly; that's what
`routineWithinBounds :: RoutineDue -> Maybe (UTCTime, UTCTime)` is for, a
read-only accessor over an already-valid value. It cannot construct or
fabricate a `RoutineWithin`, so it doesn't reopen `mkRoutineWithin`'s
invariant.

## Slots

```haskell
data AvailableSlot = AvailableSlot
  { id                  :: SlotId
  , doctorId            :: DoctorId
  , healthcareServiceId :: HealthcareServiceId
  , start               :: UTCTime
  , duration            :: Duration
  }
```

`AvailableSlot` is the only slot type. There is no `Slot` sum type, no
`Booked` state, and no `BookedSlot` carrying a reference back to whatever it
got booked into. A slot has no existence independent of matching: it is
available until claimed, and at the moment it's claimed its facts
(`doctorId`, `start`, `duration`) are hard-copied directly into the
resulting `AppointedIntakeRequest` — the original slot is then fully
absorbed and ceases to be referenced. There is no post-booking slot state to
model, nothing to free, and no sealed "proof" wrapper marking that a slot
passed a match: `matches` (below) is business logic for trusted callers, not
a guard against fabrication — an external caller could already trivially
construct a `TriagedIntakeRequest` that passes `matches` against any slot,
so a sealed wrapper would add no real protection.

One consequence worth calling out: if a cancelled or reassigned request's
original time should become bookable again, that is an explicit new
`AvailableSlot` created by the caller — not an automatic transition
triggered by the cancellation or reassignment itself.

## Waitlist matching

```haskell
matches :: AvailableSlot -> TriagedIntakeRequest -> Bool
matches slot TriagedIntakeRequest { healthcareServiceId, priority, submitted } =
     slot.healthcareServiceId == healthcareServiceId
  && matchesDoctorRequirement slot submitted.doctorRequirement
  && matchesTime priority slot.start
```

A slot and a triaged request `matches` when the slot's service matches the
request's, the slot's doctor satisfies the request's `DoctorRequirement`
(`AnyDoctor` or a specific one), and the slot's start time satisfies the
request's priority-carried deadline (or window, for `Routine`).

```haskell
matchIntakeRequestToSlot
  :: AvailableSlot -> TriagedIntakeRequest -> Maybe AppointedIntakeRequest

checkIntakeWaitlist
  :: AvailableSlot -> [TriagedIntakeRequest] -> Maybe AppointedIntakeRequest
checkIntakeWaitlist slot =
  listToMaybe . mapMaybe (matchIntakeRequestToSlot slot) . sortOn priority
```

`matchIntakeRequestToSlot` is the direct one-to-one check: does this
specific triaged request fit this specific slot, and if so, produce the
`AppointedIntakeRequest` that results. `checkIntakeWaitlist` is the
automatic path a newly available slot takes: sort the waitlist by priority
(using `IntakeRequestPriority`'s own `Ord` instance), try to satisfy each in
order via `matchIntakeRequestToSlot`, take the first success. The pipeline
shape *is* the spec — no separate prose description should be needed to
understand what this does.

```haskell
reassignIntakeRequestSlot
  :: AppointedIntakeRequest -> AvailableSlot -> Maybe AppointedIntakeRequest
```

`reassignIntakeRequestSlot` moves an already-appointed request to a
*different* slot, re-checking the same structural eligibility (`matches`)
against the proposed slot. On success, the same `TriagedIntakeRequest` is
carried through unchanged — only `doctorId`/`start`/`duration` are
replaced. On failure, that is deliberately not this function's problem to
retry: the correct caller-side response is to close the current appointment
(`Cancelled`-shaped) and then submit and accept a brand new
`IntakeRequest` — two existing operations called in sequence, not a new
composed one.

## What's deliberately not modeled yet

- Priority *escalation* over time (e.g. a request ages up in priority as its
  deadline approaches). This sounds plausible but has not been validated
  with the doctor — see `docs/decisions.md` open questions. Do not add it
  speculatively.
