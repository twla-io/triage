-- Derived from src/Domain.hs by the triage-db-codegen skill.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ── Doctor / Patient ─────────────────────────────────────────────────────────

CREATE TABLE doctors (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE patients (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL
);

-- ── Healthcare Service ───────────────────────────────────────────────────────

CREATE TABLE healthcare_services (
  id       UUID PRIMARY KEY,
  name     TEXT NOT NULL,
  -- Duration, whole minutes: QuarterOfAnHour, HalfAnHour, OneHour
  duration SMALLINT NOT NULL CHECK (duration IN (15, 30, 60))
);

-- ── Intake Request ───────────────────────────────────────────────────────────
-- One table for the IntakeRequest sum type; `state` is its constructor.

CREATE TABLE intake_requests (
  state                 TEXT NOT NULL
    CHECK (state IN ('submitted', 'rejected', 'accepted', 'appointed',
                     'withdrawn', 'stale', 'closed')),

  -- SubmittedIntakeRequest (every case)
  id                    UUID PRIMARY KEY,
  patient_id            UUID NOT NULL REFERENCES patients (id),
  narrative             TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL,

  -- RejectedIntakeRequest
  rejected_at           TIMESTAMPTZ,
  rejection_reason      TEXT,

  -- TriagedIntakeRequest
  healthcare_service_id UUID REFERENCES healthcare_services (id),
  -- IntakeRequestPriority's discriminator (Emergency and Urgent set the same
  -- columns)
  priority              TEXT
    CHECK (priority IN ('emergency', 'urgent', 'routine')),
  -- MustBeSeenBy (Emergency, Urgent)
  must_be_seen_by       TIMESTAMPTZ,
  -- RoutineDue (Routine): RoutineNotBefore / RoutineNotAfter / RoutineWithin
  routine_not_before    TIMESTAMPTZ,
  routine_not_after     TIMESTAMPTZ,
  -- DoctorRequirement: SpecificDoctor (set) / AnyDoctor (NULL)
  specific_doctor_id    UUID REFERENCES doctors (id),
  triaged_at            TIMESTAMPTZ,

  -- AppointedIntakeRequest
  doctor_id             UUID REFERENCES doctors (id),
  start                 TIMESTAMPTZ,
  duration              SMALLINT CHECK (duration IN (15, 30, 60)),

  -- WithdrawnIntakeRequest
  withdrawn_at          TIMESTAMPTZ,
  withdrawal_note       TEXT,

  -- StaleIntakeRequest
  stale_at              TIMESTAMPTZ,

  -- ClosedIntakeRequest's CloseReason: Cancelled (Cancellation) / NoShow
  -- (Absence) / Completed (none set)
  cancelled_by          TEXT CHECK (cancelled_by IN ('doctor_party', 'patient_party')),
  cancelled_at          TIMESTAMPTZ,
  cancellation_note     TEXT,
  absent_party          TEXT CHECK (absent_party IN ('doctor_party', 'patient_party')),

  -- ── One CHECK per constructor ──────────────────────────────────────────────

  CONSTRAINT intake_requests_submitted CHECK (state <> 'submitted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NULL AND priority IS NULL
    AND must_be_seen_by IS NULL AND routine_not_before IS NULL
    AND routine_not_after IS NULL AND specific_doctor_id IS NULL
    AND triaged_at IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL
    AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_rejected CHECK (state <> 'rejected' OR (
        rejected_at IS NOT NULL AND rejection_reason IS NOT NULL
    AND healthcare_service_id IS NULL AND priority IS NULL
    AND must_be_seen_by IS NULL AND routine_not_before IS NULL
    AND routine_not_after IS NULL AND specific_doctor_id IS NULL
    AND triaged_at IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL
    AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_accepted CHECK (state <> 'accepted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL
    AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL
    AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_appointed CHECK (state <> 'appointed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL
    AND triaged_at IS NOT NULL
    AND doctor_id IS NOT NULL AND start IS NOT NULL AND duration IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL
    AND cancellation_note IS NULL AND absent_party IS NULL)),

  -- Withdrawn records which stage it came from (WithdrawnFrom): one CHECK
  -- per inner constructor. FromSubmitted is identified by none of
  -- FromAccepted's (TriagedIntakeRequest's) columns being set.
  CONSTRAINT intake_requests_withdrawn_from_submitted CHECK (state <> 'withdrawn'
    OR NOT (    healthcare_service_id IS NULL AND priority IS NULL
            AND must_be_seen_by IS NULL AND routine_not_before IS NULL
            AND routine_not_after IS NULL AND specific_doctor_id IS NULL
            AND triaged_at IS NULL)
    OR (    rejected_at IS NULL AND rejection_reason IS NULL
        AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
        AND withdrawn_at IS NOT NULL
        AND stale_at IS NULL
        AND cancelled_by IS NULL AND cancelled_at IS NULL
        AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_withdrawn_from_accepted CHECK (state <> 'withdrawn'
    OR (    healthcare_service_id IS NULL AND priority IS NULL
        AND must_be_seen_by IS NULL AND routine_not_before IS NULL
        AND routine_not_after IS NULL AND specific_doctor_id IS NULL
        AND triaged_at IS NULL)
    OR (    rejected_at IS NULL AND rejection_reason IS NULL
        AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL
        AND triaged_at IS NOT NULL
        AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
        AND withdrawn_at IS NOT NULL
        AND stale_at IS NULL
        AND cancelled_by IS NULL AND cancelled_at IS NULL
        AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_stale CHECK (state <> 'stale' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL
    AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NOT NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL
    AND cancellation_note IS NULL AND absent_party IS NULL)),

  CONSTRAINT intake_requests_closed CHECK (state <> 'closed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL
    AND triaged_at IS NOT NULL
    AND doctor_id IS NOT NULL AND start IS NOT NULL AND duration IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL)),

  -- ── Nested sum types ───────────────────────────────────────────────────────

  -- IntakeRequestPriority, where its stage is present. RoutineDue needs no
  -- CHECK of its own: every combination of its two columns is a case.
  CONSTRAINT intake_requests_priority CHECK (priority IS NULL
    OR (priority IN ('emergency', 'urgent')
        AND must_be_seen_by IS NOT NULL
        AND routine_not_before IS NULL AND routine_not_after IS NULL)
    OR (priority = 'routine' AND must_be_seen_by IS NULL)),

  -- CloseReason: Completed sets none of its siblings' columns.
  CONSTRAINT intake_requests_close_reason CHECK (
       (    cancelled_by IS NULL AND cancelled_at IS NULL
        AND cancellation_note IS NULL AND absent_party IS NULL)
    OR (    cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL
        AND absent_party IS NULL)
    OR (    absent_party IS NOT NULL
        AND cancelled_by IS NULL AND cancelled_at IS NULL
        AND cancellation_note IS NULL)),

  -- Sealed RoutineWindow: routineNotBefore <= routineNotAfter.
  CONSTRAINT intake_requests_routine_window CHECK (
       routine_not_before IS NULL OR routine_not_after IS NULL
    OR routine_not_before <= routine_not_after)
);

-- ── Slot ─────────────────────────────────────────────────────────────────────

CREATE TABLE available_slots (
  id                    UUID PRIMARY KEY,
  doctor_id             UUID NOT NULL REFERENCES doctors (id),
  healthcare_service_id UUID NOT NULL REFERENCES healthcare_services (id),
  start                 TIMESTAMPTZ NOT NULL,
  duration              SMALLINT NOT NULL CHECK (duration IN (15, 30, 60))
);

-- ── Doctor Calendar ──────────────────────────────────────────────────────────
-- Shadow table for the sealed DoctorCalendar: one row per DoctorCalendarEntry
-- (Slot: an available_slots row; Appointment: an intake_requests row in
-- state 'appointed'). Maintained by the triggers below; the EXCLUDE is the
-- invariant (no two entries of a doctor overlap).

CREATE TABLE doctor_calendar (
  doctor_id         UUID NOT NULL,
  during            TSTZRANGE NOT NULL,
  source            TEXT NOT NULL CHECK (source IN ('slot', 'appointment')),
  slot_id           UUID UNIQUE REFERENCES available_slots (id) ON DELETE CASCADE,
  intake_request_id UUID UNIQUE REFERENCES intake_requests (id),

  CONSTRAINT doctor_calendar_source CHECK (
       (source = 'slot'        AND slot_id IS NOT NULL AND intake_request_id IS NULL)
    OR (source = 'appointment' AND intake_request_id IS NOT NULL AND slot_id IS NULL)),

  CONSTRAINT doctor_calendar_no_overlap
    EXCLUDE USING gist (doctor_id WITH =, during WITH &&)
);

CREATE FUNCTION available_slots_doctor_calendar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO doctor_calendar (doctor_id, during, source, slot_id)
  VALUES (NEW.doctor_id,
          tstzrange(NEW.start, NEW.start + NEW.duration * INTERVAL '1 minute'),
          'slot', NEW.id);
  RETURN NULL;
END;
$$;

-- Slots are never updated; a deleted slot's entry goes by ON DELETE CASCADE.
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
            tstzrange(NEW.start, NEW.start + NEW.duration * INTERVAL '1 minute'),
            'appointment', NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER intake_requests_doctor_calendar
  AFTER INSERT OR UPDATE ON intake_requests
  FOR EACH ROW EXECUTE FUNCTION intake_requests_doctor_calendar();
