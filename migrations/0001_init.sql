-- Schema derived from src/Domain.hs by triage-db-codegen.
-- Every table and column name traces back to a Domain.hs name.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ── Doctor ────────────────────────────────────────────────────────────────
CREATE TABLE doctors (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL
);

-- ── Patient ───────────────────────────────────────────────────────────────
CREATE TABLE patients (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL
);

-- ── HealthcareService ─────────────────────────────────────────────────────
-- duration: Duration, whole minutes of durationToNominalDiffTime over
-- [minBound .. maxBound] (QuarterOfAnHour, HalfAnHour, OneHour).
CREATE TABLE healthcare_services (
  id       UUID PRIMARY KEY,
  name     TEXT NOT NULL,
  duration SMALLINT NOT NULL,
  CONSTRAINT healthcare_services_duration CHECK (duration IN (15, 30, 60))
);

-- ── AvailableSlot ─────────────────────────────────────────────────────────
-- Deleted when matched (deleted-on-match); never updated.
CREATE TABLE available_slots (
  id                    UUID PRIMARY KEY,
  doctor_id             UUID NOT NULL REFERENCES doctors (id),
  healthcare_service_id UUID NOT NULL REFERENCES healthcare_services (id),
  start                 TIMESTAMPTZ NOT NULL,
  duration              SMALLINT NOT NULL,
  CONSTRAINT available_slots_duration CHECK (duration IN (15, 30, 60))
);

