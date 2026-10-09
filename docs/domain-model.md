# Domain model

Read this before working in `src/Domain.hs`. This is the narrative the types
are meant to tell — if code and this doc disagree, that's a bug in one of
them.

## Intake requests

```haskell
data IntakeRequest
  = Submitted SubmittedIntakeRequest
  | Rejected  RejectedIntakeRequest
  | Accepted  TriagedIntakeRequest
  | Appointed AppointedIntakeRequest
  | Withdrawn WithdrawnIntakeRequest
  | Stale     StaleIntakeRequest
  | Closed    ClosedIntakeRequest
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

data RejectedIntakeRequest = RejectedIntakeRequest
  { submitted       :: SubmittedIntakeRequest
  , rejectedAt      :: UTCTime
  , rejectionReason :: Text
  }

data StaleIntakeRequest = StaleIntakeRequest
  { triaged :: TriagedIntakeRequest
  , staleAt :: UTCTime
  }

data ClosedIntakeRequest = ClosedIntakeRequest
  { appointed   :: AppointedIntakeRequest
  , closeReason :: CloseReason
  }
```

`SubmittedIntakeRequest` *is* the base record — there is no separate
"Details" type underneath it holding the same fields a second way.
`TriagedIntakeRequest` embeds the submitted request whole (`submitted`) and
adds only what triage itself contributes; `AppointedIntakeRequest` embeds
the triaged request whole (`triaged`) and adds only what matching itself
contributes (the doctor/time/duration the request got matched to). The
terminal stages follow the same pattern: each embeds the stage it ended and
adds its own facts. Each layer adds only its own stage's facts — no type
duplicates a fact another type already owns, so "what was originally
submitted" is never lost and "has this been triaged / appointed" is a
type-level fact, not a nullable field. See `docs/modeling-principles.md`'s
"Embed previous state, don't duplicate fields" for the general version of
this rule.

