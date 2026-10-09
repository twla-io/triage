-- Derived from src/Domain.hs (triage-db-codegen).

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ── Doctor ──────────────────────────────────────────────────────────────────

CREATE TABLE doctors (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL,
  CONSTRAINT doctors_name CHECK (name ~ '[^[:space:]]')
);

-- ── Patient ─────────────────────────────────────────────────────────────────

CREATE TABLE patients (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL,
  CONSTRAINT patients_name CHECK (name ~ '[^[:space:]]')
);

-- ── HealthcareService ───────────────────────────────────────────────────────

CREATE TABLE healthcare_services (
  id       UUID PRIMARY KEY,
  name     TEXT NOT NULL,
  duration SMALLINT NOT NULL,
  CONSTRAINT healthcare_services_name     CHECK (name ~ '[^[:space:]]'),
  CONSTRAINT healthcare_services_duration CHECK (duration IN (15, 30, 60))
);

-- ── AvailableSlot ───────────────────────────────────────────────────────────

CREATE TABLE available_slots (
  id                    UUID PRIMARY KEY,
  doctor_id             UUID NOT NULL REFERENCES doctors (id),
  healthcare_service_id UUID NOT NULL REFERENCES healthcare_services (id),
  start                 TIMESTAMPTZ NOT NULL,
  duration              SMALLINT NOT NULL,
  CONSTRAINT available_slots_duration CHECK (duration IN (15, 30, 60))
);

-- ── IntakeRequest ───────────────────────────────────────────────────────────
-- One table for the sum type; `state` is its discriminator. Nested sum types:
--   IntakeRequestPriority — discriminator `priority` (Emergency and Urgent set
--     the same column, must_be_seen_by);
--   RoutineDue, DoctorRequirement, CloseReason, WithdrawnFrom — told apart by
--     which columns are set.