-- ── IntakeRequest ─────────────────────────────────────────────────────────
-- One table for the sum type; `state` is its discriminator. Every case's
-- values are columns, flattened from the stage records with no prefix.
--
-- Classification (R required, N NULL, o optional; columns NOT NULL in the
-- table are omitted):
--
--   column                 sub rej acc app wd/sub wd/acc sta clo
--   rejected_at             N   R   N   N    N      N     N   N
--   rejection_reason        N   R   N   N    N      N     N   N
--   healthcare_service_id   N   N   R   R    N      R     R   R
--   priority                N   N   R   R    N      R     R   R   (IntakeRequestPriority discriminator)
--   must_be_seen_by         N   N   o   o    N      o     o   o   (IntakeRequestPriority)
--   routine_not_before      N   N   o   o    N      o     o   o   (RoutineDue)
--   routine_not_after       N   N   o   o    N      o     o   o   (RoutineDue)
--   specific_doctor_id      N   N   o   o    N      o     o   o   (DoctorRequirement)
--   triaged_at              N   N   R   R    N      R     R   R
--   doctor_id               N   N   N   R    N      N     N   R
--   start                   N   N   N   R    N      N     N   R
--   duration                N   N   N   R    N      N     N   R
--   withdrawn_at            N   N   N   N    R      R     N   N
--   withdrawal_note         N   N   N   N    o      o     N   N
--   stale_at                N   N   N   N    N      N     R   N
--   cancelled_by            N   N   N   N    N      N     N   o   (CloseReason)
--   cancelled_at            N   N   N   N    N      N     N   o   (CloseReason)
--   cancellation_note       N   N   N   N    N      N     N   o   (CloseReason)
--   absent_party            N   N   N   N    N      N     N   o   (CloseReason)
--
-- Nested sum types:
--   IntakeRequestPriority: Emergency and Urgent set the same column, so it
--     has a discriminator column, `priority` (the field holding it).
--   RoutineDue: told apart by which of routine_not_before/routine_not_after
--     are set; every combination is valid, so no CHECK of its own (beyond
--     RoutineWindow's sealed invariant).
--   DoctorRequirement: AnyDoctor sets nothing, SpecificDoctor sets
--     specific_doctor_id; every combination is valid, so no CHECK.
--   WithdrawnFrom: FromSubmitted sets none of the triaged columns,
--     FromAccepted sets them; one CHECK per inner constructor.
--   CloseReason: Completed sets none, Cancelled sets cancelled_by and
--     cancelled_at, NoShow sets absent_party; no discriminator column.
CREATE TABLE intake_requests (
  -- SubmittedIntakeRequest (required in every case)
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
  -- ClosedIntakeRequest (CloseReason: Cancellation, Absence)
  cancelled_by          TEXT,
  cancelled_at          TIMESTAMPTZ,
  cancellation_note     TEXT,
  absent_party          TEXT,

  CONSTRAINT intake_requests_state CHECK (state IN
    ('submitted', 'rejected', 'accepted', 'appointed', 'withdrawn', 'stale', 'closed')),
  CONSTRAINT intake_requests_duration CHECK (duration IN (15, 30, 60)),
  CONSTRAINT intake_requests_cancelled_by CHECK (cancelled_by IN ('doctor_party', 'patient_party')),
  CONSTRAINT intake_requests_absent_party CHECK (absent_party IN ('doctor_party', 'patient_party')),

  -- ── one CHECK per constructor ──────────────────────────────────────────
  CONSTRAINT intake_requests_submitted CHECK (state <> 'submitted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NULL AND priority IS NULL AND must_be_seen_by IS NULL
    AND routine_not_before IS NULL AND routine_not_after IS NULL
    AND specific_doctor_id IS NULL AND triaged_at IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  CONSTRAINT intake_requests_rejected CHECK (state <> 'rejected' OR (
        rejected_at IS NOT NULL AND rejection_reason IS NOT NULL
    AND healthcare_service_id IS NULL AND priority IS NULL AND must_be_seen_by IS NULL
    AND routine_not_before IS NULL AND routine_not_after IS NULL
    AND specific_doctor_id IS NULL AND triaged_at IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  CONSTRAINT intake_requests_accepted CHECK (state <> 'accepted' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  CONSTRAINT intake_requests_appointed CHECK (state <> 'appointed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NOT NULL AND start IS NOT NULL AND duration IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  -- Withdrawn records its source stage (WithdrawnFrom): one CHECK per inner
  -- constructor. FromSubmitted is identified by none of FromAccepted's
  -- columns being set; FromAccepted by any of them being set.
  CONSTRAINT intake_requests_withdrawn_from_submitted CHECK (state <> 'withdrawn'
    OR healthcare_service_id IS NOT NULL OR priority IS NOT NULL OR triaged_at IS NOT NULL
    OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND must_be_seen_by IS NULL
    AND routine_not_before IS NULL AND routine_not_after IS NULL
    AND specific_doctor_id IS NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NOT NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  CONSTRAINT intake_requests_withdrawn_from_accepted CHECK (state <> 'withdrawn'
    OR (healthcare_service_id IS NULL AND priority IS NULL AND triaged_at IS NULL)
    OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NOT NULL
    AND stale_at IS NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  CONSTRAINT intake_requests_stale CHECK (state <> 'stale' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NULL AND start IS NULL AND duration IS NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NOT NULL
    AND cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
    AND absent_party IS NULL)),

  CONSTRAINT intake_requests_closed CHECK (state <> 'closed' OR (
        rejected_at IS NULL AND rejection_reason IS NULL
    AND healthcare_service_id IS NOT NULL AND priority IS NOT NULL AND triaged_at IS NOT NULL
    AND doctor_id IS NOT NULL AND start IS NOT NULL AND duration IS NOT NULL
    AND withdrawn_at IS NULL AND withdrawal_note IS NULL
    AND stale_at IS NULL)),

  -- ── nested sum types ───────────────────────────────────────────────────
  -- IntakeRequestPriority, where its stage (TriagedIntakeRequest) is present.
  CONSTRAINT intake_requests_priority CHECK (priority IS NULL
    OR (priority = 'emergency' AND must_be_seen_by IS NOT NULL
        AND routine_not_before IS NULL AND routine_not_after IS NULL)
    OR (priority = 'urgent' AND must_be_seen_by IS NOT NULL
        AND routine_not_before IS NULL AND routine_not_after IS NULL)
    OR (priority = 'routine' AND must_be_seen_by IS NULL)),

  -- CloseReason, where its stage (ClosedIntakeRequest) is present.
  CONSTRAINT intake_requests_close_reason CHECK (state <> 'closed'
    OR (cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
        AND absent_party IS NULL)
    OR (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL
        AND absent_party IS NULL)
    OR (cancelled_by IS NULL AND cancelled_at IS NULL AND cancellation_note IS NULL
        AND absent_party IS NOT NULL)),

  -- RoutineWindow (sealed): routineNotBefore <= routineNotAfter.
  CONSTRAINT intake_requests_routine_window CHECK (routine_not_before IS NULL
    OR routine_not_after IS NULL OR routine_not_before <= routine_not_after)
);

-- ── DoctorCalendar (shadow table) ─────────────────────────────────────────
-- One row per DoctorCalendarEntry: an available_slots row (Slot) or an
-- intake_requests row in state 'appointed' (Appointment). Maintained by the
-- triggers below; enforces DoctorCalendar's invariant (no two entries of a
-- doctor overlap). Intervals are half-open [start, end), tstzrange's default.
-- Never read by the application.
CREATE TABLE doctor_calendar (
  doctor_id         UUID NOT NULL,
  during            TSTZRANGE NOT NULL,
  source            TEXT NOT NULL,
  slot_id           UUID UNIQUE REFERENCES available_slots (id) ON DELETE CASCADE,
  intake_request_id UUID UNIQUE REFERENCES intake_requests (id),
  CONSTRAINT doctor_calendar_source CHECK (
       (source = 'slot'        AND slot_id IS NOT NULL AND intake_request_id IS NULL)
    OR (source = 'appointment' AND slot_id IS NULL     AND intake_request_id IS NOT NULL)),
  CONSTRAINT doctor_calendar_no_overlap
    EXCLUDE USING gist (doctor_id WITH =, during WITH &&)
);

-- A slot is inserted, never updated; its deletion cascades.
CREATE FUNCTION available_slots_doctor_calendar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO doctor_calendar (doctor_id, during, source, slot_id)
  VALUES (NEW.doctor_id,
          tstzrange(NEW.start, NEW.start + NEW.duration * INTERVAL '1 minute'),
          'slot', NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER available_slots_doctor_calendar
AFTER INSERT ON available_slots
FOR EACH ROW EXECUTE FUNCTION available_slots_doctor_calendar();

-- An intake request is an entry exactly while its case is Appointed
-- (Closed only embeds it).
CREATE FUNCTION intake_requests_doctor_calendar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM doctor_calendar WHERE intake_request_id = NEW.id;
  IF NEW.state = 'appointed' THEN
    INSERT INTO doctor_calendar (doctor_id, during, source, intake_request_id)
    VALUES (NEW.doctor_id,
            tstzrange(NEW.start, NEW.start + NEW.duration * INTERVAL '1 minute'),
            'appointment', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER intake_requests_doctor_calendar
AFTER INSERT OR UPDATE ON intake_requests
FOR EACH ROW EXECUTE FUNCTION intake_requests_doctor_calendar();
