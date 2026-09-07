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
nothing transitions back out of any of them. A brand new `IntakeRequest`
(new `IntakeRequestId`) is created only when a patient submits again after
one of those terminal outcomes — not as a mechanism for displacement from a
slot, which reuses the same `IntakeRequestId` instead (see "Reassignment and
displacement live in `Service.hs`, not here" below).

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
    -- ^ Also how a request is reclaimed back to Accepted — appointed.triaged
    -- is already that value; no dedicated reclaim function needed.
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

### Reassignment and displacement live in `Service.hs`, not here

`Domain.hs` has no reassignment function — there is no
`reassignIntakeRequestSlot` or equivalent. Moving an already-appointed
request to a different slot, and displacing a request from its slot
altogether, are both `Service.hs`-level compositions, one layer up from
this module, consistent with `CLAUDE.md`'s "Layering" section (`Domain.hs`
stays pure; `Service.hs` orchestrates it with `Persistence.hs`):

```haskell
reclaimAppointedIntakeRequest
  :: ConnectionPool -> IntakeRequestId -> IO (Either ServiceError TriagedIntakeRequest)
```

This works because `AppointedIntakeRequest` already embeds the
`TriagedIntakeRequest` it came from, unchanged, as its `triaged` field (see
"Each stage embeds the one before it" above) — reclaiming an `Appointed`
request back to `Accepted` is free: plain field access
(`appointed.triaged`), no re-triage, no new information produced, the same
`IntakeRequestId`/`triagedAt`/priority carried through exactly.

- **Reassignment** = `reclaimAppointedIntakeRequest`, then
  `matchAcceptedIntakeRequestToSlot` against a different slot, back-to-back.
- **Displacement** = `reclaimAppointedIntakeRequest` alone — the request
  falls back into the ordinary waitlist (`Accepted`), no new
  `IntakeRequest`, no lost history.

Whether the vacated original time becomes bookable again is still not
automatic either way — that's a separate, explicit `createAvailableSlot`
call by the caller.

A dedicated `reassignIntakeRequestSlot :: AppointedIntakeRequest ->
AvailableSlot -> Maybe AppointedIntakeRequest` used to live in this module.
It re-checked the same structural eligibility (`matches`) against the
proposed slot and, on success, carried the same `TriagedIntakeRequest`
through unchanged. It was removed, not patched, after its
`Persistence.hs` counterpart turned out to have a real bug (it never freed
the slot it replaced) — see `docs/decisions.md`'s "Reassignment and
displacement both compose from reclaimAppointedIntakeRequest, not a
dedicated transition" entry for the full history.

## What's deliberately not modeled yet

- Priority *escalation* over time (e.g. a request ages up in priority as its
  deadline approaches). This sounds plausible but has not been validated
  with the doctor — see `docs/decisions.md` open questions. Do not add it
  speculatively.
