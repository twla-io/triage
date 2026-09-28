-- triage: initial schema
-- Derived from src/Domain.hs under the rules in
-- .claude/skills/triage-db-codegen/SKILL.md (rule names cited below).

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTORS / PATIENTS
-- minimal-types-minimal-tables: Doctor and Patient are id + name only.
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
-- Duration is stored in minutes: QuarterOfAnHour | HalfAnHour | OneHour.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE healthcare_services (
  id               UUID NOT NULL PRIMARY KEY,
  name             TEXT NOT NULL,
  duration_minutes SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60))
);

-- ═══════════════════════════════════════════════════════════════════════
-- SLOTS
-- deleted-on-match: AvailableSlot is the only slot type, so a row means
-- "available, not yet matched". No state column and no request reference;
-- matching deletes the row in the same transaction that appoints the
-- request (atomic-multi-table-write).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE slots (
  id                    UUID NOT NULL PRIMARY KEY,
  doctor_id             UUID NOT NULL REFERENCES doctors(id),
  healthcare_service_id UUID NOT NULL REFERENCES healthcare_services(id),
  start_time            TIMESTAMPTZ NOT NULL,
  duration_minutes      SMALLINT NOT NULL CHECK (duration_minutes IN (15, 30, 60))
);

-- ═══════════════════════════════════════════════════════════════════════
-- INTAKE REQUESTS
-- discriminator-column-tables: IntakeRequest's seven cases in one table,
-- discriminated by state; each stage's columns are nullable. Rows are
-- never deleted (no-delete-on-consumption).
--
-- Column groups, by the Domain type that contributes them:
--   base       SubmittedIntakeRequest: id, patient_id, narrative, created_at
--   rejection  Rejected _ UTCTime Text: rejected_at, rejection_reason
--   triage     TriagedIntakeRequest: healthcare_service_id, tier,
--              due_not_before, due_not_after, triaged_at, required_doctor_id
--   appointment AppointedIntakeRequest: appointed_doctor_id, start_time,
--              duration_minutes
--   withdrawal WithdrawnFrom* _ UTCTime (Maybe Text): withdrawn_at,
--              withdrawal_note
--   stale      Stale _ UTCTime: stale_at
--   close      Closed _ CloseReason: close_reason, closed_by_party,
--              cancelled_at, cancellation_note
--
-- One CHECK per constructor shape, written as "state = X implies shape",
-- because Postgres requires every CHECK on a table to hold. Each shape
-- names every column outside the base group: required (IS NOT NULL),
-- absent (IS NULL), or optional. Optional columns are listed in the
-- constraint's comment and are pinned by a nested-type CHECK further
-- down (priority, close reason) or are a Maybe field.
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE intake_requests (
  id                    UUID NOT NULL PRIMARY KEY,
  patient_id            UUID NOT NULL REFERENCES patients(id),
  narrative             TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL,

  state                 TEXT NOT NULL CHECK (state IN
    ('submitted', 'rejected', 'accepted', 'appointed', 'withdrawn', 'stale', 'closed')),

  rejected_at           TIMESTAMPTZ NULL,
  rejection_reason      TEXT NULL,

  healthcare_service_id UUID NULL REFERENCES healthcare_services(id),
  tier                  TEXT NULL CHECK (tier IN ('emergency', 'urgent', 'routine')),
  due_not_before        TIMESTAMPTZ NULL,
  due_not_after         TIMESTAMPTZ NULL,
  triaged_at            TIMESTAMPTZ NULL,
  -- DoctorRequirement (nullability-as-discriminator): NULL = AnyDoctor.
  required_doctor_id    UUID NULL REFERENCES doctors(id),

  appointed_doctor_id   UUID NULL REFERENCES doctors(id),
  start_time            TIMESTAMPTZ NULL,
  duration_minutes      SMALLINT NULL CHECK (duration_minutes IN (15, 30, 60)),

  withdrawn_at          TIMESTAMPTZ NULL,
  withdrawal_note       TEXT NULL,

  stale_at              TIMESTAMPTZ NULL,

  close_reason          TEXT NULL CHECK (close_reason IN ('completed', 'cancelled', 'no_show')),
  closed_by_party       TEXT NULL CHECK (closed_by_party IN ('doctor', 'patient')),
  cancelled_at          TIMESTAMPTZ NULL,
  cancellation_note     TEXT NULL,

  -- Submitted SubmittedIntakeRequest
  CONSTRAINT intake_requests_submitted_shape CHECK (state <> 'submitted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NULL AND tier IS NULL
    AND due_not_before IS NULL AND due_not_after IS NULL
    AND triaged_at IS NULL AND required_doctor_id IS NULL
    AND appointed_doctor_id IS NULL AND start_time IS NULL AND duration_minutes IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Rejected SubmittedIntakeRequest UTCTime Text
  CONSTRAINT intake_requests_rejected_shape CHECK (state <> 'rejected' OR (
        rejected_at IS NOT NULL AND rejection_reason IS NOT NULL
    AND healthcare_service_id IS NULL AND tier IS NULL
    AND due_not_before IS NULL AND due_not_after IS NULL
    AND triaged_at IS NULL AND required_doctor_id IS NULL
    AND appointed_doctor_id IS NULL AND start_time IS NULL AND duration_minutes IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Accepted TriagedIntakeRequest
  -- optional: due_not_before, due_not_after (priority), required_doctor_id
  CONSTRAINT intake_requests_accepted_shape CHECK (state <> 'accepted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL
    AND appointed_doctor_id IS NULL AND start_time IS NULL AND duration_minutes IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Appointed AppointedIntakeRequest
  -- optional: due_not_before, due_not_after (priority), required_doctor_id
  CONSTRAINT intake_requests_appointed_shape CHECK (state <> 'appointed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL
    AND appointed_doctor_id IS NOT NULL AND start_time IS NOT NULL AND duration_minutes IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Withdrawn (WithdrawnFromSubmitted SubmittedIntakeRequest UTCTime (Maybe Text))
  -- Within 'withdrawn', healthcare_service_id IS NULL selects this case
  -- (nullability-as-discriminator).
  -- optional: withdrawal_note
  CONSTRAINT intake_requests_withdrawn_from_submitted_shape CHECK (
    state <> 'withdrawn' OR healthcare_service_id IS NOT NULL OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND tier IS NULL
    AND due_not_before IS NULL AND due_not_after IS NULL
    AND triaged_at IS NULL AND required_doctor_id IS NULL
    AND appointed_doctor_id IS NULL AND start_time IS NULL AND duration_minutes IS NULL
    AND withdrawn_at IS NOT NULL
    AND stale_at IS NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Withdrawn (WithdrawnFromAccepted TriagedIntakeRequest UTCTime (Maybe Text))
  -- Within 'withdrawn', healthcare_service_id IS NOT NULL selects this case.
  -- optional: due_not_before, due_not_after (priority), required_doctor_id,
  --           withdrawal_note
  CONSTRAINT intake_requests_withdrawn_from_accepted_shape CHECK (
    state <> 'withdrawn' OR healthcare_service_id IS NULL OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND tier IS NOT NULL AND triaged_at IS NOT NULL
    AND appointed_doctor_id IS NULL AND start_time IS NULL AND duration_minutes IS NULL
    AND withdrawn_at IS NOT NULL
    AND stale_at IS NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Stale TriagedIntakeRequest UTCTime
  -- optional: due_not_before, due_not_after (priority), required_doctor_id
  CONSTRAINT intake_requests_stale_shape CHECK (state <> 'stale' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL
    AND appointed_doctor_id IS NULL AND start_time IS NULL AND duration_minutes IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NOT NULL
    AND close_reason IS NULL AND closed_by_party IS NULL
    AND cancelled_at IS NULL AND cancellation_note IS NULL)),

  -- Closed AppointedIntakeRequest CloseReason
  -- optional: due_not_before, due_not_after (priority), required_doctor_id,
  --           closed_by_party, cancelled_at, cancellation_note (close reason)
  CONSTRAINT intake_requests_closed_shape CHECK (state <> 'closed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND tier IS NOT NULL AND triaged_at IS NOT NULL
    AND appointed_doctor_id IS NOT NULL AND start_time IS NOT NULL AND duration_minutes IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND close_reason IS NOT NULL)),

  -- IntakeRequestPriority (nullability-as-discriminator). Emergency and
  -- Urgent carry one deadline, in due_not_after. Routine's RoutineDue is
  -- the 2x2 over due_not_before/due_not_after. No tier, no due.
  CONSTRAINT intake_requests_priority_shape CHECK (
       (tier IS NULL AND due_not_before IS NULL AND due_not_after IS NULL)
    OR (tier IN ('emergency', 'urgent') AND due_not_before IS NULL AND due_not_after IS NOT NULL)
    OR  tier = 'routine'),

  -- RoutineWithin's from <= to (mkRoutineWithin).
  CONSTRAINT intake_requests_routine_within_order CHECK (
    due_not_before IS NULL OR due_not_after IS NULL OR due_not_before <= due_not_after),

  -- CloseReason: Completed | Cancelled AppointmentParty UTCTime (Maybe Text)
  --            | NoShow AppointmentParty. Only Cancelled has a time and a
  -- note; no close reason means none of its payload.
  CONSTRAINT intake_requests_close_reason_shape CHECK (
       (close_reason IS NULL
          AND closed_by_party IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL)
    OR (close_reason = 'completed'
          AND closed_by_party IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL)
    OR (close_reason = 'cancelled'
          AND closed_by_party IS NOT NULL AND cancelled_at IS NOT NULL)
    OR (close_reason = 'no_show'
          AND closed_by_party IS NOT NULL AND cancelled_at IS NULL AND cancellation_note IS NULL))
);

-- ═══════════════════════════════════════════════════════════════════════
-- DOCTOR CALENDAR
-- cross-table-invariants-need-a-shadow-table: DoctorCalendar's invariant
-- (a doctor's entries never overlap) spans slots and appointed
-- intake_requests, so both are mirrored here under one EXCLUDE constraint.
-- Intervals are half-open, [start, start + duration), matching
-- Domain.hs; tstzrange's default bounds are [).
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE doctor_calendar (
  doctor_id         UUID NOT NULL,
  during            TSTZRANGE NOT NULL,
  source            TEXT NOT NULL CHECK (source IN ('slot', 'appointment')),
  slot_id           UUID UNIQUE REFERENCES slots(id) ON DELETE CASCADE,
  intake_request_id UUID UNIQUE REFERENCES intake_requests(id),
  CHECK (
    (source = 'slot'        AND slot_id IS NOT NULL AND intake_request_id IS NULL) OR
    (source = 'appointment' AND intake_request_id IS NOT NULL AND slot_id IS NULL)
  ),
  EXCLUDE USING gist (doctor_id WITH =, during WITH &&)
);

-- Inserting a slot adds its interval. Deleting one removes it through
-- slot_id's ON DELETE CASCADE.
CREATE FUNCTION sync_slot_to_doctor_calendar() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO doctor_calendar (doctor_id, during, source, slot_id)
  VALUES (NEW.doctor_id,
          tstzrange(NEW.start_time, NEW.start_time + make_interval(mins => NEW.duration_minutes)),
          'slot', NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER slots_sync_doctor_calendar
  AFTER INSERT ON slots
  FOR EACH ROW EXECUTE FUNCTION sync_slot_to_doctor_calendar();

-- A request's interval exists exactly while it is 'appointed': every insert
-- or update drops the row's interval and re-adds it if the row is appointed.
-- No column list on the trigger, so a change to what "appointed" stores
-- can't be missed.
CREATE FUNCTION sync_intake_request_to_doctor_calendar() RETURNS TRIGGER AS $$
BEGIN
  DELETE FROM doctor_calendar WHERE intake_request_id = NEW.id;
  IF NEW.state = 'appointed' THEN
    INSERT INTO doctor_calendar (doctor_id, during, source, intake_request_id)
    VALUES (NEW.appointed_doctor_id,
            tstzrange(NEW.start_time, NEW.start_time + make_interval(mins => NEW.duration_minutes)),
            'appointment', NEW.id);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER intake_requests_sync_doctor_calendar
  AFTER INSERT OR UPDATE ON intake_requests
  FOR EACH ROW EXECUTE FUNCTION sync_intake_request_to_doctor_calendar();
