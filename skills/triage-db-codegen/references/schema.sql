# Worked Example: Full Schema

A complete, worked-through example of applying every rule in `SKILL.md` to the current `Domain.hs`. This is **illustrative reference material, not the live schema** — when actually generating or updating the database, derive the schema fresh from `Domain.hs` each time (per the rules in `SKILL.md`) and write the result to the project's real migration files, not here. This file may go stale as `Domain.hs` evolves; that's acceptable, since its job is teaching the pattern, not being authoritative.

```sql
CREATE TABLE doctors (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE patients (
  id   UUID PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE services (
  id               UUID PRIMARY KEY,
  name             TEXT NOT NULL,
  duration_minutes INT NOT NULL CHECK (duration_minutes IN (30, 60))
);

CREATE TABLE slots (
  id               UUID PRIMARY KEY,
  doctor_id        UUID NOT NULL REFERENCES doctors(id),
  service_id       UUID NOT NULL REFERENCES services(id),
  start_time       TIMESTAMPTZ NOT NULL,
  duration_minutes INT NOT NULL CHECK (duration_minutes IN (30, 60)),

  state            TEXT NOT NULL CHECK (state IN ('pending', 'available', 'booked')),
  appointment_id   UUID REFERENCES appointments(id),

  CHECK (
    (state = 'pending'   AND appointment_id IS NULL) OR
    (state = 'available' AND appointment_id IS NULL) OR
    (state = 'booked'    AND appointment_id IS NOT NULL)
  )
);

CREATE TABLE appointment_requests (
  id              UUID PRIMARY KEY,
  patient_id      UUID NOT NULL REFERENCES patients(id),
  service_id      UUID NOT NULL REFERENCES services(id),
  created_at      TIMESTAMPTZ NOT NULL,

  priority        SMALLINT NOT NULL CHECK (priority IN (0, 1, 2)),  -- 0=Emergency, 1=Urgent, 2=Routine

  -- Routine only:
  doctor_id       UUID REFERENCES doctors(id),
  due_not_before  TIMESTAMPTZ,
  due_not_after   TIMESTAMPTZ,

  CHECK (
    priority = 2 OR  -- Routine
    (doctor_id IS NULL AND due_not_before IS NULL AND due_not_after IS NULL)
  ),
  CHECK (
    due_not_before IS NULL OR due_not_after IS NULL OR due_not_before <= due_not_after
  )
);

CREATE TABLE appointments (
  id           UUID PRIMARY KEY,
  patient_id   UUID NOT NULL REFERENCES patients(id),
  slot_id      UUID NOT NULL REFERENCES slots(id),
  priority     SMALLINT NOT NULL CHECK (priority IN (0, 1, 2)),

  state        TEXT NOT NULL CHECK (state IN ('open', 'closed')),

  -- Closed only:
  close_reason TEXT CHECK (close_reason IN ('completed', 'cancelled', 'rescheduled', 'no_show')),
  closed_by    TEXT CHECK (closed_by IN ('doctor', 'patient')),

  CHECK (
    (state = 'open'   AND close_reason IS NULL                                  AND closed_by IS NULL) OR
    (state = 'closed' AND close_reason = 'completed'                            AND closed_by IS NULL) OR
    (state = 'closed' AND close_reason IN ('cancelled','rescheduled','no_show') AND closed_by IS NOT NULL)
  )
);
```

## Notes on specific decisions

- **`priority` is `SMALLINT`, not `TEXT`**, on both `appointment_requests` and `appointments` — see Rule 2 in `SKILL.md`. `TEXT` would sort alphabetically (`'emergency' < 'routine' < 'urgent'`), disagreeing with the actual `Ord AppointmentPriority` ranking (`Emergency < Urgent < Routine`).
- **`duration_minutes` is `INT`, not a `TEXT` constructor name**, on `services` and `slots` — chosen for the same reason as `priority`, even though `Duration` doesn't derive `Ord`: the integer carries real semantic value (it's used in arithmetic, e.g. computing a slot's end time) that the constructor name doesn't.
- **No `declined_by` join table** — `PendingSlot.declinedBy` was removed entirely along with the offer mechanism (see `Domain.hs`'s comment on `PendingSlot`). Rule 3 is kept in `SKILL.md` for a future multi-valued field, but nothing in the current schema needs it.
- **No `offered_to`/`offered_slot_id` columns, no cross-table trigger** — the entire offer mechanism (`OfferedSlot`, `AppointmentRequestWithOffer`, `giveOffer`, `accept`) was removed from `Domain.hs`. A waitlist match now commits directly via `assignAppointment`; there's no intermediate state, and no second copy of a cross-table reference to keep consistent.
- **`appointment_requests` rows are deleted, not flagged, on consumption** — see Rule 9. A request either exists (waiting) or doesn't (consumed into an `Appointment`); there's no terminal state to represent with a column.
- **`doctors`/`patients` are intentionally minimal** — see Rule 7. Expect these tables to be replaced or federated with an external system later; don't grow them speculatively in the meantime.
