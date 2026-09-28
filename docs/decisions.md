# Decisions

Dated, short. Log what was decided, what was rejected, and why — so the next
session doesn't re-litigate settled questions or re-derive answers that
already cost real thinking.

## Domain.hs as AI-agent-facing specification (foundational)

**Decided:** `src/Domain.hs` is not "an implementation of the domain model" —
it's the specification of it. Sealed types + smart constructors exist to make
domain rules machine-legible, not just to protect invariants at runtime.
Claude Code reads this file and generates DB schema, Persistence, Service,
API, and UI/UX layers from it via dedicated codegen skills
(`triage-db-codegen`, `triage-api-codegen`, `triage-ui-codegen`).

**Consequence:** sealing is itself part of the spec. Where a type's
constructor is hidden, that tells the generating agent an invariant exists
downstream that needs enforcing. Where it's open, that tells the agent there
isn't one. Sealing something without an identified invariant, or leaving
something open that does have one, doesn't just weaken defensive coding — it
misinforms every layer generated from it.

## Persistence schema: discriminator column over side-tables (2026-07-11)

**Note (2026-09-27):** seven states since `Stale` was added (2026-07-18); the rest of this entry is unchanged history.

**Decided:** Sealed sum types persist as a single table with a discriminator
column, not one side-table per state. This session extended that principle
further: `IntakeRequest`'s six lifecycle states (`submitted`/`rejected`/
`accepted`/`appointed`/`withdrawn`/`closed`) all live in one `intake_requests`
table with one `state` column, replacing the prior two-table split
(`healthcare_requests` + `appointments`).

**Why:** State transitions are frequent and the state set is small and
closed — the same reasoning that originally justified one table per sum type
is what justified merging `Appointment` into `IntakeRequest` in the first
place, not a reversal of it. Side-tables (or a second aggregate's own table)
would mean cross-table moves on every transition for no real query benefit at
this scale.

**Note:** `Slot` was already resolved as having nothing to discriminate (see
`deleted-on-match`). With this session's redesign, `Appointment` no longer
exists as a separate table or type either — `state` alone carries all six
cases.

## Event sourcing: explored, rejected (2026-06)

**Considered for:** the Slot / AppointmentRequest aggregate.

**Rejected because:** sealed types already provide most of the benefit event
sourcing would add (valid-state-only representation, explicit transitions).
The operational cost — event store, replay, projection maintenance — isn't
justified at 2-3 doctor scale. Revisit only if scale assumptions change.

**Kept from the exploration:** `UNIQUE (stream_id, seq)` in Postgres was
identified as the right concurrency-control primitive for the gap the type
system can't close alone (two concurrent writers racing on the same
aggregate). Worth reusing even without full event sourcing.

## Generic-derived FromJSON on sealed types: rejected as a pattern (2026-06)

**Found:** Generic-derived `FromJSON` on a sealed Domain type is a live
validation bypass — Generic derivation runs inside the module where
constructors are visible, so it sidesteps the export-based sealing entirely.

**Decided:** Never derive `FromJSON` generically on sealed Domain types.
Transport DTO twin types may derive Generic freely; the `toDomain` boundary
function is where smart-constructor validation actually happens.

## Rescheduling: reassignIntakeRequestSlot, not a CloseReason variant (2026-07-11)

**Superseded (2026-07-13):** by "Reassignment and displacement both compose
from reclaimAppointedIntakeRequest, not a dedicated transition" below —
`reassignIntakeRequestSlot` no longer exists; a real bug in its
Persistence-layer counterpart led to a simpler design that removes the
dedicated transition entirely rather than fixing it in place. Kept here
for history. The rejection below (a `CloseReason`-variant representation)
still holds independently of which mechanism replaced the
dedicated-transition approach — the new design doesn't reintroduce it
either.

**Decided:** Moving an appointed request to a different slot is modeled as
`reassignIntakeRequestSlot :: AppointedIntakeRequest -> AvailableSlot ->
Maybe AppointedIntakeRequest` — it re-checks the same structural eligibility
(`matches`) against the proposed slot and, on success, produces a new
`AppointedIntakeRequest` with the new slot's doctor/time/duration hard-copied
in. The old slot's facts are discarded, not freed or returned — there is no
slot-level state to transition (see `deleted-on-match`). The request stays
`Appointed` throughout; its `IntakeRequestId` and embedded
`TriagedIntakeRequest` are unchanged.

