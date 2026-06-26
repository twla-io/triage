# DB Strategy: Document Store

One JSON document per aggregate (Postgres `JSONB`, MongoDB, or similar).

## Example: `Slot`

```sql
CREATE TABLE slots (
  id   UUID PRIMARY KEY,
  data JSONB NOT NULL
);
```

A row's `data` column holds the JSON-encoded `Slot` value directly, e.g.:

```json
{ "tag": "Offered", "slot": { "details": {...}, "declinedBy": [...] }, "offeredTo": "..." }
```

## Trade-offs

**Pros:**
- Closest possible mirror of the Haskell type — almost no translation layer, lowest risk of schema/type drift.
- Adding a new constructor or field to the Haskell type needs no migration.
- Natural fit if the API is also JSON-based end to end (request/response bodies look like the stored documents).

**Cons:**
- Weakest schema-level guarantees — the DB enforces almost nothing about the document's shape; a malformed write isn't caught until read time.
- Querying by a nested field (e.g. "find all slots offered to a specific waitlist entry") needs JSON path queries (`data->>'offeredTo'`), which are slower and less ergonomic than a real column, and typically need a manually-maintained index (`CREATE INDEX ... USING GIN`).
- Foreign key constraints to other tables (e.g. `doctorId` referencing `doctors`) aren't enforceable by the DB at all — referential integrity becomes an application concern.

## When to choose this

Best for early-stage projects prioritizing development speed and schema flexibility over query performance and DB-enforced integrity, or when the team is already committed to a document-store-first stack. Reconsider as the domain model stabilizes — the DB-discriminator or side-table strategies recover real schema guarantees once the types stop changing frequently.
