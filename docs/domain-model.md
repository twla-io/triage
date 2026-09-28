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
  | Stale     TriagedIntakeRequest UTCTime
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

The seven constructors trace out the paths a request can actually take:

- `Submitted -> Accepted` — a triager (doctor or qualified assistant)
  assigns a service and a priority.
- `Accepted -> Appointed` — the request is matched to a slot (see "Waitlist
  matching" below).
- `Appointed -> Closed` — the appointment concludes, tagged with *why*
  (`CloseReason`).
- `Submitted -> Rejected` — the request never gets triaged at all.
- `Submitted -> Withdrawn` or `Accepted -> Withdrawn` — the patient or
  doctor pulls the request before an appointment exists.
- `Accepted -> Stale` — staff manually close out an accepted request that
  never got matched to a slot and never got withdrawn (see "`Stale` is
  reachable only from `Accepted`" below).

`Rejected`, `Withdrawn`, `Stale`, and `Closed` are all permanently terminal —
nothing transitions back out of any of them, and no transition leads back
to an earlier stage. A patient who needs to be seen again after one of those
terminal outcomes gets a brand new `IntakeRequest` (new `IntakeRequestId`) —
including a patient displaced or rescheduled from an appointment (see
"Displacement and rescheduling: close, then a new request" below).

### Each stage embeds the one before it

```haskell
data SubmittedIntakeRequest = SubmittedIntakeRequest
  { id                :: IntakeRequestId
  , patientId         :: PatientId
  , narrative         :: Text
  , createdAt         :: UTCTime
  }

data TriagedIntakeRequest = TriagedIntakeRequest
  { submitted           :: SubmittedIntakeRequest
  , healthcareServiceId :: HealthcareServiceId
  , priority             :: IntakeRequestPriority
  , doctorRequirement    :: DoctorRequirement
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

### `Stale` is reachable only from `Accepted`

`Stale TriagedIntakeRequest UTCTime` (see the `IntakeRequest` definition
above). An `Accepted` request that never gets matched to a slot and never
gets withdrawn by the patient could otherwise sit unresolved forever.
`Stale` exists so staff can close that out directly, the same way
`Rejected` and `Closed` already end a request's lifecycle.

It's reachable only from `Accepted` — not from `Submitted` — because a due
date doesn't exist before triage, so "stale" is structurally meaningless
there. Like every other terminal case, it's permanently terminal: nothing
transitions back out of it.

It is always an explicit, staff-initiated action, never an automatic or
timer-driven transition — no code anywhere should trigger this on its own.
This is the same trust-in-human-judgment pattern as `AppointmentParty`'s
`Cancelled`-versus-`NoShow` distinction: the system records a human's
judgment call rather than inferring one itself.

There is no dedicated `markIntakeRequestStale` function in `Domain.hs` —
direct construction only (`Stale triaged staleAt`), the same precedent
`Rejected` set. Its only precondition, "this was `Accepted`," belongs in
`Service.hs`'s fetch-then-check wrapper (also named
`markIntakeRequestStale`), not here.

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
< RoutineAnytime`, tighter/earlier constraints first. Two `RoutineWithin`
windows compare by upper bound first; on equal upper bounds the narrower
window (later lower bound) ranks first, so `compare` returns `EQ` only for
equal windows.

The only unresolved case is two requests with a genuinely identical priority
value (same tier, same due value) — `sortOn` is stable, so that's settled by
input-list order, not by a designed rule. Not currently a problem worth
solving.

`RoutineDue`'s `RoutineWithin` case is sealed — export it and any caller
could build a `RoutineWithin` with `from > to`, a range that can never
match anything. `mkRoutineWithin :: UTCTime -> UTCTime -> Maybe RoutineDue`
is the only way to construct one, and enforces `from <= to`. The only other
sealed type is `DoctorCalendar` (see "Doctor calendar" below); see
`CLAUDE.md`'s "Sealing in Domain.hs" section for the full statement of that
rule. Because the constructor is hidden, a caller that already holds a
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

One consequence worth calling out: if a cancelled or rescheduled
appointment's original time should become bookable again, that is an
explicit new `AvailableSlot` created by the caller — not an automatic
transition triggered by the cancellation itself.

## Doctor calendar

```haskell
data CalendarEntry
  = Slot        AvailableSlot
  | Appointment AppointedIntakeRequest

mkDoctorCalendar :: [CalendarEntry] -> Maybe DoctorCalendar
addAvailableSlot
  :: DoctorCalendar -> SlotId -> DoctorId -> HealthcareService -> UTCTime
  -> Maybe (AvailableSlot, DoctorCalendar)
```

A doctor's time is occupied by available slots and appointed requests. No
two entries of the same doctor may overlap. Entries occupy half-open
intervals `[start, end)`, so an entry starting exactly where another ends
does not overlap it.

`DoctorCalendar` covers the whole practice and is sealed: the only ways to
get one are `mkDoctorCalendar` (from existing entries) and
`addAvailableSlot`, and both return `Nothing` rather than a calendar with
an overlap. A slot is the only thing ever *added* to a calendar, and
`addAvailableSlot` is how a new slot is created: it takes the service, so
the slot's duration is always the service's.
Appointments arrive by matching, which takes over the slot's exact
interval, so matching cannot create an overlap and
`matchIntakeRequestToSlot` takes no calendar.

A `DoctorCalendar` value only proves that *its own* entries don't overlap,
not that it matches what is stored right now. Stored data is protected by
the database (`doctor_calendar`'s `EXCLUDE` constraint); `Domain.hs` states
the rule and checks it for values it holds. See `docs/decisions.md`'s
"Doctor calendar" entry.

## Waitlist matching

```haskell
matches :: AvailableSlot -> TriagedIntakeRequest -> Bool
matches slot TriagedIntakeRequest { healthcareServiceId, priority, doctorRequirement } =
     slot.healthcareServiceId == healthcareServiceId
  && matchesDoctorRequirement slot doctorRequirement
  && matchesTime priority slot.start
```

A slot and a triaged request `matches` when the slot's service matches the
request's, the slot's doctor satisfies the `DoctorRequirement` triage decided
(`AnyDoctor` or a specific one; a patient's own preference lives in the
narrative), and the slot's start time satisfies the
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

### Displacement and rescheduling: close, then a new request

`Domain.hs` has no reassignment or reclaim function. Moving an appointed
patient to a different time, or displacing them from their slot, ends the
appointment and starts a new intake:

- `Closed appointed (Cancelled party cancelledAt note)` — the cancelled
  appointment stays on record, with who cancelled it and when.
- A new `SubmittedIntakeRequest`, accepted by the doctor, then matched like
  any other waitlisted request.

No link between the two requests is modeled: an `IntakeRequest` covers one
intake, not a patient's whole care history, and `patientId` already groups a
patient's requests. Context goes into the new request's narrative; whether
the patient should rank higher is the doctor's triage decision when
accepting it, taking the previous priority into account. This keeps every
lifecycle path one-way (see `docs/decisions.md`, "Reclaim removed;
displacing a patient is Closed + a new IntakeRequest").

Whether the vacated original time becomes bookable again is not automatic —
that's a separate, explicit `createAvailableSlot` call by the caller.

## What's deliberately not modeled yet

- Priority *escalation* over time (e.g. a request ages up in priority as its
  deadline approaches). This sounds plausible but has not been validated
  with the doctor — see `docs/decisions.md` open questions. Do not add it
  speculatively.
