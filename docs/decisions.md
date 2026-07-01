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

**Decided:** Sealed sum types (`Slot`, `HealthcareRequest`) persist as a
single table with a discriminator column, not one side-table per state.

**Why:** State transitions are frequent and the state set is small and
closed. Side-tables would mean cross-table moves on every transition for no
real query benefit at this scale.

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
`reassignSlot` — it frees the old `BookedSlot`, books the new one, and
updates `OpenAppointment`'s `SlotId`, re-checking the same structural
eligibility (`matches`) against the proposed slot. The appointment stays
`Open` throughout.

**Rejected:** the previous representation, `CloseReason`'s `Rescheduled
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

## No lineage tracking across re-triage after failed reassignment (2026-07-01)

**Decided:** when a slot reassignment fails, the appointment is closed, and
the same `HealthcareRequestDetails` is re-triaged, the new
`TriagedHealthcareRequest` is a plain new row — no FK or other pointer back
to the original.

**Why:** `Domain.hs` itself doesn't track this lineage —
`triageHealthcareRequest` doesn't thread an old `TriagedHealthcareRequest`
through — so the schema doesn't invent tracking the domain model doesn't
have. Revisit only if reporting/audit needs surface a concrete requirement.

## slots/appointments cross-table consistency: transaction discipline, not a trigger (2026-07-01)

**Decided:** `slots.appointment_id` and `appointments.slot_id` are kept
consistent by transaction discipline in `Persistence.hs` — both rows
written together in one transaction for `satisfyHealthcareRequest` and
`reassignSlot` — not by a database trigger. Both FKs are `DEFERRABLE
INITIALLY DEFERRED` to allow this.

**Why:** per db-codegen's `transactional-cross-table-consistency`, a trigger
is justified only when nothing else catches a mismatch; here the
Persistence-layer transaction already does. Rejected adding one "to be
safe."

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