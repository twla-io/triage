-- triage: initial schema
-- Generated from Domain.hs. See SKILL.md (triage-db-codegen) for the rules
-- this schema follows and the reasoning behind each one. This is the
-- initial schema for the current IntakeRequest-based domain model — no
-- prior schema has ever been deployed against this database.

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
-- state column, no appointment reference: once matchIntakeRequestToSlot
-- or reassignIntakeRequestSlot matches a row, it is DELETED in the same
-- transaction that updates the intake_requests row
-- (atomic-multi-table-write), not flagged or transitioned. There is no
-- schema-level record of a slot's existence after it's matched — that
-- fact lives only inside the intake_requests row it became, with no
-- back-reference.
--
-- Recreating a vacated time after a reassignIntakeRequestSlot is NOT
-- automatic — that's a separate, explicit call to insert a new row here,
-- by deliberate choice (mirrors Domain.hs's own refusal to decide this).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE slots (
  id                     UUID NOT NULL PRIMARY KEY,
  doctor_id              UUID NOT NULL REFERENCES doctors(id),
  healthcare_service_id  UUID NOT NULL REFERENCES healthcare_services(id),
  start_time             TIMESTAMPTZ NOT NULL,
  duration_minutes       SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60))
);

-- ═══════════════════════════════════════════════════════════════════════
-- INTAKE REQUESTS
-- discriminator-column-tables: one table, one state column, six values
-- (submitted/rejected/accepted/appointed/withdrawn/closed) — mirroring
-- Domain.hs's IntakeRequest sum type exactly, one identity
-- (IntakeRequestId) throughout. IntakeRequest folds what would otherwise
-- be a separate Appointment aggregate into itself, since the two are
-- permanently 1:1.
--
-- No FK to slots at all (deleted-on-match) — appointed_doctor_id/
-- start_time/duration_minutes are hard-copied directly at matching time,
-- mirroring exactly what AppointedIntakeRequest itself hard-copies rather
-- than referencing a slot by id.
--
-- healthcare_service_id doubles as the discriminator between
-- WithdrawnFromSubmitted (NULL — withdrawn before triage) and
-- WithdrawnFromAccepted (NOT NULL — withdrawn after triage) within
-- state = 'withdrawn'. Deliberate, not an oversight: no separate
-- sub-state column, reusing the same nullability-as-discriminator
-- convention already used elsewhere in this schema (required_doctor_id,
-- due_not_before/due_not_after).
--
-- cancellation_note (nullability-as-discriminator): populated only
-- optionally alongside close_reason = 'cancelled', mirroring
-- CloseReason's Cancelled AppointmentParty UTCTime (Maybe Text) — an
-- optional free-text note, independent of whether closed_by_party/
-- cancelled_at are set.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE intake_requests (
  id                     UUID NOT NULL PRIMARY KEY,
  patient_id             UUID NOT NULL REFERENCES patients(id),
  narrative              TEXT NOT NULL,
  required_doctor_id     UUID NULL REFERENCES doctors(id),  -- NULL = AnyDoctor
  created_at             TIMESTAMPTZ NOT NULL,

  state                  TEXT NOT NULL CHECK (state IN
    ('submitted', 'rejected', 'accepted', 'appointed', 'withdrawn', 'closed')),

  rejected_at            TIMESTAMPTZ NULL,
  rejection_reason       TEXT NULL,

  healthcare_service_id  UUID NULL REFERENCES healthcare_services(id),
  tier                   TEXT NULL CHECK (tier IN ('emergency', 'urgent', 'routine')),
  due_not_before         TIMESTAMPTZ NULL,
  due_not_after          TIMESTAMPTZ NULL,
  triaged_at             TIMESTAMPTZ NULL,

  appointed_doctor_id    UUID NULL REFERENCES doctors(id),
  start_time             TIMESTAMPTZ NULL,
  duration_minutes       SMALLINT NULL CHECK (duration_minutes IN (15, 30, 60)),

  withdrawn_at           TIMESTAMPTZ NULL,
  withdrawal_note        TEXT NULL,

  close_reason           TEXT NULL CHECK (close_reason IN ('completed', 'cancelled', 'no_show')),
  closed_by_party        TEXT NULL CHECK (closed_by_party IN ('doctor', 'patient')),
  cancelled_at           TIMESTAMPTZ NULL,
  cancellation_note      TEXT NULL,

  CHECK (
    (state = 'submitted' AND
       rejected_at IS NULL AND healthcare_service_id IS NULL AND
       appointed_doctor_id IS NULL AND withdrawn_at IS NULL AND close_reason IS NULL)
    OR
    (state = 'rejected' AND
       rejected_at IS NOT NULL AND rejection_reason IS NOT NULL AND
       healthcare_service_id IS NULL AND appointed_doctor_id IS NULL AND
       withdrawn_at IS NULL AND close_reason IS NULL)
    OR
    (state = 'accepted' AND
       healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL AND
       rejected_at IS NULL AND appointed_doctor_id IS NULL AND
       withdrawn_at IS NULL AND close_reason IS NULL)
    OR
    (state = 'appointed' AND
       healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL AND
       appointed_doctor_id IS NOT NULL AND start_time IS NOT NULL AND duration_minutes IS NOT NULL AND
       rejected_at IS NULL AND withdrawn_at IS NULL AND close_reason IS NULL)
    OR
    (state = 'withdrawn' AND
       withdrawn_at IS NOT NULL AND
       rejected_at IS NULL AND appointed_doctor_id IS NULL AND close_reason IS NULL)
    OR
    (state = 'closed' AND
       healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL AND
       appointed_doctor_id IS NOT NULL AND start_time IS NOT NULL AND duration_minutes IS NOT NULL AND
       close_reason IS NOT NULL AND
       rejected_at IS NULL AND withdrawn_at IS NULL)
  ),

  -- Emergency/Urgent: exactly one deadline (due_not_after), never a window.
  CHECK (
    tier IS NULL OR tier = 'routine' OR
    (due_not_before IS NULL AND due_not_after IS NOT NULL)
  ),

  CHECK (
    close_reason IS NULL OR
    (close_reason = 'completed' AND closed_by_party IS NULL AND cancelled_at IS NULL) OR
    (close_reason = 'cancelled' AND closed_by_party IS NOT NULL AND cancelled_at IS NOT NULL) OR
    (close_reason = 'no_show'   AND closed_by_party IS NOT NULL AND cancelled_at IS NULL)
  )
);

-- Backstop against two live appointments for the same doctor at the same
-- time — the actual guard, since nothing at slot-creation time
-- cross-checks against existing appointed rows.
CREATE UNIQUE INDEX intake_requests_doctor_start_appointed_key
  ON intake_requests (appointed_doctor_id, start_time)
  WHERE state = 'appointed';