**Rejected:** the original representation, `CloseReason`'s `Rescheduled
AppointmentParty` constructor — closing the request to reschedule conflated
"this request is done" with "this request moved," losing the appointed
request's identity across the move.

**Why:** a request being rescheduled is still the same request, still
`Appointed` — closing it to represent a slot change would mean an
`AppointedIntakeRequest`'s identity doesn't survive an operation that
shouldn't affect its identity at all.

## intake_requests lifecycle: six states, no delete-on-consumption, waitlist is a plain filter (2026-07-11)

**Note (2026-09-27):** seven states since `Stale` was added (2026-07-18); the rest of this entry is unchanged history.

**Decided:** `intake_requests` state is six-valued (`submitted`/`rejected`/
`accepted`/`appointed`/`withdrawn`/`closed`), confirmed against `Domain.hs`'s
`IntakeRequest` sum type. Rows are never deleted on consumption — matching
updates `state` from `accepted` to `appointed` in place (see the rewritten
"Matching is atomic delete-and-update" entry below); it never deletes or
re-inserts the `intake_requests` row.

**Rejected:** the old `appointment_requests` delete-on-match behavior from an
earlier domain version — already rejected before this session and unaffected
by it.

**Consequence, and the actual simplification found this session:** with
`healthcare_requests` and `appointments` as two separate tables, "currently
waiting" was a derived anti-join — a triaged request with no corresponding
`appointments` row, via `LEFT JOIN ... WHERE a.id IS NULL`. Now that both are
one table, "the waitlist" is just `WHERE state = 'accepted'` — a plain
filter, no join at all (see `fetchIntakeWaitlist` in `Persistence.hs`).

## Doctor-originated requests reuse the existing flow unchanged

**Decided:** A doctor scheduling a follow-up (e.g. "come back in 3 months")
is modeled as an ordinary `SubmittedIntakeRequest` + `acceptIntakeRequest`
call — same flow as a patient-submitted request, with the doctor as both the
author of `narrative`/`doctorRequirement` and the triager, potentially in the
same transaction with no observable `Submitted`-only gap.

**Why:** `SubmittedIntakeRequest` and `acceptIntakeRequest` never required
patient self-authorship or an elapsed gap between submission and triage —
that was an implicit, unvalidated assumption, not something the types
enforce. No new mechanism is needed.

**Open, not yet decided:** whether doctor-authored vs. patient-authored
requests need to be distinguishable (for reporting, or because a
doctor-originated request arguably doesn't need the same triage scrutiny).
Left alone — no function currently needs this distinction, and CLAUDE.md's
standard is not to add it speculatively.

## Matching is atomic delete-and-update, not insert-and-delete (2026-07-11)

**Superseded:** the prior version of this entry described matching as an
atomic insert-and-delete — inserting a new `appointments` row and deleting
the matched `slots` row in one transaction. That `appointments` table no
longer exists.

**Decided:** `persistMatchedIntakeRequest` deletes the matched `slots` row
AND updates the `intake_requests` row's `state` from `'accepted'` to
`'appointed'` (hard-copying `appointed_doctor_id`/`start_time`/
`duration_minutes` in the same UPDATE), both within one transaction
(`atomic-multi-table-write`). No trigger; the atomicity is enforced by the
Persistence function's own `withTransaction` scope.

**Why the compound-rollback machinery is still needed despite the merge:**
folding `Appointment` into `IntakeRequest` removes the *insert*, but it does
not remove the *two-table write* — matching still touches `slots` (one
table) and `intake_requests` (a different table). The request-side guard's
mechanism changed — from an `INSERT ... WHERE NOT EXISTS` guarding
`appointments.healthcare_request_id`'s `UNIQUE` constraint (which no longer
exists) to `claimAcceptedIntakeRequest`'s `UPDATE ... WHERE state =
'accepted'`, guarding the discriminator column itself as the version check
(no separate `row_version` column needed — nothing in this model changes
state without it being a real transition worth naming). *[Superseded
2026-09-27: a row version was added — see "Row version for freshness" below.
Restored 2026-09-28: the version was removed once reclaim was — see "Row
version removed; the state guard also gives freshness" below.]* But if the slot
delete wins and the request-side UPDATE then loses its race, the slot delete
must still be rolled back — the same phantom-slot-loss risk the original
`atomic-multi-table-write` entry existed to prevent, unchanged by the merge.
`MatchAbort`/`withTransaction`'s blanket rollback-on-any-exception is what
closes that gap, exactly as before.

## Slot has no existence after being matched (2026-07-11)

**Decided:** `Slot`, `SlotDetails`, and `BookedSlot` do not exist as types.
`AvailableSlot` is the only slot representation. Once matched, a slot's
facts are copied into the resulting `AppointedIntakeRequest` and the
original ceases to be referenced. In the schema, a matched `slots` row is
deleted, not flagged (`deleted-on-match`).

**Why:** a slot is a pre-declaration mechanism for matching, with no domain
significance of its own afterward. Keeping a `Booked` slot state meant the
same facts existed in two places (the slot's own record and the appointment
it produced) with nothing forcing them to agree — a real bug was found this
way: a freed `AvailableSlot` returned alongside a `ClosedAppointment` that
still, internally, asserted the slot was booked.

**Rejected:** keeping `Slot`'s two-state model and referencing it by
`SlotId` from the appointed-request side. Rejected because that reference
would be either permanently dangling (rows deleted on match) or require
indefinite slot retention purely to keep an unused reference valid.

**Consequence:** if a cancelled/reassigned request's original time should
become bookable again, that's an explicit new `AvailableSlot` created by the
caller — not an automatic domain-level transition.

## AppointedIntakeRequest hard-copies doctor/time/duration, embeds TriagedIntakeRequest whole (2026-07-11)

**Decided:**

```haskell
data AppointedIntakeRequest = AppointedIntakeRequest
  { triaged  :: TriagedIntakeRequest
  , doctorId :: DoctorId
  , start    :: UTCTime
  , duration :: Duration
  }
