-- triage: initial schema
-- Generated from Domain.hs. See SKILL.md (triage-db-codegen) for the rules
-- this schema follows and the reasoning behind each one. This file is the
-- live reference example — do not copy it verbatim into a future
-- regeneration without re-checking it against the current Domain.hs first.

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTORS / PATIENTS
-- minimal-types-minimal-tables: minimal domain types get minimal tables — id/name only, no
-- speculative columns (email, specialty, etc.) until Domain.hs gains them.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE doctors (
  id   UUID NOT NULL PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE patients (
  id   UUID NOT NULL PRIMARY KEY,
  name TEXT NOT NULL
);

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE SERVICES
-- Duration stored as minutes; decoded/encoded via decodeDuration/
-- encodeDuration in Persistence.hs (fail-loudly-on-decode). Duration
-- has no Ord instance, so ord-ranking-check's ranking check does not apply here.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE healthcare_services (
  id               UUID NOT NULL PRIMARY KEY,
  name             TEXT NOT NULL,
  duration_minutes SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60))
);

-- ═══════════════════════════════════════════════════════════════════════
-- SLOTS
-- discriminator-column-tables: one table, discriminator column, nullable state-specific columns.
-- Two states only (Available | Booked) — no Pending/Offered.
--
-- appointment_id has a circular relationship with appointments.slot_id
-- (transactional-cross-table-consistency) — the FK completing this circle is
-- added below, after the appointments table exists. Both sides are
-- DEFERRABLE INITIALLY DEFERRED so a single transaction can write both
-- tables in either order without a chicken-and-egg failure.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE slots (
  id                     UUID NOT NULL PRIMARY KEY,
  doctor_id              UUID NOT NULL REFERENCES doctors(id),
  healthcare_service_id  UUID NOT NULL REFERENCES healthcare_services(id),
  start_time             TIMESTAMPTZ NOT NULL,
  duration_minutes       SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60)),
  state                  TEXT NOT NULL CHECK (state IN ('available', 'booked')),
  appointment_id         UUID NULL,  -- FK added below (references appointments, not yet defined)
  CHECK (
    (state = 'available' AND appointment_id IS NULL) OR
    (state = 'booked'    AND appointment_id IS NOT NULL)
  )
);

