# DB Strategy: Side Tables Per State

One table for the shared fields, one side table per state-specific payload, joined on `id`. No nullable columns anywhere — a row's mere existence in a side table tells you the state.

## Example: `Slot`

```sql
CREATE TABLE slot_details (
  id          UUID PRIMARY KEY,
  doctor_id   UUID NOT NULL REFERENCES doctors(id),
  service_id  UUID NOT NULL REFERENCES services(id),
  start_time  TIMESTAMPTZ NOT NULL,
  duration_minutes INT NOT NULL
);

-- Exactly one of these four has a row for a given slot_details.id:

CREATE TABLE pending_slots (
  slot_id UUID PRIMARY KEY REFERENCES slot_details(id)
);

CREATE TABLE pending_slot_declines (
  slot_id           UUID NOT NULL REFERENCES pending_slots(slot_id),
  waitlist_entry_id UUID NOT NULL REFERENCES waitlist_entries(id),
  PRIMARY KEY (slot_id, waitlist_entry_id)
);

CREATE TABLE offered_slots (
  slot_id   UUID PRIMARY KEY REFERENCES slot_details(id),
  offered_to UUID NOT NULL REFERENCES waitlist_entries(id)
);

CREATE TABLE available_slots (
  slot_id UUID PRIMARY KEY REFERENCES slot_details(id)
);

CREATE TABLE booked_slots (
  slot_id        UUID PRIMARY KEY REFERENCES slot_details(id),
  appointment_id UUID NOT NULL REFERENCES appointments(id)
);
```

A transition like `bookSlot` becomes: `DELETE FROM available_slots WHERE slot_id = ?` + `INSERT INTO booked_slots ...`, in one transaction. The DB itself prevents the same slot from being in two states at once if the deletes and inserts are correctly paired — though enforcing "exactly one side table has this id" fully still needs application discipline or a check across tables.

## Trade-offs

**Pros:**
- No nullable columns — a column existing means the value is always meaningful.
- Schema directly mirrors the sum type's shape; reading the schema tells you the domain model.
- `declinedBy :: Set WaitlistEntryId` becomes a natural join table (`pending_slot_declines`), not a JSON blob.

**Cons:**
- More joins to assemble a full picture of one slot.
- More tables to migrate as the model grows.
- Moving between states is a delete-and-insert across tables, not a single `UPDATE` — needs care to keep atomic.

## When to choose this

Best when the team wants the schema to enforce structure as strongly as possible, queries are typically scoped to one state at a time (e.g. "find all available slots" doesn't need to filter out other states), and the sum type's payloads are substantial enough that nullable columns would be unwieldy.
