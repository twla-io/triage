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

## Persistence schema: discriminator column over side-tables (2026-06)

**Decided:** Sealed sum types persist as a single table with a discriminator
column, not one side-table per state. Live cases: `HealthcareRequest`
(`submitted`/`triaged`), `Appointment` (`open`/`closed`).

**Why:** State transitions are frequent and the state set is small and
closed. Side-tables would mean cross-table moves on every transition for no
real query benefit at this scale.

**Note:** `Slot` was originally a third case here (`available`/`booked`).
It no longer applies — `AvailableSlot` is the only slot type as of the
`deleted-on-match` redesign (see below); there is nothing left to
discriminate.

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

## Rescheduling: reassignSlot, not a CloseReason variant (2026-07-01)

**Decided:** Moving an open appointment to a different slot is modeled as
`reassignSlot :: OpenAppointment -> AvailableSlot -> Maybe OpenAppointment`
— it re-checks the same structural eligibility (`matches`) against the
proposed slot and, on success, produces a new `OpenAppointment` with the
new slot's doctor/time/duration hard-copied in. The old slot's facts are
discarded, not freed or returned — there is no slot-level state to
transition (see `deleted-on-match`). The appointment stays `Open`
throughout; its `AppointmentId` and embedded request are unchanged.

**Rejected:** the original representation, `CloseReason`'s `Rescheduled
AppointmentParty` constructor — closing the appointment to reschedule
conflated "this appointment is done" with "this appointment moved," losing
the open appointment's identity across the move.

**Why:** an appointment being rescheduled is still the same appointment,
still open — closing it to represent a slot change would mean an
`OpenAppointment`'s identity doesn't survive an operation that shouldn't
affect its identity at all.

## Appointments: FK to healthcare_requests, not denormalized (2026-07-01)

**Decided:** the `appointments` table stores `healthcare_request_id` as a
foreign key back to `healthcare_requests`, rather than denormalizing the
full `TriagedHealthcareRequest` onto the appointments row.

**Why:** `OpenAppointment`'s constructor is open — no invariant to protect
— so reconstruction is a plain join. A FK is the relational mirror of "one
fact in one place," matching how `OpenAppointment` embeds the request by
reference in Haskell rather than duplicating its fields.

## healthcare_requests lifecycle: two states, no delete-on-match, waitlist is derived (2026-07-01)

**Decided:** `healthcare_requests` state is two-valued (`submitted` /
`triaged`) only — no third "matched" state, and no schema-level path back
from matched to waiting, confirmed against `Domain.hs`: nothing transitions
a request from matched back to waiting. Rows are never deleted on
consumption.

**Rejected:** the old `appointment_requests` delete-on-match behavior from
an earlier domain version.

**Consequence:** "currently waiting" is a derived query — a triaged request
with no corresponding `appointments` row (anti-join) — not a stored flag.

## Doctor-originated requests reuse the existing flow unchanged

**Decided:** A doctor scheduling a follow-up (e.g. "come back in 3 months")
is modeled as an ordinary `HealthcareRequestDetails` + `triageHealthcareRequest`
call — same flow as a patient-submitted request, with the doctor as both
the author of `narrative`/`doctorRequirement` and the triager, potentially
in the same transaction with no observable `Submitted`-only gap.

**Why:** `HealthcareRequestDetails` and `triageHealthcareRequest` never
required patient self-authorship or an elapsed gap between submission and
triage — that was an implicit, unvalidated assumption, not something the
types enforce. No new mechanism is needed.

**Open, not yet decided:** whether doctor-authored vs. patient-authored
requests need to be distinguishable (for reporting, or because a
doctor-originated request arguably doesn't need the same triage scrutiny).
Left alone — no function currently needs this distinction, and CLAUDE.md's
standard is not to add it speculatively.

## No lineage tracking across re-triage after failed reassignment (corrected)

**Decided:** when a slot reassignment fails, the appointment is closed, and
the same `HealthcareRequestDetails` is re-triaged, the new
`TriagedHealthcareRequest` reuses the **original** `HealthcareRequestId` —
`details` is extracted from the closed appointment's embedded request and
passed to `triageHealthcareRequest` unchanged, so `details.id` is
preserved. This is an in-place update via `persistTriagedRequest` (same
row, new priority/triagedAt/service), not a new row.

**Why no lineage tracking is needed:** there is nothing to link — it's the
same record being re-triaged, not two records that need a pointer between
them. (Superseded: an earlier version of this entry incorrectly stated a
new `HealthcareRequestId` is minted — that was wrong; corrected here.)

## Matching is atomic insert-and-delete, not FK sync (2026-07 revision)

**Superseded:** the original version of this entry described keeping
`slots.appointment_id` and `appointments.slot_id` in sync via transaction
discipline (both `DEFERRABLE INITIALLY DEFERRED`). That FK pair no longer
exists.

**Decided:** `appointments` doesn't reference `slots` at all — matching
hard-copies doctor/time/duration into the `appointments` row and deletes
the matched `slots` row, both within one transaction
(`atomic-multi-table-write`). No trigger; the atomicity is enforced by the
Persistence function's own `withTransaction` scope.

**Why:** once `OpenAppointment` stopped referencing a slot by ID (see
`deleted-on-match`), there was no cross-table pair left to keep in sync —
the remaining risk is a crash between insert and delete leaving a phantom
available slot or an appointment whose slot was never actually claimed,
which the same single-transaction discipline still closes.

## Slot has no existence after being matched (2026-07)

**Decided:** `Slot`, `SlotDetails`, and `BookedSlot` do not exist as types.
`AvailableSlot` is the only slot representation. Once matched, a slot's
facts are copied into the resulting `OpenAppointment` and the original
ceases to be referenced. In the schema, a matched `slots` row is deleted,
not flagged (`deleted-on-match`).

**Why:** a slot is a pre-declaration mechanism for matching, with no
domain significance of its own afterward. Keeping a `Booked` slot state
meant the same facts existed in two places (the slot's own record and the
appointment it produced) with nothing forcing them to agree — a real bug
was found this way: a freed `AvailableSlot` returned alongside a
`ClosedAppointment` that still, internally, asserted the slot was booked.

**Rejected:** keeping `Slot`'s two-state model and referencing it by
`SlotId` from the appointment side. Rejected because that reference would
be either permanently dangling (rows deleted on match) or require
indefinite slot retention purely to keep an unused reference valid.

**Consequence:** if a cancelled/reassigned appointment's original time
should become bookable again, that's an explicit new `AvailableSlot`
created by the caller — not an automatic domain-level transition.

## OpenAppointment hard-copies doctor/time/duration, no slot reference (2026-07)

**Decided:**

```haskell
data OpenAppointment =
  OpenAppointment AppointmentId TriagedHealthcareRequest DoctorId UTCTime Duration