-- A given appointment can be the booking on at most one slot at a time.
-- Postgres UNIQUE indexes allow multiple NULLs, so 'available' rows never
-- collide with each other here.
CREATE UNIQUE INDEX slots_appointment_id_key ON slots(appointment_id);

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE REQUESTS
-- discriminator-column-tables: one table, discriminator column (submitted/triaged) — a
-- request's lifecycle is one entity moving through two stages, not two
-- independent things.
--
-- nullability-as-discriminator (nullable-field-as-discriminator bijection):
--   - DoctorRequirement (AnyDoctor | SpecificDoctor) encodes via nullable
--     FK alone. NULL = AnyDoctor, set = SpecificDoctor. No redundant
--     discriminator column.
--   - RoutineDue's four cases (Anytime/NotBefore/NotAfter/Within) encode
--     via the joint nullability of due_not_before/due_not_after alone —
--     a genuine bijection:
--       NULL, NULL -> RoutineAnytime
--       set,  NULL -> RoutineNotBefore
--       NULL, set  -> RoutineNotAfter
--       set,  set  -> RoutineWithin
--   - Emergency/Urgent reuse due_not_after (structurally identical to
--     RoutineNotAfter: a single "must be seen by X" deadline) rather than
--     separate emergency_due/urgent_due columns.
--
-- ord-ranking-check: HealthcareRequestPriority and RoutineDue both derive Ord, but
-- ordering happens exclusively in Domain.hs (checkWaitlist's `sortOn
-- priority`, in-memory over already-decoded values) — never in SQL. No
-- integer tier-rank column exists here. Do not add one; nothing sorts by
-- this column at the database layer.
--
-- no-delete-on-consumption (this rule previously worked the opposite way, under a different number — see SKILL.md for why names replaced numbers): unlike the old
-- appointment_requests table, this row is NEVER deleted once matched, and
-- there is no third "matched" state value (no domain path returns a
-- matched request to waiting — confirmed against reassignSlot and
-- closeAppointment). "Currently waiting" is a DERIVED query, not a stored
-- state — see the waitlist query note in SKILL.md's Persistence section.
-- A displaced-and-re-triaged request (failed reassignSlot -> close ->
-- re-triage) produces an entirely new row here with no lineage pointer
-- back to the original, by deliberate choice — Domain.hs itself doesn't
-- track that lineage, and this schema doesn't invent it.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE healthcare_requests (
  id                     UUID NOT NULL PRIMARY KEY,
  patient_id             UUID NOT NULL REFERENCES patients(id),
  narrative              TEXT NOT NULL,
  required_doctor_id     UUID NULL REFERENCES doctors(id),  -- NULL = AnyDoctor
  created_at             TIMESTAMPTZ NOT NULL,

  state                  TEXT NOT NULL CHECK (state IN ('submitted', 'triaged')),

  -- Triage-only columns. All NULL while state = 'submitted'.
  healthcare_service_id  UUID NULL REFERENCES healthcare_services(id),
  tier                   TEXT NULL CHECK (tier IN ('emergency', 'urgent', 'routine')),
  due_not_before         TIMESTAMPTZ NULL,
  due_not_after          TIMESTAMPTZ NULL,
  triaged_at             TIMESTAMPTZ NULL,

  CHECK (
    (state = 'submitted' AND healthcare_service_id IS NULL AND tier IS NULL
       AND due_not_before IS NULL AND due_not_after IS NULL AND triaged_at IS NULL)
    OR
    (state = 'triaged' AND healthcare_service_id IS NOT NULL AND tier IS NOT NULL
       AND triaged_at IS NOT NULL)
  ),

  -- Emergency/Urgent: exactly one deadline (due_not_after), never a window.
  -- Routine: all four nullability combinations of
  -- (due_not_before, due_not_after) are valid, per the bijection above —
  -- no further constraint needed for that branch.
  CHECK (
    tier IS NULL OR tier = 'routine' OR
    (due_not_before IS NULL AND due_not_after IS NOT NULL)
  )
);

-- ═══════════════════════════════════════════════════════════════════════
-- APPOINTMENTS
-- discriminator-column-tables: one table, discriminator column (open/closed).
--
-- OpenAppointment embeds the full TriagedHealthcareRequest in Haskell, but
-- since its constructor is open (no invariant to protect) the DB mirrors
-- this as a foreign key (healthcare_request_id), not denormalized columns
-- — reconstruction is a plain join, no sealed-type-replay needed.
--
-- slot_id is MUTABLE: reassignSlot rebinds an open appointment to a new
-- slot in place — no new appointment row, no close/reopen. This is the
-- live case for transactional-cross-table-consistency: every write that changes slot_id must also update
-- the corresponding slots rows (old -> available, new -> booked) in the
-- SAME transaction. No trigger enforces this agreement — transactional
-- discipline in Persistence.hs is the only guard, by deliberate choice.
--
-- healthcare_request_id is UNIQUE: a given triaged request is consumed by
-- at most one appointment, ever. A failed reassignSlot does not free the
-- request back to waiting — it produces a brand new triage row (see
-- healthcare_requests comment above).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE appointments (
  id                     UUID NOT NULL PRIMARY KEY,
  healthcare_request_id  UUID NOT NULL UNIQUE REFERENCES healthcare_requests(id),
  slot_id                UUID NOT NULL REFERENCES slots(id) DEFERRABLE INITIALLY DEFERRED,

  state                  TEXT NOT NULL CHECK (state IN ('open', 'closed')),

  -- Close-reason columns. NULL while state = 'open'.
  close_reason           TEXT NULL CHECK (close_reason IN ('completed', 'cancelled', 'no_show')),
  closed_by_party        TEXT NULL CHECK (closed_by_party IN ('doctor', 'patient')),

  CHECK (
    (state = 'open'   AND close_reason IS NULL AND closed_by_party IS NULL) OR
    (state = 'closed' AND close_reason = 'completed' AND closed_by_party IS NULL) OR
    (state = 'closed' AND close_reason IN ('cancelled', 'no_show') AND closed_by_party IS NOT NULL)
  )
);

-- Circular FK completion: slots.appointment_id -> appointments(id).
-- Deferred for the same reason as appointments.slot_id above — a single
-- transaction inserts/updates both tables together (transactional-cross-table-consistency).
ALTER TABLE slots
  ADD CONSTRAINT slots_appointment_id_fkey
  FOREIGN KEY (appointment_id) REFERENCES appointments(id)
  DEFERRABLE INITIALLY DEFERRED;