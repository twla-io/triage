---
name: triage-db-codegen
description: Conventions for generating a database schema from triage's Domain.hs — the medical appointment scheduling domain model. Use this skill whenever designing, generating, or migrating database tables, SQL schemas, or document-store collections derived from Domain.hs types. Trigger this even if the user just says "create the database tables" or "design the schema" without mentioning Domain.hs explicitly, as long as the triage domain model is the source. Do not use this skill for API or UI generation — see triage-api-codegen and triage-ui-codegen instead.
---

# triage-db-codegen

`Domain.hs` is the single source of truth for the `triage` scheduling domain. The database schema should be **derived** from it, not designed independently.

## Invariants (non-negotiable)

### Sum types without a separate status field are the entity's entire state

```haskell
data Slot = Pending PendingSlot | Offered OfferedSlot
          | Available AvailableSlot | Booked BookedSlot
```

This is **not** "one `Slot` table plus a `status` enum column." Each constructor is a distinct state with its own payload — the constructor **is** the status. Never add a separate `status` column alongside whichever encoding you choose below. The same pattern applies to `WaitlistEntry` (`EmergencyEntry | UrgentEntry | RoutineEntry`) and `Appointment` (`Open | Closed`).

### Newtype ID wrappers are opaque UUIDs

`DoctorId`, `PatientId`, `SlotId`, etc. are `UUID` columns, never a wrapper or composite type. Different ID types must never share a column or be used interchangeably, even though they have the same underlying type — preserve the distinction via foreign key targets, not just naming convention.

### `Maybe a` is nullable; `[a]` / `Set a` is multi-valued storage

`doctorId :: Maybe DoctorId` is a nullable foreign key column. `declinedBy :: Set WaitlistEntryId` is never modeled as repeated rows of the same entity — it's a join table or an array/JSON column (the exact shape depends on which schema strategy below is chosen).

### Multi-aggregate writes are atomic, always

```haskell
data WaitlistResult = NoMatch AvailableSlot | Matched OfferedSlot WaitlistEntry
```

Both values inside `Matched` must be written in a single transaction. If only one half is written, the invariant "the slot's `offeredTo` agrees with the waitlist entry's `SlotOffered` status" breaks. Any domain function returning more than one value follows this same rule — never commit one half and defer the other.

## Strategy choices — pick one, or ask the user

Three legitimate ways to encode "sum type = entire state" relationally or in a document store. None is more correct than the others; they trade off differently.

- `references/discriminator-column.md` — one table per aggregate, a discriminator column, nullable columns for state-specific fields. Simplest migrations, more nullable columns, weakest schema-level state guarantees.
- `references/side-tables.md` — shared table for common fields, one side table per state-specific payload. No nullable columns, stronger guarantees, more joins.
- `references/document-store.md` — one JSON document per aggregate, closest mirror of the Haskell type. Fastest to iterate, weakest schema enforcement, hardest to query by nested field.

Ask which fits the team's existing DB engine and query patterns before picking. If the team already has a DB engine in use elsewhere in the codebase, match it rather than introducing a new one for this domain alone.

## When unsure

Prefer the option that keeps the schema a thin, faithful mirror of the type structure over one that "normalizes" or "simplifies" it — the type structure already reflects real domain decisions made with the doctor (see `Domain.hs`'s inline comments for the reasoning behind each type). Flag the ambiguity to the user rather than silently picking.