```

Exported openly — no invariant to protect.

**Why:** once slots have no post-match existence, there's nothing left to
reference. The facts that matter are copied at match time — same
principle as embedding `TriagedHealthcareRequest`.

**Rejected:** an interim `BookedSlot` sealed wrapper, kept briefly as
"proof the slot passed `matches`." Removed once shown that any external
caller can already trivially construct a `TriagedHealthcareRequest` that
passes `matches` against any slot — the wrapper added no real protection,
same trust boundary as `AppointmentId` freshness elsewhere.

## ClosedAppointment embeds OpenAppointment unchanged; no dedicated close function (2026-07)

**Decided:**

```haskell
data ClosedAppointment = ClosedAppointment OpenAppointment CloseReason
```

Exported openly. No `closeAppointment` function — callers construct
`ClosedAppointment` directly.

**Why:** once `OpenAppointment` no longer asserts any live/mutable state,
embedding it whole is safe and free — "closing carries its full history."
`ClosedAppointment` was briefly sealed in an earlier iteration, but the
function gating it (`closeAppointment = ClosedAppointment`) was an
unconditional alias with no predicate — sealing added a false signal.

## CloseReason: Rescheduled removed, Cancelled carries a timestamp (2026-07)

**Decided:** `CloseReason = Completed | Cancelled AppointmentParty UTCTime
| NoShow AppointmentParty`. See "Rescheduling" entry above for why
`Rescheduled` was removed. The `UTCTime` on `Cancelled` records when the
cancellation occurred (distinct from the appointment's own date) — not
validated against the appointment's date structurally; whether something
is `Cancelled` vs. `NoShow` is the booking manager's judgment call,
recorded as given.

## RoutineWithin needs a read-only bounds accessor (2026-07)

**Decided:** `routineWithinBounds :: RoutineDue -> Maybe (UTCTime, UTCTime)`
added to `Domain.hs`, since `RoutineWithin`'s constructor is
deliberately unexported (protecting `mkRoutineWithin`'s `from <= to`) but
Persistence still needs to read its bounds back out to encode an
already-valid value. See `sealed-value-decomposition` in
`triage-db-codegen` — this is decomposition, not reconstruction, so
replay-through-a-gate-function doesn't apply; a plain read-only accessor
does.

## Concurrent-match races: affected-rows checks, not caught exceptions; a compound race needs rollback, not just reporting (2026-07-09)

**Decided:** any `Persistence.hs` write guarding a `UNIQUE` constraint that
enforces a domain invariant (not just data hygiene) detects a lost race via
the affected-row count on a conditional write (`DELETE ... WHERE id = ?`,
`INSERT ... WHERE NOT EXISTS (...)`) — never by letting Postgres throw a
`SqlError` and catching it. See `uniqueness-races-are-outcomes` in
`triage-db-codegen`'s `SKILL.md` for the general rule; `deleteSlot` was the
original instance, applied to both `persistMatchedAppointment` and
`persistReassignedAppointment` (slot-side race only — reassignment doesn't
write against `healthcare_request_id`, so it needs no second guard).

**Found:** `persistMatchedAppointment` actually guards *two* independent
races, not one. Beyond the slot-delete race (two concurrent operations
targeting the same `SlotId`), two concurrent matches can also target the
same `healthcare_request_id` — two different slots' waitlist scans both
picking up the same triaged request before either commits, guarded by
`appointments.healthcare_request_id UNIQUE`. Fixed by adding
`insertIfUnclaimed`, the same conditional-write pattern applied to the
request side.

**Found, and corrected before landing:** guarding both races isn't enough
on its own — if the slot delete succeeds but the request insert then loses
its race, the slot delete must be rolled back, or that slot vanishes from
`slots` with no committed appointment to show for it (a phantom loss,
exactly what `atomic-multi-table-write` exists to prevent). The first fix
for this used manual `begin`/`commit`/`rollback` to express "commit here,
roll back there" — but that gives up `withTransaction`'s own guarantee
(rollback on *any* escaping exception, not just the paths explicitly coded
for), reintroducing the class of risk `atomic-multi-table-write` exists to
close, in the course of fixing one instance of it.

**Kept:** `withTransaction` plus an internal, unexported exception type
(`MatchAbort`, constructors `SlotGone`/`RequestGone`) thrown inside its
action to trigger rollback, caught immediately outside and translated back
into `MatchPersistOutcome`. The exception never crosses
`persistMatchedAppointment`'s own boundary, so it doesn't touch this
module's "decode failures return `Either`, never throw" discipline — that
rule is about business-outcome reporting to callers, not about how a
function undoes its own partial writes internally.

**Why this belongs here, not just in code comments:** a future session
touching `persistMatchedAppointment` without this reasoning on hand could
plausibly "simplify" the `withTransaction`/`handle`/`throwIO` combination
back toward manual transaction control, not realizing that reintroduces the
exact bug this entry documents.

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

Do not resolve these speculatively in code. Validate with the domain expert
first, per the workflow discipline in CLAUDE.md.