CREATE TABLE intake_requests (
  -- SubmittedIntakeRequest
  id                    UUID PRIMARY KEY,
  state                 TEXT NOT NULL,
  patient_id            UUID NOT NULL REFERENCES patients (id),
  narrative             TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL,
  -- RejectedIntakeRequest
  rejected_at           TIMESTAMPTZ,
  rejection_reason      TEXT,
  -- TriagedIntakeRequest
  healthcare_service_id UUID REFERENCES healthcare_services (id),
  priority              TEXT,
  must_be_seen_by       TIMESTAMPTZ,
  routine_not_before    TIMESTAMPTZ,
  routine_not_after     TIMESTAMPTZ,
  specific_doctor_id    UUID REFERENCES doctors (id),
  triaged_at            TIMESTAMPTZ,
  -- AppointedIntakeRequest
  doctor_id             UUID REFERENCES doctors (id),
  start                 TIMESTAMPTZ,
  duration              SMALLINT,
  -- WithdrawnIntakeRequest
  withdrawn_at          TIMESTAMPTZ,
  withdrawal_note       TEXT,
  -- StaleIntakeRequest
  stale_at              TIMESTAMPTZ,
  -- ClosedIntakeRequest (CloseReason)
  cancelled_by          TEXT,
  cancelled_at          TIMESTAMPTZ,
  cancellation_note     TEXT,
  absent_party          TEXT,

  CONSTRAINT intake_requests_state CHECK (
    state IN ('submitted', 'rejected', 'accepted', 'appointed', 'withdrawn', 'stale', 'closed')),
  CONSTRAINT intake_requests_duration CHECK (duration IN (15, 30, 60)),
  CONSTRAINT intake_requests_cancelled_by CHECK (cancelled_by IN ('doctor_party', 'patient_party')),
  CONSTRAINT intake_requests_absent_party CHECK (absent_party IN ('doctor_party', 'patient_party')),

  -- One CHECK per constructor.
  CONSTRAINT intake_requests_submitted CHECK (state <> 'submitted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NULL AND priority IS NULL AND must_be_seen_by IS NULL
    AND routine_not_before IS NULL AND routine_not_after IS NULL AND specific_doctor_id IS NULL
    AND triaged_at IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_rejected CHECK (state <> 'rejected' OR (
        rejected_at IS NOT NULL AND rejection_reason IS NOT NULL
    AND healthcare_service_id IS NULL AND priority IS NULL AND must_be_seen_by IS NULL
    AND routine_not_before IS NULL AND routine_not_after IS NULL AND specific_doctor_id IS NULL
    AND triaged_at IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_accepted CHECK (state <> 'accepted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_appointed CHECK (state <> 'appointed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NOT NULL AND start IS NOT NULL AND duration IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  -- Withdrawn: one CHECK per inner constructor of WithdrawnFrom. FromAccepted
  -- is identified by its TriagedIntakeRequest columns being set; FromSubmitted
  -- by none of them being set.
  CONSTRAINT intake_requests_withdrawn_from_submitted CHECK (state <> 'withdrawn'
    OR healthcare_service_id IS NOT NULL OR priority IS NOT NULL OR triaged_at IS NOT NULL
    OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND must_be_seen_by IS NULL AND routine_not_before IS NULL AND routine_not_after IS NULL
    AND specific_doctor_id IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NOT NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_withdrawn_from_accepted CHECK (state <> 'withdrawn'
    OR (healthcare_service_id IS NULL AND priority IS NULL AND triaged_at IS NULL)
    OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NOT NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_stale CHECK (state <> 'stale' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NOT NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_closed CHECK (state <> 'closed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NOT NULL AND start IS NOT NULL AND duration IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL)),

  -- IntakeRequestPriority: discriminated by `priority`. Within Routine,
  -- RoutineDue is told apart by which of routine_not_before /
  -- routine_not_after are set; every combination is valid, so it has no CHECK
  -- of its own.
  CONSTRAINT intake_requests_priority CHECK (priority IS NULL
    OR (priority IN ('emergency', 'urgent')
        AND must_be_seen_by IS NOT NULL
        AND routine_not_before IS NULL AND routine_not_after IS NULL)
    OR (priority = 'routine'
        AND must_be_seen_by IS NULL)),

  -- RoutineWindow (sealed): routineNotBefore <= routineNotAfter.
  CONSTRAINT intake_requests_routine_window CHECK (
    routine_not_before IS NULL OR routine_not_after IS NULL
    OR routine_not_before <= routine_not_after),

  -- CloseReason: Completed sets none; Cancelled sets cancelled_by and
  -- cancelled_at (cancellation_note optional); NoShow sets absent_party.
  CONSTRAINT intake_requests_close_reason CHECK (state <> 'closed'
    OR (cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
        AND absent_party IS NULL)
    OR (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL
        AND absent_party IS NULL)
    OR (absent_party IS NOT NULL
        AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL))
);

-- ── DoctorCalendar (shadow table) ───────────────────────────────────────────
-- One row per DoctorCalendarEntry: each available slot (Slot) and each
-- intake request while it is Appointed (Appointment). Maintained by the
-- triggers below; the EXCLUDE is the sealed type's no-overlap invariant.

CREATE TABLE doctor_calendar (
  doctor_id         UUID NOT NULL,
  during            TSTZRANGE NOT NULL,
  source            TEXT NOT NULL,
  slot_id           UUID UNIQUE REFERENCES available_slots (id) ON DELETE CASCADE,
  intake_request_id UUID UNIQUE REFERENCES intake_requests (id),

  CONSTRAINT doctor_calendar_source CHECK (
       (source = 'slot'        AND slot_id IS NOT NULL AND intake_request_id IS NULL)
    OR (source = 'appointment' AND intake_request_id IS NOT NULL AND slot_id IS NULL)),

  CONSTRAINT doctor_calendar_no_overlap EXCLUDE USING gist (doctor_id WITH =, during WITH &&)
);

CREATE FUNCTION available_slots_doctor_calendar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO doctor_calendar (doctor_id, during, source, slot_id)
  VALUES (NEW.doctor_id,
          tstzrange(NEW.start, NEW.start + make_interval(mins => NEW.duration)),
          'slot',
          NEW.id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER available_slots_doctor_calendar
  AFTER INSERT ON available_slots
  FOR EACH ROW EXECUTE FUNCTION available_slots_doctor_calendar();

CREATE FUNCTION intake_requests_doctor_calendar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    DELETE FROM doctor_calendar WHERE intake_request_id = OLD.id;
  END IF;
  IF NEW.state = 'appointed' THEN
    INSERT INTO doctor_calendar (doctor_id, during, source, intake_request_id)
    VALUES (NEW.doctor_id,
            tstzrange(NEW.start, NEW.start + make_interval(mins => NEW.duration)),
            'appointment',
            NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER intake_requests_doctor_calendar
  AFTER INSERT OR UPDATE ON intake_requests
  FOR EACH ROW EXECUTE FUNCTION intake_requests_doctor_calendar();