Every stored value has a name in these types — a record field, or the
constructor of a single-field type — never an unnamed positional
argument. The names are part of the specification: downstream layers take
their column and field names from them (see `docs/decisions.md`, "Every
stored value is named in Domain.hs").

### Withdrawal has two cases, not three

```haskell
data WithdrawnIntakeRequest = WithdrawnIntakeRequest
  { withdrawnFrom  :: WithdrawnFrom
  , withdrawnAt    :: UTCTime
  , withdrawalNote :: Maybe Text
  }

data WithdrawnFrom
  = FromSubmitted SubmittedIntakeRequest
  | FromAccepted  TriagedIntakeRequest
```

A withdrawn request is what it was withdrawn from, plus when, plus an
optional note — the withdrawal's own facts are stated once, whichever stage
it ended.

Withdrawal only exists as a concept *before* an appointment exists. There is
no `FromAppointed` — once a request is `Appointed`, ending it is always
`Closed` with a `Cancellation` instead. A hypothetical `FromAppointed` would
assert the identical fact a cancellation already does: same precondition
type (`AppointedIntakeRequest`), same timestamp, "who ended it" already
answered by `cancelledBy`. True redundancy, not two real cases.

### CloseReason is a separate axis from lifecycle stage

```haskell
data AppointmentParty
  = DoctorParty
  | PatientParty

data Cancellation = Cancellation
  { cancelledBy      :: AppointmentParty
  , cancelledAt      :: UTCTime
  , cancellationNote :: Maybe Text
  }

newtype Absence = Absence
  { absentParty :: AppointmentParty
  }

data CloseReason
  = Completed
  | Cancelled Cancellation
  | NoShow    Absence
```

`CloseReason` stays nested under `Closed` (`ClosedIntakeRequest`'s
`closeReason`), deliberately not flattened into top-level `IntakeRequest`
constructors of their own (`Completed`/`Cancelled`/`NoShow` as siblings of
`Appointed`). "Why a closed appointment ended" is orthogonal to "what
lifecycle stage this request is in," and flattening would mix those two
axes at one level.

`cancelledAt` records *when the cancellation occurred* — distinct from the
appointment's own scheduled time (embedded via `AppointedIntakeRequest`)
and not validated against it structurally; whether something is
`Cancelled` versus `NoShow` is entirely the booking manager's judgment
call, recorded as given. `cancellationNote` is an optional free-text note.
A no-show needs no time of its own: it happens at the appointment's
`start`.

`cancelledBy` (who cancelled) and `absentParty` (who didn't turn up) are
kept as separate facts. What `absentParty` means, and whether a no-show
needs a note, is an open question for the domain expert (see
`docs/decisions.md`'s open questions). `AppointmentParty`
(`DoctorParty`/`PatientParty`) avoids colliding with the `Doctor`/`Patient`
entity constructors elsewhere in the module.

### `Stale` is reachable only from `Accepted`

`Stale StaleIntakeRequest` (see the stage records above). An `Accepted`
request that never gets matched to a slot and never
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

There is no dedicated stale function in `Domain.hs` — direct construction
only (`Stale StaleIntakeRequest { triaged, staleAt }`), the same precedent
`Rejected` set. Its only precondition, "this was `Accepted`," belongs in
`Service.hs`'s fetch-then-check wrapper, `markAcceptedIntakeRequestStale`,
whose name states the precondition it verifies — not here.

## Priority

```haskell
newtype MustBeSeenBy = MustBeSeenBy UTCTime

data IntakeRequestPriority
  = Emergency MustBeSeenBy
  | Urgent    MustBeSeenBy
  | Routine   RoutineDue

data RoutineDue
  = RoutineAnytime
  | RoutineNotBefore UTCTime
  | RoutineNotAfter  UTCTime
  | RoutineWithin    RoutineWindow

data RoutineWindow = RoutineWindow UTCTime UTCTime   -- sealed

routineNotBefore, routineNotAfter :: RoutineWindow -> UTCTime
```

Emergency and Urgent carry a deadline — the patient must be seen by then —
and it is the same fact in both tiers, so both carry the same type.
Routine carries a window the appointment may start in, a different fact.
A single-field constructor names its value: `RoutineNotBefore t`'s `t` is
the routine's not-before bound, which `RoutineWindow` calls by the same
name.

Ordering is fully derived from a hand-written `Ord` instance, not a
tiebreaker chain of separate fields — there's no `requestedAt`/`entryId` in
this type. Tier order (`Emergency < Urgent < Routine`) is structural in the
instance itself: any `Emergency` beats any non-`Emergency`, any `Urgent`
beats any `Routine`. Within a tier, `compare` falls through to the deadline:
`MustBeSeenBy` derives `Ord` on its `UTCTime`; `RoutineDue` has its own
instance ranking `RoutineWithin < RoutineNotAfter < RoutineNotBefore <
RoutineAnytime`, tighter/earlier constraints first. Two `RoutineWithin`
windows compare by `routineNotAfter` first; on equal upper bounds the
narrower window (later `routineNotBefore`) ranks first, so `compare`
returns `EQ` only for equal windows.

Two requests with an identical priority value (same tier, same due value —
common: every `RoutineAnytime` ranks equal) are ordered by `sortByPriority`:
the earlier triaged first, then the earlier submitted. Only after all three
keys tie does input-list order decide.

`RoutineWindow` is sealed — export its constructor and any caller could
build a window with `routineNotBefore > routineNotAfter`, a range that can
never match anything. `mkRoutineWindow :: UTCTime -> UTCTime -> Maybe
RoutineWindow` is the only way to construct one, and enforces
`routineNotBefore <= routineNotAfter`. The other sealed types are
`DoctorCalendar` (see "Doctor calendar" below) and `Name` (a doctor's,
patient's or service's name: `mkName` refuses empty or whitespace-only
text, `nameText` reads it); see `CLAUDE.md`'s "Sealing
in Domain.hs" section for the full statement of that rule. It has no record
fields — record-update syntax would bypass `mkRoutineWindow` — so its two
values are read through the named, read-only accessors `routineNotBefore`
and `routineNotAfter`, which cannot construct or change a window. Every
layer names the bounds after them.

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
data DoctorCalendarEntry
  = Slot        AvailableSlot
  | Appointment AppointedIntakeRequest

mkDoctorCalendar :: [DoctorCalendarEntry] -> Maybe DoctorCalendar
doctorCalendarEntries :: DoctorCalendar -> [DoctorCalendarEntry]
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
The calendar is read through `doctorCalendarEntries`, as `RoutineWindow` is
read through its accessors: sealing limits how a calendar is built, not how
it is read. It returns the entries in order of start.

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

sortByPriority :: [TriagedIntakeRequest] -> [TriagedIntakeRequest]
sortByPriority = sortOn (\r -> (r.priority, r.triagedAt, r.submitted.createdAt))

matchByPriority
  :: AvailableSlot -> [TriagedIntakeRequest] -> Maybe AppointedIntakeRequest
matchByPriority slot =
  listToMaybe . mapMaybe (matchIntakeRequestToSlot slot) . sortByPriority
```

`matchIntakeRequestToSlot` is the direct one-to-one check: does this
specific triaged request fit this specific slot, and if so, produce the
`AppointedIntakeRequest` that results. `matchByPriority` is the
automatic path a newly available slot takes: sort the requests with
`sortByPriority` (`IntakeRequestPriority`'s own `Ord` instance, then the
triage and submission times), try to satisfy each in
order via `matchIntakeRequestToSlot`, take the first success. The pipeline
shape *is* the spec — no separate prose description should be needed to
understand what this does.

### Displacement and rescheduling: close, then a new request

`Domain.hs` has no reassignment or reclaim function. Moving an appointed
patient to a different time, or displacing them from their slot, ends the
appointment and starts a new intake:

- `Closed` with `Cancelled Cancellation { cancelledBy, cancelledAt,
  cancellationNote }` — the cancelled appointment stays on record, with who
  cancelled it and when.
- A new `SubmittedIntakeRequest`, accepted by the doctor, then matched like
  any other waitlisted request.

No link between the two requests is modeled: an `IntakeRequest` covers one
intake, not a patient's whole care history, and `patientId` already groups a
patient's requests. Context goes into the new request's narrative; whether
the patient should rank higher is the doctor's triage decision when
accepting it, taking the previous priority into account. This keeps every
lifecycle path one-way (see `docs/decisions.md`, "Every lifecycle path is
one-way; displacing a patient is Closed plus a new request").

Whether the vacated original time becomes bookable again is not automatic —
that's a separate, explicit `createAvailableSlot` call by the caller.

## What's deliberately not modeled yet

- Priority *escalation* over time (e.g. a request ages up in priority as its
  deadline approaches). This sounds plausible but has not been validated
  with the doctor — see `docs/decisions.md` open questions. Do not add it
  speculatively.
