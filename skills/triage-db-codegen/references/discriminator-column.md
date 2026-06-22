# DB Strategy: Discriminator Column

One table per aggregate. A `kind`/`status` discriminator column selects which constructor the row represents; columns specific to one constructor are nullable and only populated when relevant.

## Example: `Slot`

```sql
CREATE TABLE slots (
  id          UUID PRIMARY KEY,
  doctor_id   UUID NOT NULL REFERENCES doctors(id),
  service_id  UUID NOT NULL REFERENCES services(id),
  start_time  TIMESTAMPTZ NOT NULL,
  duration_minutes INT NOT NULL,

  kind        TEXT NOT NULL CHECK (kind IN ('pending', 'offered', 'available', 'booked')),

  -- Pending only:
  declined_by UUID[] DEFAULT NULL,

  -- Offered only:
  offered_to  UUID REFERENCES waitlist_entries(id) DEFAULT NULL,

  -- Booked only:
  appointment_id UUID REFERENCES appointments(id) DEFAULT NULL
);
```

A row with `kind = 'available'` has `declined_by`, `offered_to`, and `appointment_id` all `NULL`. A row with `kind = 'booked'` has `appointment_id` set and the other two `NULL`.

## Trade-offs

**Pros:**
- Simple migrations — one `ALTER TABLE` per new field, no new tables.
- One query (`SELECT * FROM slots WHERE id = ?`) always gets the full picture.
- Easy to add a partial index per state (e.g. `WHERE kind = 'available'`) for fast "find open slots" queries.

**Cons:**
- Nullable columns proliferate as the sum type grows more constructors/payloads.
- No DB-level guarantee that `offered_to` is only set when `kind = 'offered'` — that invariant lives in application code or a `CHECK` constraint you maintain by hand.
- A wide table with mostly-NULL columns can be harder to read at a glance.

## When to choose this

Best when the sum type has few constructors, the state-specific payloads are small (a foreign key or two, not many fields), and the team values simple migrations and single-query reads over strict schema-level invariants.
