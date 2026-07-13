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
state without it being a real transition worth naming). But if the slot
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
- **Narrowed (2026-07-13):** the record-loss half of this question is now
  resolved by design, not doctor habit — see "Reassignment and
  displacement both compose from reclaimAppointedIntakeRequest..." above;
  a displaced patient's `IntakeRequestId`/`triagedAt`/priority survive
  `reclaimAppointedIntakeRequest` exactly, no narrative-writing habit
  needed. What remains open: should a displaced patient's priority be
  *bumped* as a compensating policy (e.g. moved up a tier, or given an
  earlier deadline, for having been displaced)? Not yet validated with
  the domain expert.

Do not resolve these speculatively in code. Validate with the domain expert
first, per the workflow discipline in CLAUDE.md.