```

Exported openly — no invariant to protect.

**Why:** once slots have no post-match existence, there's nothing left to
reference. The facts that matter are copied at match time — same principle
as embedding `TriagedIntakeRequest`. Where this used to be a standalone type
(`OpenAppointment`) alongside a separate request type, it's now one link in
the `SubmittedIntakeRequest -> TriagedIntakeRequest -> AppointedIntakeRequest`
embedding chain, each layer adding only the fields that stage itself
contributes — not a special case.

**Rejected:** an interim `BookedSlot` sealed wrapper, kept briefly as "proof
the slot passed `matches`." Removed once shown that any external caller can
already trivially construct a `TriagedIntakeRequest` that passes `matches`
against any slot — the wrapper added no real protection, same trust boundary
as ID freshness elsewhere.

## Closed is a case of IntakeRequest, not a separate ClosedAppointment type; no dedicated close function (2026-07-11)

**Superseded:** `ClosedAppointment` no longer exists as a type. The prior
entry described `data ClosedAppointment = ClosedAppointment OpenAppointment
CloseReason`, embedding `OpenAppointment` unchanged.

**Decided:** `Closed` is a constructor of `IntakeRequest` itself —
`Closed AppointedIntakeRequest CloseReason` — embedding the appointed
request whole, same as `ClosedAppointment` did. No `closeIntakeRequest`
function; callers construct `Closed appointed reason` directly.

**Why:** once `AppointedIntakeRequest` no longer asserts any live/mutable
state, embedding it whole is safe and free — "closing carries its full
history." The "no dedicated function, callers construct directly" principle
carried forward directly into this session's separate decision to drop
`rejectIntakeRequest` as a function too (see "Accept/reject asymmetry"
below) — the same reasoning applied a second time, not independently
rediscovered.

## CloseReason: Rescheduled removed, Cancelled carries a timestamp and optional note (2026-07-11)

**Decided:** `CloseReason = Completed | Cancelled AppointmentParty UTCTime
(Maybe Text) | NoShow AppointmentParty`. See "Rescheduling" entry above for
why `Rescheduled` was removed. The `UTCTime` on `Cancelled` records when the
cancellation occurred (distinct from the appointed request's own date) —
not validated against that date structurally; whether something is
`Cancelled` vs. `NoShow` is the booking manager's judgment call, recorded as
given.

**This session's addition:** `Cancelled` also carries a `Maybe Text` — an
optional administrative note on why the cancellation happened. Considered
and rejected: adding the same kind of note to `Completed`. `Completed`
doesn't need a "why" — it isn't ambiguous the way `Cancelled` is, so no
field was added there.

## RoutineWithin needs a read-only bounds accessor (2026-07)

**Decided:** `routineWithinBounds :: RoutineDue -> Maybe (UTCTime, UTCTime)`
added to `Domain.hs`, since `RoutineWithin`'s constructor is
deliberately unexported (protecting `mkRoutineWithin`'s `from <= to`) but
Persistence still needs to read its bounds back out to encode an
already-valid value. See `sealed-value-decomposition` in
`triage-db-codegen` — this is decomposition, not reconstruction, so
replay-through-a-gate-function doesn't apply; a plain read-only accessor
does.

## RoutineWithin ordering: narrower window breaks upper-bound ties (2026-09-26)

**Decided:** two `RoutineWithin` windows compare by upper bound (earlier
first), then, on equal upper bounds, by lower bound descending (narrower
window first). Previously windows sharing an upper bound compared `EQ`
while derived `Eq` called them unequal — an `Ord`/`Eq` inconsistency
noticed while preparing the MuniHac talk. Now `compare` is `EQ` exactly
when the windows are equal.

**Source:** chosen in that discussion (equal scheduling priority vs. equal
values), not independently confirmed by the domain expert. Ordering between
`RoutineDue` constructors and all other priority/matching rules are
unchanged.

## Concurrent-match races: affected-rows checks, not caught exceptions; a compound race needs rollback, not just reporting (2026-07-11)

**Decided:** any `Persistence.hs` write guarding a race that enforces a
domain invariant (not just data hygiene) detects a lost race via the
affected-row count on a conditional write (`DELETE ... WHERE id = ?`,
`UPDATE ... WHERE state = ?`) — never by letting Postgres throw a
`SqlError` and catching it. See `uniqueness-races-are-outcomes` in
`triage-db-codegen`'s `SKILL.md` for the general rule; `deleteSlot` was the
original instance, now paired with `claimAcceptedIntakeRequest`'s
`UPDATE intake_requests ... WHERE state = 'accepted'`.

**Found:** matching guards *two* independent races, not one — the
slot-delete race (two concurrent operations targeting the same `SlotId`)
and the request-side race (two different slots' waitlist scans both
picking up the same triaged request before either commits). The
request-side guard's mechanism changed with this session's merge:
previously `appointments.healthcare_request_id UNIQUE` plus an
`INSERT ... WHERE NOT EXISTS` (`insertIfUnclaimed`); now, with matching an
UPDATE rather than an INSERT, there is no UNIQUE constraint to guard —
`claimAcceptedIntakeRequest`'s `UPDATE ... WHERE state = 'accepted'`
affected-rows check IS the guard.

**Kept, unchanged by the merge:** `withTransaction` plus the internal,
unexported `MatchAbort` exception (`SlotGone`/`RequestGone`) for compound
rollback when the slot delete wins but the request-side claim then loses
its race — see the rewritten "Matching is atomic delete-and-update" entry
above for the full reasoning (why a caught-and-reported outcome alone isn't
enough, and why manual `begin`/`commit`/`rollback` was tried and rejected);
not duplicated here.

**Why this belongs here, not just in code comments:** a future session
touching `persistMatchedIntakeRequest` without this reasoning on hand could
plausibly "simplify" the `withTransaction`/`handle`/`throwIO` combination
back toward manual transaction control, not realizing that reintroduces the
exact bug this entry documents.

## IntakeRequest: Appointment folded into one sum type, one identity (2026-07-11)

**Superseded in part (2026-07-13):** displacement no longer creates a new `IntakeRequest` — it reclaims the same request back to `Accepted` (see "Reassignment and displacement both compose from reclaimAppointedIntakeRequest..." below). A new request is still needed after a terminal case.

**Restored (2026-09-28):** reclaim was removed; displacement creates a new `IntakeRequest` again, as this entry originally decided. See "Reclaim removed; displacing a patient is Closed + a new IntakeRequest" below.

**Decided:** `HealthcareRequest` was over-scoped — renamed to
`IntakeRequest` to name its actual, narrower scope (the intake artifact: the
front-door path from a patient's raw ask to a single appointment, not a
general ongoing healthcare need). Once the IntakeRequest-to-appointment
relationship is confirmed 1:1 permanently, `Appointment` no longer needs to
be a separate aggregate: six lifecycle states (`Submitted`/`Rejected`/
`Accepted`/`Appointed`/`Withdrawn`/`Closed`) live in one `IntakeRequest` sum
type, one `IntakeRequestId` throughout — no separate `AppointmentId`.

**Superseded direction, considered and reversed:** an earlier direction
(`TriageRecord`) preserved a request's identity across displacement, for
fairness — the idea being that if a patient is bumped from a slot, their
original wait time stays attached to whatever replaces it. This session's
redesign reverses that: any displaced or redisplaced patient becomes a
brand new `IntakeRequest` (new `IntakeRequestId`), never a transition back
out of a terminal case (see "All terminal states..." below).

**Why:** the reversal trades away a precise wait-time audit trail across
displacement for trusting doctor judgment at re-triage — a request's whole
history is simpler to reason about as one linear chain through six states
with no reopening, and Domain.hs's own sealing already relies on terminal
states staying terminal.

**Not yet confirmed with the domain expert** — flagged explicitly, added to
Open Questions below: if a patient is displaced and resubmitted, the system
keeps no record linking their old wait time to their new spot in line
unless the doctor writes it into the new request's narrative. Whether
that's acceptable, and whether doing so should be a stated habit rather
than ad hoc, has not been validated.

## SubmittedIntakeRequest is the base record, no separate Details type (2026-07-11)

**Decided:** `SubmittedIntakeRequest` is a flat record — `id`, `patientId`,
`narrative`, `doctorRequirement`, `createdAt` — with no separate "Details"
type underneath it.

**Rejected:** a draft that split this into an `IntakeRequestDetails` record
plus a zero-field newtype wrapper around it. Rejected as pure indirection —
no invariant, no fan-out (no sibling type needs the same fields with
different extras, unlike cases where a Details split earns its keep).

**Why:** `SubmittedIntakeRequest -> TriagedIntakeRequest ->
AppointedIntakeRequest` is a linear embedding chain; each layer adds only
the fields that stage itself contributes on top of the whole prior stage. A
base "Details" type would have added a layer with nothing of its own to
add.

## WithdrawnFromAppointed removed; ending an appointed request is always Closed (2026-07-11)

**Decided:** `WithdrawnIntakeRequest` has two cases —
`WithdrawnFromSubmitted` and `WithdrawnFromAccepted` — not three. There is
no `WithdrawnFromAppointed`.

**Why:** `WithdrawnFromAppointed` and `Closed (Cancelled ByPatient ...)`
would have asserted the identical fact — same precondition type
(`AppointedIntakeRequest`), same timestamp, "who ended it" already answered
by `AppointmentParty`. True redundancy, not two real cases. Withdrawal only
exists as a concept before an appointment exists; once a request is
`Appointed`, ending it is always `Closed`.

## Accept/reject asymmetry: acceptIntakeRequest is a function, rejection is direct construction (2026-07-11)

**Decided:** `acceptIntakeRequest` exists as a function because it does
real work — it assembles a `TriagedIntakeRequest` from positional arguments
(service, priority, timestamp) on top of a `SubmittedIntakeRequest`. There
is no `rejectIntakeRequest` function; rejection is direct construction
(`Rejected submitted rejectedAt reason`).

**Why:** a hypothetical `rejectIntakeRequest` would be an unconditional
alias with no transformation — the same shape as the already-rejected
`closeAppointment = ClosedAppointment` pattern (see "Closed is a case of
IntakeRequest..." above). A function that does nothing but wrap its
arguments in a constructor is a false signal of work being done.

**Rejected:** `TriageOutcome`, a shared wrapper type both
`acceptIntakeRequest` and a hypothetical `rejectIntakeRequest` were going to
return (`TriageAccepted`/`TriageRejected`). Dropped entirely — each call
site already commits to one outcome by which function it calls (or, for
rejection, which constructor it builds), so a sum type with a
structurally-unreachable other branch at each call site was a false signal,
not a real choice being represented.

## rejectedAt added to Rejected (2026-07-11)

**Decided:** `Rejected SubmittedIntakeRequest UTCTime Text` — the `UTCTime`
(`rejectedAt`) is new.

**Why:** every other terminal case already carries a timestamp —
`Withdrawn`'s two sub-cases each carry one, `Closed` via `Cancelled`
carries one. `Rejected` originally didn't, which was the inconsistency;
adding `rejectedAt` brings it in line with the others.

## All terminal states (Rejected/Withdrawn/Closed) confirmed permanently terminal, no reopening (2026-07-11)

**Superseded in part (2026-07-13):** displacement no longer creates a new `IntakeRequest` — it reclaims the same request back to `Accepted` (see "Reassignment and displacement both compose from reclaimAppointedIntakeRequest..." below). A new request is still needed after a terminal case.

**Restored (2026-09-28):** reclaim was removed; displacement creates a new `IntakeRequest` again, as this entry originally decided. See "Reclaim removed; displacing a patient is Closed + a new IntakeRequest" below.

**Decided:** `Rejected`, `Withdrawn`, and `Closed` are all permanently
terminal — no transitions out of any of them, confirmed against
`Domain.hs`. A displaced or redisplaced patient always becomes a brand new
`IntakeRequest` (new `IntakeRequestId`), never a transition back out of a
terminal case.

**Why:** direct consequence of the multiplicity reversal described in
"IntakeRequest: Appointment folded..." above — any transition back out of
a terminal case would silently resurrect the identity-preservation
mechanism (`TriageRecord`) that reversal rejected. Keeping terminal states
genuinely terminal is what makes the simpler six-state model hold together.

## Reassignment write gained a state guard, closing a latent race (2026-07-11)

**Found** while redesigning `reassignAppointedIntakeRequestSlot`, unrelated
to the IntakeRequest merge itself: the pre-existing
`persistReassignedAppointment` had no `WHERE state = 'open'` guard on its
UPDATE at all, unlike `persistClosedAppointmentIfOpen`'s equivalent guard —
a concurrent close racing a reassignment could silently overwrite
doctor/time/duration on an already-closed row.

**Decided:** `persistReassignedIntakeRequest` now guards
`WHERE state = 'appointed'`, the same affected-rows pattern as every other
conditional write in this module. `AlreadyClaimed` from this guard is
reported the same way as any other closed-row collision —
`RequestAlreadyClosed`, not a new outcome category.

**Why this belongs here, not just in code comments:** per the
"Concurrent-match races" entry's own closing note, a future session
touching this function without this reasoning on hand could plausibly
"simplify" the guard back out, not realizing it closes a real (if latent)
bug rather than adding unneeded ceremony.

## Overlap prevention: trigger-maintained doctor_calendar shadow table with a single cross-table EXCLUDE constraint (2026-07-11)

**Problem:** no two intervals may overlap for the same doctor, where an
interval is either an available `slots` row or an `intake_requests` row with
`state = 'appointed'`. Touching endpoints do not count as overlapping
(half-open intervals). This spans two tables, and a single-table `EXCLUDE`
constraint — Postgres's native tool for "no two rows with matching keys may
have overlapping ranges" — can only see one table at a time. Declaring it on
`slots` alone can't see appointed `intake_requests` rows, and vice versa.

**Rejected alternatives, and why:**

- **Naive check-then-insert** (query for overlapping rows across both
  tables, then insert if none found): races under `READ COMMITTED` — two
  concurrent inserts can both see no overlap and both commit, since neither
  sees the other's uncommitted row.
- **`pg_advisory_xact_lock`** keyed on doctor id: works, and is cheaper than
  the chosen design, but is convention-enforced, not schema-enforced — any
  write path (a future migration script, a backdoor `psql` session, code
  that forgets to take the lock) can silently violate the invariant. Rejected
  for that reason despite the lower cost, consistent with this codebase's
  standing preference (`discriminator-column-tables`'s own reasoning) for
  invariants the schema itself enforces over ones only convention enforces.
- **`SELECT ... FOR UPDATE`** on the candidate range: can't lock rows that
  don't exist yet — this doesn't help two inserts racing into empty space,
  which is the actual failure mode here.
- **`SERIALIZABLE` isolation:** closes the race, but shares the advisory
  lock's rejection reason — it's a transaction-level *convention* every
  writer must opt into, not something the schema enforces on writes that
  don't. Also higher overhead (retry-on-conflict machinery) for no schema-
  level guarantee gained over the chosen design.

**Decided:** a trigger-maintained shadow table, `doctor_calendar`, carrying
one `EXCLUDE USING gist (doctor_id WITH =, during WITH &&)` constraint that
sees both sources at once. `AFTER INSERT` on `slots` and `AFTER INSERT OR
UPDATE` on `intake_requests` triggers keep it in sync; `slot_id`'s `ON DELETE
CASCADE` handles slot removal without a second trigger. See
`migrations/0001_init.sql` for the full schema and trigger bodies.

**Why this closes the gap the others don't:** the constraint lives in the
schema itself, not in any particular code path's discipline — it fires
regardless of which trigger inserted the conflicting row, which process
issued the write, or whether the writer remembered any convention at all.

**The deliberate, contained exception to the no-caught-SqlError convention:**
`uniqueness-races-are-outcomes` (this codebase's standing rule: detect a lost
race via an affected-rows check on a conditional write, never a caught
`SqlError`) still holds everywhere else in `Persistence.hs`. It cannot hold
here: an `EXCLUDE` violation has no affected-rows equivalent, because there
is no `WHERE` clause that expresses "does this range overlap any existing
one" — that check only exists inside the index Postgres itself maintains.
`insertAvailableSlot` and `claimAcceptedIntakeRequest` each now catch `SqlError` and match on
`sqlState == "23P01"` (`exclusion_violation`) as the one narrow, contained
exception to the rule, rethrowing anything else unchanged.

**Accepted cost:** trigger maintenance surface. Any future column that
changes what counts as "appointed" (a new way to enter or leave that state)
needs `sync_intake_request_to_doctor_calendar` updated by hand — the trigger
is not derived from `intake_requests`' schema automatically. This is judged
acceptable at 2-3 doctor scale; revisit if the schema around `intake_requests`
churns often enough to make this a recurring source of missed updates.

## Reassignment and displacement both compose from reclaimAppointedIntakeRequest, not a dedicated transition (2026-07-13)

**Superseded (2026-09-28):** reclaim was removed; reassignment and displacement are now a close plus a new `IntakeRequest`. See "Reclaim removed; displacing a patient is Closed + a new IntakeRequest" below. (Earlier, in part (2026-09-27): the "No new `Domain.hs` function is needed" point — reclaim got a signature, `reclaimIntakeRequest`. See "Reclaim gets a signature in Domain.hs" below.)

**Found:** `persistReassignedIntakeRequest` had a real bug — it updated
`intake_requests`' `appointed_doctor_id`/`start_time`/`duration_minutes`
to the new slot's values but never deleted the `slots` row that slot came
from. Because `doctor_calendar`'s cross-table `EXCLUDE` constraint (see
"Overlap prevention" above) tracks `slots` rows as live intervals, the
still-present slot row and the newly-written appointment interval for the
same doctor/time would collide against each other, so the write would
reject via the `23P01` exclusion-violation path it's already wired to
catch — the caller would see `NewSlotAlreadyClaimed` for a slot that was
in fact free. Found while investigating a documentation pass on the
`triage-db-codegen` skill, not by design.

**Rejected fix:** simply add the missing `deleteSlot` call to
`persistReassignedIntakeRequest`, wrapped in `withTransaction` like
`persistMatchedIntakeRequest`. This would have worked, but it would make
reassignment a second, parallel implementation of exactly what matching
already does correctly — the same delete-a-slot-and-update-the-request
transaction, duplicated for no gain, now two places to keep in sync
instead of one.

**The actual insight:** `AppointedIntakeRequest` already embeds the
`TriagedIntakeRequest` it came from, unchanged, as its `triaged` field
(see "AppointedIntakeRequest hard-copies doctor/time/duration, embeds
TriagedIntakeRequest whole" above). Reclaiming an `Appointed` request back
to `Accepted` is therefore free — `appointed.triaged` already *is* the
value to return to. No re-triage happens, no new information is produced,
the same `IntakeRequestId`/`triagedAt`/priority survive exactly. No new
`Domain.hs` function is needed for this either, same precedent as
`Rejected`/`Closed`: direct field access, not a wrapped transformation.

**Decided:** `reassignIntakeRequestSlot`, `persistReassignedIntakeRequest`,
and `reassignAppointedIntakeRequestSlot` are removed entirely, replaced by
one new primitive — `reclaimAppointedIntakeRequest` (`Service.hs`), backed
by `persistReclaimedIntakeRequest` (`Persistence.hs`), a single-table
`UPDATE ... WHERE state = 'appointed'` moving the row back to `'accepted'`
and nulling `appointed_doctor_id`/`start_time`/`duration_minutes`. Nothing
about `doctor_calendar` needs to change — its existing trigger already
deletes the corresponding row on any `'appointed'` → non-`'appointed'`
transition.

"Reassignment" and "displacement" are not two different mechanisms
needing their own dedicated transition — they're both compositions of
this one primitive with an operation that already exists and is already
correct:

- **Reassignment** = `reclaimAppointedIntakeRequest`, then
  `matchAcceptedIntakeRequestToSlot` against a different slot, same
  doctor, back-to-back.
- **Displacement** = `reclaimAppointedIntakeRequest` alone — the request
  falls back into the ordinary waitlist (`state = 'accepted'`), no new
  `IntakeRequest`, no lost history.

Whether the vacated original time becomes bookable again is still not
automatic either way — that's a separate, explicit `createAvailableSlot`
call by the caller, per `deleted-on-match`'s existing convention. This was
already true of the old `reassignIntakeRequestSlot` design and isn't
changed by this one.

**A side effect worth naming explicitly:** this resolves half of the
fairness-reversal concern flagged in "IntakeRequest: Appointment folded
into one sum type, one identity" above — the worry that a displaced
patient's original wait time and clinical judgment would be lost unless
the doctor happened to write it into a new request's narrative. That
concern doesn't apply here: displacement now reuses
`reclaimAppointedIntakeRequest`, which preserves the *same*
`IntakeRequestId`, `triagedAt`, and `priority` exactly — nothing is lost
structurally, and no narrative-writing habit is needed to preserve it.
This is a consequence of the design, not a mitigation layered on top.

**What this does NOT decide:** whether a displaced patient's priority
should be *bumped* as a compensating policy (e.g. moved up a tier, or
given an earlier deadline, for having been displaced) is a separate,
genuinely open question, untouched by this change — see Open Questions
below.

## Doctor calendar: the no-overlap invariant is declared in Domain.hs, enforced by the database (2026-09-27)

**Problem:** the no-overlap rule (see "Overlap prevention" above) was
enforced only by `doctor_calendar`'s `EXCLUDE` constraint and appeared
nowhere in `Domain.hs` or `docs/domain-model.md`. Since `Domain.hs` is the
spec every other layer is derived from, a real domain invariant was
invisible to anyone reading the spec.

**Why Domain.hs can declare it but not enforce it:** every other invariant
in `Domain.hs` holds within one value (`mkRoutineWithin`'s `from <= to`).
This one spans every stored slot and appointed request of a doctor. A
`DoctorCalendar` value is a snapshot of what was read; it cannot prove it
matches what is stored now. Enforcing the rule with a pure check alone is
exactly the naive check-then-insert rejected above. So the database
constraint stays the enforcement; `Domain.hs` states the rule and checks it
for values it holds.

**Decided:**

- `CalendarEntry` (`Slot AvailableSlot | Appointment
  AppointedIntakeRequest`) moves from `Service.hs` to `Domain.hs`. This
  reverses `Service.hs`'s earlier note that it was "not a domain concept
  with an invariant to protect" — it is now the unit the invariant is
  stated over. `Transport.hs` imports it from `Domain`, so Transport no
  longer depends on Service.
- `DoctorCalendar` is sealed, practice-wide (`Map DoctorId (Map UTCTime
  CalendarEntry)`), matching the single `doctor_calendar` table. Intervals
  are half-open `[start, end)`, the same as `tstzrange`'s default `[)`.
- Two ways in: `mkDoctorCalendar :: [CalendarEntry] -> Maybe
  DoctorCalendar` rebuilds a calendar from stored entries;
  `addAvailableSlot :: AvailableSlot -> DoctorCalendar -> Maybe
  DoctorCalendar` is the one domain operation that adds time. Appointments
  are never added: they arrive by matching, which takes over the slot's
  exact interval and so cannot create an overlap.
  `matchIntakeRequestToSlot` therefore takes no calendar.
- `slotEnd` removed — it had no users outside `Domain.hs`; end times only
  matter to the overlap rule, which is stated over calendar entries.
- `Service.createAvailableSlot` now fetches the doctor's entries that
  intersect the new slot (`Persistence.fetchDoctorCalendar`), checks
  `addAvailableSlot`, then inserts — the same "Service checks, Persistence
  guards the write" pattern as match/accept. Both a failed check and an
  `EXCLUDE` violation report `SlotConflict`. Its signature becomes
  `IO (Either ServiceError SlotCreationOutcome)`.
- Stored entries that already overlap fail decoding as
  `DecodeError`'s `OverlappingCalendarEntries`, surfaced as
  `PersistenceDecodeError` (500) — the same smart-constructor-on-decode
  pattern as `InvalidWithin` for `mkRoutineWithin`.

**Rejected:**

- `DoctorCalendar` as the enforcement (loaded, checked, saved): the
  check-then-insert race above. Making it a versioned aggregate would close
  the race but gives appointments two owners (the calendar and the
  `IntakeRequest` lifecycle) and is convention-enforced, the same reason
  advisory locks were rejected.
- A per-doctor calendar (`Map UTCTime CalendarEntry`): `addAvailableSlot`
  would need a second failure reason (entry for a different doctor).
- A fetch window of "start minus the longest duration": hard-codes that
  the longest `Duration` is 60 minutes outside `Domain.hs`. The intersect
  query only selects rows; returning more than needed is harmless.

**General rule this establishes:** `Domain.hs` declares every invariant.
One that holds within a single row maps to a `CHECK`; one that spans rows
maps to `EXCLUDE`/`UNIQUE`, and only the latter depends on the database to
hold for stored data.

## Stored facts are referenced by ID, never accepted from the caller (2026-09-27)

**Found:** `POST /intake-requests/:id/match` accepted a whole `AvailableSlotDTO`. `persistMatchedIntakeRequest` deleted the stored slot by its id, but the appointment copied the client-sent doctor, start and duration. So any API client could book a request at a time, and for `AnyDoctor` requests with a doctor, of its choosing. The only limits were `matches` and the `doctor_calendar` `EXCLUDE` constraint. The shipped frontend always sent the slot unchanged. This was found while discussing whether to seal `AvailableSlot`, not by a test.

**Cause:** it started in `Service.hs`. From its first version (`1776d9d`), Service functions took a whole `AvailableSlot` from their caller, and the service skill's `caller-supplied-facts` rule then made that a convention ("take that value whole … the caller already assembled it correctly"). `matchAcceptedIntakeRequestToSlot` followed it. The API skill copied the signature and satisfied it the easiest way, by decoding the slot from the request body ("`AvailableSlotDTO`, reused directly"). That was the last point where untrusted input entered, and the question "who is the authority on these fields?" wasn't asked.

**Decided:** an operation on an existing stored entity takes its ID and fetches the stored value; the caller never supplies facts the database holds (`stored-facts-by-reference`, in `triage-service-codegen`). API request bodies follow from the Service signature, so there is no separate API-side rule. The match route now takes `{slotId}`. A missing slot reports `SlotAlreadyClaimed`: slots are deleted on match, so "claimed a moment ago" and "never existed" look identical, and a lost race is an outcome, not an error.

**Not yet done:** integration tests against a real database for the write paths. That's the kind of test that would have caught this.

## A slot's duration always comes from its healthcare service (2026-09-27)

**Found:** `Domain.hs` and the README already said `HealthcareService` "defines the canonical duration copied into each Slot at allocation time", but the code took the duration from the client: `CreateAvailableSlotRequest` had its own `duration` field and the New-slot form had a free duration picker. A 15-minute service could get a 60-minute slot. Nothing in the domain read `HealthcareService.duration` at all.

**Decided:** keep the spec as written. `Service.createAvailableSlot` takes a `HealthcareServiceId`, fetches the service and copies its duration into the slot (`stored-facts-by-reference`); it also mints the `SlotId`, as the other create functions do. The request body and the UI picker lose `duration`; the form shows the service's duration read-only. The slot keeps its own copy, so a later change to a service would not alter existing slots.

**Unknown service:** a new `ServiceError`, `HealthcareServiceNotFound`, not an outcome. Services are never deleted, so an unknown id is the caller's mistake, not a lost race. Services are never updated either, so the fetched duration can't go stale before the insert.

## Updates follow the transition rules defined in Domain.hs (2026-09-27)

**Found:** `persistTriagedIntakeRequest` and `persistRejectedIntakeRequest` wrote with `WHERE id = ?` only, so a concurrent accept/reject could overwrite each other (fixed in `819eae5`). `Domain.hs` defined the precondition all along — both transitions take a `SubmittedIntakeRequest` — but no rule said how a transition's source case becomes a guard on the write. `uniqueness-races-are-outcomes` framed guarding as a judgment about which races mattered; close was guarded, accept/reject were never considered, and the Appointment→IntakeRequest fold carried them over unchanged.

**Decided:** `triage-db-codegen` gains `updates-follow-domain-transitions`: an `UPDATE` may change a sum type's case from A to B only if `Domain.hs` defines that transition, and it is conditioned on `state = 'A'` with an affected-rows check. A is found mechanically — the case whose payload type is exactly the transition's input type; embedding an earlier stage as history doesn't make a case that stage. One source case per write, never `IN (...)`. The skill also now states that a new or changed rule applies to existing functions, not only new ones.

**Consequence for the model:** the derivation needs every non-terminal case of a sum type to have a distinct payload type. That holds today and is now a property to preserve in `Domain.hs`.

## Reclaim gets a signature in Domain.hs (2026-09-27)

**Superseded (2026-09-28):** reclaim was removed. See "Reclaim removed; displacing a patient is Closed + a new IntakeRequest" below.

**Found:** a clean-room generation from `Domain.hs` and `triage-db-codegen` alone derived every lifecycle transition's source case from its input type — except reclaim, which existed only as field access (`Accepted appointed.triaged`) described in a comment. `Accepted`'s constructor takes `TriagedIntakeRequest`, Accepted's own payload, so the Appointed source was invisible in the types. The 2026-07-13 entry had called this the same precedent as `Rejected`/`Closed`, but those are constructors that take the source stage (`Rejected SubmittedIntakeRequest …`, `Closed AppointedIntakeRequest …`), so their source case is derivable; reclaim's wasn't.

**Decided:** `reclaimIntakeRequest :: AppointedIntakeRequest -> TriagedIntakeRequest` in `Domain.hs`. It is still just the embedded value — no re-triage, same `IntakeRequestId`/priority/`triagedAt` — but now every transition is a function or constructor signature, so `updates-follow-domain-transitions` derives the whole transition set from types with no hand-kept row. `Service.reclaimAppointedIntakeRequest` calls it, pairing the way `acceptIntakeRequest`/`acceptSubmittedIntakeRequest` do. A property test checks that reclaiming undoes a match exactly.

## Row version for freshness; state guard kept for legality (2026-09-27)

**Superseded (2026-09-28):** the version was removed after reclaim was. See "Row version removed; the state guard also gives freshness" below.

**Found:** reclaim made Accepted ⇄ Appointed a cycle. Between a close or reclaim's fetch and its write, the request could be reclaimed and re-matched to a different slot; the row is back in `'appointed'`, `WHERE state = 'appointed'` passes, and the write acts on an appointment its caller never saw. The earlier assumption that "state itself is the version discriminator" no longer held.

**Decided:** separate the two properties. *Legality* (A → B is allowed) comes from `Domain.hs` and stays enforced by the state guard (`updates-follow-domain-transitions`). *Freshness* (the row is the one the caller decided from) gets a row version: `intake_requests.version`, bumped by a `BEFORE UPDATE` trigger on every update; every read-decide-write checks `AND version = ?` (`row-version-for-freshness`). Persistence returns `Versioned a` from the fetches decisions are made from; every transition write takes the `RowVersion`. `Domain.hs` is unchanged.

**Rejected:** guarding on the observed appointment fields (fixes only this case, not several A → B functions or A → A edits); locking with `SELECT … FOR UPDATE` (prevents rather than detects — a new convention, when the project already reports lost races as outcomes); `SERIALIZABLE` + retry (heavier than 2–3 doctors need). The state guard is kept alongside the version: the version catches concurrent writes, the state guard catches our own code attempting a transition `Domain.hs` doesn't allow.

**Not decided:** carrying the version to clients so an action taken on a stale screen is caught. Out of scope for now. The version column went into `migrations/0001_init.sql` directly, not a new migration, since no database has had the schema applied beyond local development.

## A lost version race is reported as "changed since read" — one outcome, no retry (2026-09-27)

**Superseded (2026-09-28):** replaced by "Request-state answers follow the lifecycle: moved on, or wrong state" below. (Earlier the same day: the outcome was kept while the row version was removed, detected by the state guard alone.)

**Found:** with the row version in place, a zero-row write can no longer mean "wrong state" (Service confirmed the state at fetch time, and an unchanged version means an unchanged row) — it always means the request changed since it was read. But each operation still reported it with a guess at *how*: close and reclaim said `RequestAlreadyClosed`, mark-stale `RequestNotAccepted`, match `RequestAlreadyClaimed` ("already scheduled, drop it"). Each is wrong when the request was reclaimed and re-matched, or matched and reclaimed back to the waitlist.

**Decided:** one uniform result. Operations without an outcome type of their own (accept, reject, reclaim, mark stale, close) return `Either ServiceError (Fresh a)`, `Fresh a = Applied a | ChangedSinceRead`; `MatchOutcome` gains `RequestChangedSinceRead`. On the wire both are `{"outcome": "requestChangedSinceRead"}`. It is an outcome, not a `ServiceError` — losing a race is never the caller's mistake (`error-vs-outcome-types`). Nothing retries: the caller decided from what it saw, and re-running (say) a close against a re-matched request would close an appointment it never looked at.

**Rejected:** a `RequestChangedSinceRead` `ServiceError` (smaller, but breaks `error-vs-outcome-types`); automatic retry (acts on data the caller never saw).

**Also:** the accept, reject and mark-stale forms ignored non-success outcomes entirely (only match showed them), so `requestNotSubmittedAnymore` was already invisible. They now show them, with readable text for `requestChangedSinceRead`.

## Triage decides the doctor requirement, for any priority (2026-09-28)

**Superseded in part (same day):** `requestedDoctor` was then removed — see "The doctor requirement is only a triage decision" below.

**Found:** `Domain.hs`'s comment said Emergency/Urgent requests can't require a specific doctor ("no time slack to spend waiting"), but `doctorRequirement` sat on `SubmittedIntakeRequest`, set before triage, and `matches` enforced it at every priority. Demonstrated against the real module: an Emergency that asked for Dr A was refused Dr B's slot ten minutes out, and the waitlist gave that slot to a Routine request. The comment and the types had disagreed since `4db1a10` introduced both; triage had no way to drop the requirement.

**Decided:** two facts, two fields. `SubmittedIntakeRequest.requestedDoctor` is what was asked for; `TriagedIntakeRequest.doctorRequirement` is what triage decided, and the only one matching uses. `acceptIntakeRequest` takes it, for any priority — an Emergency or Urgent request waits for a specific doctor only if triage explicitly keeps one (continuity of care), and the triage form warns when it does. Storage: `requested_doctor_id` and `required_doctor_id`, the latter `NULL` before triage (`CHECK`).

**Rejected:** a `considerDoctorRequirement :: Bool` on the triaged request (allows meaningless `True` + `AnyDoctor`, and can't say "a different doctor than requested"); `Routine RoutineDue DoctorRequirement` so only Routine can carry one (structural, but rules out continuity of care for urgent patients, and needs a tie-break policy in `Ord IntakeRequestPriority`).

**Also:** `generate-types` was broken (the backend serves Swagger 2.0; openapi-typescript v6 and v7 read only OpenAPI 3). It now converts the spec with `swagger2openapi` first and keeps openapi-typescript v7, so `types.ts` keeps its format. Serving OpenAPI 3 from the backend (`servant-openapi3`) remains the long-term option.

## The doctor requirement is only a triage decision; no requested doctor (2026-09-28)

**Decided:** `SubmittedIntakeRequest.requestedDoctor` (and `requested_doctor_id`) removed. The person submitting a request often can't name a doctor precisely, and a preference ("Dr Smith again, if possible") says more as narrative text than as an id. Nothing enforced the requested field — matching already used only triage's decision — so it existed only to pre-fill the triage form. Now `TriagedIntakeRequest.doctorRequirement` is the one typed doctor requirement; the triage form defaults to any doctor, and the submit form's narrative prompt invites a preference.

**Why this is safe to remove:** the structured request field was never a validated requirement either; adding it back later is cheap if triagers find the narrative insufficient.

## New slots are created by addAvailableSlot; AvailableSlot stays open (2026-09-28)

**Decided:** `addAvailableSlot :: SlotId -> DoctorId -> HealthcareService -> UTCTime -> DoctorCalendar -> Maybe (AvailableSlot, DoctorCalendar)` is how a new slot is created: it checks the slot against the doctor's calendar and takes the duration from the service, so both creation rules are stated in `Domain.hs`. Service no longer builds the slot itself. Transport's unused `toDomainAvailableSlot`/`toDomainCalendarEntry` were removed. The database's `EXCLUDE` constraint stays the authority for stored data; Service's pre-insert check duplicates it deliberately, because `addAvailableSlot` and `DoctorCalendar` are how the spec declares the no-overlap rule (`5ea1396`).

**Considered and rejected: sealing `AvailableSlot`.** Tried as a `newtype` around an open `SlotDetails`, produced only by `addAvailableSlot` and `mkDoctorCalendar` (every read rebuilding the doctor's calendar). It was implemented and then dropped before commit, because it can't deliver what it seemed to: `mkDoctorCalendar` is exported and `SlotDetails` is open, so `calendarSlots <$> mkDoctorCalendar [anyDetails] []` still makes a slot from arbitrary data — a single slot always fits an empty calendar. A pure module can't prove a value came from storage; only a type Persistence alone could produce would, which inverts the dependency direction. So the seal would have cost an extra query per slot read and `slotDetails` everywhere, for friction rather than a guarantee. Earlier variants (`restoreAvailableSlot`; read-only fields via `HasField` plus a parallel `StoredSlot` type) were rejected for the same reason or for their ceremony. Revisit only if slot fabrication causes a real bug — and then look at provenance, not sealing.

## Unknown ids are ServiceErrors, checked in Service (2026-09-28)

**Found:** a patient, doctor or service id that doesn't exist reached the database and failed a foreign key; the `SqlError` surfaced as a 500. No bad data could get in, but the caller got no usable answer. Affected: submit (patient), accept (service, and the doctor in a `SpecificDoctor` requirement), create slot (doctor).

**Decided:** Service checks each referenced id before writing and reports `PatientNotFound`, `DoctorNotFound` or `HealthcareServiceNotFound` — the pattern `createAvailableSlot` already used for services. Doctors, patients and services are never deleted, so the check can't race the write. `submitIntakeRequest` now returns `Either ServiceError …`, so its route answers with the `{"outcome", "detail"}` envelope like the other mutations (`"submitted"` on success).

**Rejected:** catching the foreign-key violation (SQL state 23503) in Persistence — against the affected-rows-not-exceptions convention, and it would have to work out which id was wrong from the constraint name.

## Reclaim removed; displacing a patient is Closed + a new IntakeRequest (2026-09-28)

**Decided:** displacing or rescheduling an appointed patient is `Closed (Cancelled ByDoctor t note)` followed by submitting and accepting a new `IntakeRequest`. `reclaimIntakeRequest` goes away, and every lifecycle transition is one-way again, as the 2026-07-11 entries originally decided.

**Why:** reclaim was the only cycle in the lifecycle (Appointed → Accepted → Appointed → …). It erased the displaced appointment — doctor, time and duration were set to NULL, leaving no record the patient was ever booked — while what it preserved, `triagedAt`, plays no part in waitlist order (`checkIntakeWaitlist` sorts on priority only). Closing keeps the cancelled appointment as a record.

**Rejected:** linking the new request to the one it replaces. An `IntakeRequest` covers one intake — one ask to one appointment — not a patient's whole care history, and `patientId` already groups a patient's requests.

**Left to the doctor, not the model:** any context goes into the new request's narrative, and any compensating priority is a triage judgment — the doctor takes the previous priority into account when accepting the new request. This closes the open questions about a displaced patient's lost wait time and a priority bump for displaced patients; no rule is added for either.

**Cost accepted:** rescheduling takes close + submit + accept + match instead of reclaim + match, and the request gets a new id.

**Consequence:** with no cycle, a row enters each state at most once and no update keeps a row in the same state, so the state guard also establishes freshness. The row version ("Row version for freshness; state guard kept for legality" above) is no longer needed; removing it is a separate decision. If an update that keeps the state (an in-place edit) is ever added, the need for a version returns.

## Row version removed; the state guard also gives freshness (2026-09-28)

**Decided:** `intake_requests.version`, its trigger, and `RowVersion`/`Versioned` are removed. Every transition write is guarded on its source state only; `Fresh`/`ChangedSinceRead`/`RequestChangedSinceRead` are unchanged — a zero-row write still means the request changed since it was read.

**Why:** the version existed because reclaim made Accepted ⇄ Appointed a cycle (see "Row version for freshness" above). With reclaim gone, two things hold: no transition in `Domain.hs` leads back to an earlier state, and every `UPDATE` of `intake_requests` changes the state. So a row is in each state at most once and its data is fixed on entry; if a write finds the state its caller read, the row is the one its caller read.

**Condition to preserve:** both of those. A transition back to an earlier state, or an update that keeps a row in the same state (an in-place edit), breaks the argument — then a row version is the known answer again. `triage-db-codegen`'s `state-guard-is-freshness` rule says to stop and ask in that case.

**Not decided here:** whether the outcomes should become more specific now that the state a request moved to is knowable. Decided separately — see "Request-state answers follow the lifecycle" below.

## Request-state answers follow the lifecycle: moved on, or wrong state (2026-09-28)

**Found:** every operation expects the request in one state, and when it isn't, the answer depended on which operation was called and on timing. The same fact — someone else acted first — was a `ServiceError` when the fetch noticed (`RequestNotSubmittedAnymore`, `RequestAlreadyClosed`, `RequestNotAccepted`) and the outcome `ChangedSinceRead` when the write noticed a moment later. Match answered an Appointed request with the outcome `RequestAlreadyClaimed`; mark stale answered the same state with the error `RequestNotAccepted`. The generic "changed since read" was chosen on 2026-09-27 because, with reclaim's cycle, the state a request had moved to couldn't be named reliably; with a one-way lifecycle it can.

**Decided:** the answer is derived from the lifecycle, by comparing the state an operation expects with the state the request is in:

- **The current state comes after the expected one** — someone else acted first. A legitimate outcome carrying the request as it is now, whether the fetch or the lost write noticed. `Transition a = Transitioned a | MovedOn IntakeRequest` (replaces `Fresh`); in `MatchOutcome`, `RequestMovedOn IntakeRequest` (replaces `RequestAlreadyClaimed` and `RequestChangedSinceRead`). On the wire: `{"outcome": "requestMovedOn", "detail": <the request>}`. After a lost write, Service reads the request once more; the read always finds a later state, since states only move forward.
- **The current state can't come after the expected one** — the caller could never have seen the state it acted on: a caller mistake. One `ServiceError`, `RequestInWrongState IntakeRequest` (replaces `RequestNotSubmittedAnymore`, `RequestNotAccepted`, `RequestNotYetTriaged`, `RequestNotAppointed`, `RequestAlreadyClosed`), carrying the request for diagnosis; `{"outcome": "requestInWrongState", "detail": <the request>}`.

Per expected state: every state comes after Submitted, so accept/reject only ever answer "moved on". After Accepted come Appointed, Stale, `WithdrawnFromAccepted` and Closed; Submitted, Rejected and `WithdrawnFromSubmitted` can't follow it (the two Withdrawn cases record which state they came from, which makes this decidable). After Appointed comes only Closed. Nothing retries, as before: the caller looks at what the request is now.

**Where "comes after" lives:** in each Service operation's case split, exhaustive with no wildcard, derived from `Domain.hs`'s transition table (the rule is stated in `triage-service-codegen`). Not a function in `Domain.hs`: a stage type plus an ordering would add to the specification only to serve error reporting.

**Rejected:** keeping the current answers (the timing-dependent split stays, and each new operation needs a judgment call); `ChangedSinceRead` everywhere, including fetch-time mismatches (consistent, but discards what is now knowable and still doesn't separate lost races from caller mistakes).

---

## Open questions (from 2026-06-26 session — not yet resolved)

- `SlotEvent` vocabulary: does it live in Domain (as a description of what
  *can* happen to a Slot) or in Persistence (as a description of what *was*
  written)? Leaning Persistence since event sourcing itself was rejected,
  but not settled.
- Read-model freshness: is the read side always-consistent with the write
  side (single Postgres, no replication lag) or does the design need to
  tolerate staleness? Depends on deployment target, not yet chosen.
- Explicit command types (`BookSlot`, `CancelBooking`, ...) vs. direct
  function calls on Domain values — not yet decided whether commands earn
  their keep at this scale.
- OPEN, NOT YET RESOLVED: whether Patient needs a `name` field at all,
  vs. an opaque per-patient reference (e.g. phone number or an existing
  informal chart number), vs. eventually referencing an external patient
  registry that doesn't exist yet. Pending a conversation with the
  domain expert about whether there's already a stable per-patient
  identifier in informal use today. Domain.hs is unchanged for now — do
  not modify it as part of this task.

Do not resolve these speculatively in code. Validate with the domain expert
first, per the workflow discipline in CLAUDE.md.
