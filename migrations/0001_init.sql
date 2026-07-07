-- triage: initial schema
-- Generated from Domain.hs. See SKILL.md (triage-db-codegen) for the rules
-- this schema follows and the reasoning behind each one.

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTORS / PATIENTS
-- minimal-types-minimal-tables: id/name only, no speculative columns.
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
-- encodeDuration in Persistence.hs (fail-loudly-on-decode).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE healthcare_services (
  id               UUID NOT NULL PRIMARY KEY,
  name             TEXT NOT NULL,
  duration_minutes SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60))
);

-- ═══════════════════════════════════════════════════════════════════════
-- SLOTS
-- deleted-on-match: AvailableSlot is the only slot type. A row here means
-- exactly one thing — "available, not yet matched" — nothing else. No
-- state column, no appointment reference: once satisfyHealthcareRequest
-- or reassignSlot matches a row, it is DELETED in the same transaction
-- that writes the appointments row (atomic-multi-table-write), not
-- flagged or transitioned. There is no schema-level record of a slot's
-- existence after it's matched — that fact lives only inside the
-- appointments row it became, with no back-reference.
--
-- Recreating a vacated time after a reassignSlot is NOT automatic —
-- that's a separate, explicit call to insert a new row here, by
-- deliberate choice (mirrors Domain.hs's own refusal to decide this).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE slots (
  id                     UUID NOT NULL PRIMARY KEY,
  doctor_id              UUID NOT NULL REFERENCES doctors(id),
  healthcare_service_id  UUID NOT NULL REFERENCES healthcare_services(id),
  start_time             TIMESTAMPTZ NOT NULL,
  duration_minutes       SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60))
);

-- ═══════════════════════════════════════════════════════════════════════
-- HEALTHCARE REQUESTS
-- Unaffected by the Slot/Appointment redesign — see SKILL.md's
-- discriminator-column-tables, nullability-as-discriminator,
-- ord-ranking-check, and no-delete-on-consumption for the reasoning.
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
  CHECK (
    tier IS NULL OR tier = 'routine' OR
    (due_not_before IS NULL AND due_not_after IS NOT NULL)
  )
);

-- ═══════════════════════════════════════════════════════════════════════
-- APPOINTMENTS
-- discriminator-column-tables: one table, discriminator column
-- (open/closed).
--
-- No FK to slots at all (deleted-on-match) — doctor_id/start_time/
-- duration_minutes are hard-copied directly at matching time, mirroring
-- exactly what OpenAppointment itself hard-copies rather than
-- referencing a slot by id. A matched slot's row is gone by the time
-- this row exists; there is nothing left to join back to.
--
-- healthcare_request_id is UNIQUE: a given triaged request is consumed by
-- at most one appointment, ever (no-delete-on-consumption).
--
-- (doctor_id, start_time) is UNIQUE among OPEN appointments only (partial
-- index) — the actual backstop against two live appointments for the
-- same doctor at the same time, since nothing at slot-creation time
-- cross-checks against existing appointments.
--
-- cancelled_at (nullability-as-discriminator): populated only when
-- close_reason = 'cancelled', mirroring CloseReason's
-- Cancelled AppointmentParty UTCTime — the timestamp of when the
-- cancellation occurred, not validated against start_time (a booking
-- manager's judgment call, recorded as given).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE appointments (
  id                     UUID NOT NULL PRIMARY KEY,
  healthcare_request_id  UUID NOT NULL UNIQUE REFERENCES healthcare_requests(id),

  -- Hard-copied slot facts — no FK, no join, per deleted-on-match.
  doctor_id              UUID NOT NULL REFERENCES doctors(id),
  start_time             TIMESTAMPTZ NOT NULL,
  duration_minutes       SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60)),

  state                  TEXT NOT NULL CHECK (state IN ('open', 'closed')),

  -- Close-reason columns. NULL while state = 'open'.
  close_reason           TEXT NULL CHECK (close_reason IN ('completed', 'cancelled', 'no_show')),
  closed_by_party        TEXT NULL CHECK (closed_by_party IN ('doctor', 'patient')),
  cancelled_at           TIMESTAMPTZ NULL,

  CHECK (
    (state = 'open'   AND close_reason IS NULL AND closed_by_party IS NULL AND cancelled_at IS NULL) OR
    (state = 'closed' AND close_reason = 'completed' AND closed_by_party IS NULL AND cancelled_at IS NULL) OR
    (state = 'closed' AND close_reason = 'cancelled' AND closed_by_party IS NOT NULL AND cancelled_at IS NOT NULL) OR
    (state = 'closed' AND close_reason = 'no_show'   AND closed_by_party IS NOT NULL AND cancelled_at IS NULL)
  )
);

-- Backstop against two live appointments for the same doctor at the same
-- time — see comment above.
CREATE UNIQUE INDEX appointments_doctor_start_open_key
  ON appointments (doctor_id, start_time)
  WHERE state = 'open';