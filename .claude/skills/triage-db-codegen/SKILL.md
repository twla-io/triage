---
name: triage-db-codegen
description: Generate the database schema and Persistence-layer module from triage's Domain.hs. Use this skill whenever creating, regenerating, or extending SQL table definitions or a Persistence module (Row types, toDomain/fromDomain, fetch/store functions) for the triage domain model. Trigger this even if the user just says "create the database tables" or "write the persistence layer" without mentioning Domain.hs explicitly, as long as the triage domain model is the source.
---

# triage-db-codegen

`Domain.hs` is the single source of truth. The database schema and the Persistence module are both **derived** from it — read `Domain.hs` first, every time, rather than working from memory of a previous generation (including this skill's own worked examples, which will go stale exactly like the previous version of this skill did).

This skill encodes specific decisions already made for `triage`, not a menu of strategies. Apply these rules directly; don't offer alternatives.

**Rules are identified by name, not number.** Numbers below are positional only — they will drift whenever a rule is added, retired, or reordered (this happened once already: the previous version's "Rule 9" is a different rule than this version's). Always cross-reference by name (e.g. `nullability-as-discriminator`), never by number, in code comments, PR descriptions, or conversation.

| Name | One-line summary |
|---|---|
| `discriminator-column-tables` | Sum types → one table, discriminator column, nullable payload columns |
| `nullability-as-discriminator` | Presence/absence sum types → nullable column(s) alone, no redundant discriminator |
| `ord-ranking-check` | Only add SQL-level rank encoding if something actually sorts in SQL |
| `join-tables-not-arrays` | Multi-valued fields → join tables, never array columns |
| `fail-loudly-on-decode` | Decode errors are explicit, never clamped/defaulted |
| `transactional-cross-table-consistency` | Cross-table agreement enforced by transaction discipline, not a trigger, unless nothing else catches it |
| `id-types-plain` | ID newtypes need no helper functions |
| `minimal-types-minimal-tables` | Don't add speculative columns beyond what `Domain.hs` has |
| `sealed-type-replay` | Reconstruct sealed types by replaying through existing exported functions |
| `no-delete-on-consumption` | Requests are never deleted or flagged matched; "waiting" is a derived anti-join |

## Architecture this skill fits into

```
Domain        — pure, sealed types, smart constructors, zero awareness of JSON/DB/anything external
Transport     — DTOs for wire formats (JSON), toDomain/fromDomain at the boundary (separate skill, not this one)
Persistence   — Row types matching storage shape, toDomain/fromDomain at the boundary (this skill)
```

`Domain.hs` has no serialization of any kind — no `ToJSON`/`FromJSON`, no `Generic` deriving for that purpose. Nothing in this skill should assume otherwise or reintroduce that coupling.

## `discriminator-column-tables` (Rule 1) — Sum types become one table, a discriminator column, and nullable state-specific columns

For every multi-constructor domain type without a separate status field, generate **one table**, not one table per constructor. The three live cases in the current domain:

- `HealthcareRequest` (`Submitted | Triaged`) -> `healthcare_requests`, `state IN ('submitted', 'triaged')`.
- `Slot` (`Available | Booked`) -> `slots`, `state IN ('available', 'booked')`.
- `Appointment` (`Open | Closed`) -> `appointments`, `state IN ('open', 'closed')`.

Write **one `CHECK` constraint per valid constructor shape**, derived mechanically from the constructors themselves — every combination of which nullable columns are set must correspond to exactly one constructor. See `migrations/0001_init.sql` for the current worked example of all three — that file is the live reference; when actually generating SQL, derive it fresh from `Domain.hs` and write it to `migrations/` at the repo root, numbered sequentially (`migrations/0002_...sql`, etc.) for any schema change after this one.

This isn't redundant with `Domain.hs`'s own type-level guarantee — it's a backstop against backdoor writes (manual SQL, bad migrations, anything bypassing the generated Persistence module) that the type system can no longer see once data has left Haskell.

## `nullability-as-discriminator` (Rule 2) — Presence/absence sum types encode via nullability alone — no redundant discriminator

Where a sum type's cases differ *solely* by the presence or absence of a payload (not by which of several distinct shapes it takes), a single nullable column — or a small fixed set of them — already carries full information about which case applies. Adding a parallel `TEXT` discriminator column next to it duplicates information the nullability pattern already states, and risks the two disagreeing.

Two live cases:

- **`DoctorRequirement` (`AnyDoctor | SpecificDoctor DoctorId`)**: `required_doctor_id UUID NULL REFERENCES doctors(id)`. `NULL` means `AnyDoctor`; a set value means `SpecificDoctor`. No `doctor_requirement TEXT` column alongside it.
- **`RoutineDue` (`RoutineAnytime | RoutineNotBefore UTCTime | RoutineNotAfter UTCTime | RoutineWithin UTCTime UTCTime`)**: two nullable columns, `due_not_before` / `due_not_after`, give exactly 2² = 4 nullability combinations — a genuine bijection with `RoutineDue`'s four constructors:

  | `due_not_before` | `due_not_after` | case |
  |---|---|---|
  | NULL | NULL | `RoutineAnytime` |
  | set | NULL | `RoutineNotBefore` |
  | NULL | set | `RoutineNotAfter` |
  | set | set | `RoutineWithin` |

  `EmergencyDue`/`UrgentDue` are each a single "must be seen by X" deadline — structurally identical to `RoutineNotAfter` — so `Emergency`/`Urgent` tiers reuse `due_not_after` rather than getting their own `emergency_due`/`urgent_due` columns. The `tier` column (`emergency`/`urgent`/`routine`) exists because tier itself is *not* a presence/absence distinction — it's three genuinely different shapes — so `discriminator-column-tables` applies to `tier`, and `nullability-as-discriminator` applies within the `routine` case to the deadline pair.

When a new nullable field is proposed, check first whether it's actually encoding a presence/absence sum type per this rule before reaching for a separate discriminator column.

## `ord-ranking-check` (Rule 3) — Check `Ord`-bearing types against their derived ranking only if something actually sorts by it at the SQL level

If a domain type stored as a column has a derived `Ord` instance, that alone does not require an integer-rank encoding — only do this if some query actually needs `ORDER BY` on it in SQL.

`HealthcareRequestPriority` and `RoutineDue` both derive `Ord`, and the ranking is non-trivial (case-shape first, value second — e.g. `RoutineWithin < RoutineNotAfter < RoutineNotBefore < RoutineAnytime`, which a naive column sort would not reproduce). But **ordering happens exclusively in `Domain.hs`** — `checkWaitlist`'s `sortOn priority` runs in memory over already-decoded `TriagedHealthcareRequest` values, fetched via a plain (unordered) query. Confirmed: nothing in the intended Persistence layer issues `ORDER BY` on priority.

Consequence: **no integer tier-rank column exists in this schema, and none should be added.** If a future change introduces a query that does need SQL-level priority ordering, that's the trigger to revisit this rule — not the mere presence of the `Ord` instance.

## `join-tables-not-arrays` (Rule 4) — Multi-valued fields become join tables, never array columns

No domain field currently needs this rule. Kept for if/when a future `Set a`/`[a]` field appears on a domain type: such a field becomes a separate join table with real foreign key constraints, never a native array column (e.g. Postgres `UUID[]`), even though Postgres supports them.

Reasons, in order of how much they actually matter: an array column cannot carry a foreign key constraint at all (a stray, non-existent UUID in the array is invisible to the database forever); no cascading delete; no uniqueness guarantee against duplicate entries; awkward, index-dependent reverse queries; concurrent-write hazards on the same array. A join table closes all of these for free.

## `fail-loudly-on-decode` (Rule 5) — Decoding fails loudly, never clamps or coerces silently

Any function reading a column value back into a domain type must produce an explicit error on anything that doesn't correspond to a valid domain value — never round, clamp, or default it into something plausible-looking.

```haskell
data DecodeError = InvalidDuration Int | InvalidTier Text | InvalidState Text | ...
  deriving (Show, Eq)

decodeDuration :: Int -> Either DecodeError Duration
decodeDuration 15 = Right QuarterOfAnHour
decodeDuration 30 = Right HalfAnHour
decodeDuration 60 = Right OneHour
decodeDuration n  = Left (InvalidDuration n)
```

This matters specifically because of `discriminator-column-tables`'s threat model: a `CHECK` constraint defends against backdoor writes at insert time, but anything that somehow still gets through (a constraint added after data already existed, a constraint disabled during a migration) must surface as a decode failure when read back — not get silently coerced into a default that hides the corruption.

Where `Domain.hs` itself exposes a smart constructor for the value being decoded (e.g. `mkRoutineWithin` for `RoutineDue`'s `RoutineWithin` case), the decode function must go through it rather than constructing the value directly — the same validation that protects in-memory construction has to protect the read-from-storage path too.

## `transactional-cross-table-consistency` (Rule 6) — Cross-table consistency needs a trigger only when nothing else catches the mismatch

This is now a **live case**, not a hypothetical: `slots.appointment_id` and `appointments.slot_id` are two independent columns in two different tables that must always agree, and `reassignSlot` actively changes this pairing in place (old slot freed, new slot booked, same appointment row's `slot_id` updated) with no new rows created on either side.

Applying the same standard as before: `satisfyHealthcareRequest` and `reassignSlot` both produce their `BookedSlot`/`OpenAppointment` (or freed/rebooked) pairs atomically as pure values — the corresponding `Persistence.hs` store functions must write both the `slots` and `appointments` rows involved **in a single transaction**. Given that discipline, no trigger is used. Both FKs (`slots.appointment_id -> appointments`, `appointments.slot_id -> slots`) are declared `DEFERRABLE INITIALLY DEFERRED` specifically so a single transaction can insert/update both tables in either order without a constraint firing mid-transaction on a momentarily-circular reference.

Don't add a trigger by default "to be safe" — that's the unnecessary-complexity mistake this domain model has avoided elsewhere. The transactional-pairing discipline is the chosen guard; revisit only if a real unguarded write path (bypassing `Persistence.hs` entirely) is identified.

## `id-types-plain` (Rule 7) — ID types need no special handling

Domain ID newtypes (`DoctorId`, `PatientId`, `HealthcareServiceId`, `HealthcareRequestId`, `SlotId`, `AppointmentId`) are not sealed — their constructors are exported. Extract the underlying `UUID` with plain pattern matching (`let DoctorId u = someDoctorId in u`); no helper function or typeclass is needed for this.

## `minimal-types-minimal-tables` (Rule 8) — Minimal domain types get minimal tables

`Doctor` and `Patient` are deliberately minimal in `Domain.hs` (`id` and `name` only, pending a future external system). Their tables must match — do not add columns speculatively (email, specialty, contact info, etc.) that aren't in the domain type. If `Domain.hs` gains a field, the table gains the matching column; not before.

## `sealed-type-replay` (Rule 9) — Reconstructing a sealed type's hidden state replays through existing exported functions, never a new raw constructor

Some domain types are sealed because their internal state must only ever be reached through validated paths. As of the current `Domain.hs`, **`BookedSlot` is the only remaining case needing this treatment.**

`OpenAppointment` is now exported openly (`OpenAppointment (..)` — "constructor open, no invariant to protect") and `ClosedAppointment`'s only producer, `closeAppointment`, has no predicate to satisfy — both reconstruct from real stored data via direct construction, no placeholder needed:

```haskell
-- OpenAppointment: real data throughout — healthcare_request_id and slot_id
-- come straight from the row, no fabrication.
toDomainOpenAppointment :: AppointmentId -> TriagedHealthcareRequest -> SlotId -> OpenAppointment
toDomainOpenAppointment = OpenAppointment

-- ClosedAppointment: closeAppointment has no predicate to satisfy — direct
-- wrap of two already-real values.
rebuildClosedAppointment :: OpenAppointment -> CloseReason -> ClosedAppointment
rebuildClosedAppointment = closeAppointment
```

`BookedSlot`'s only producers are `satisfyHealthcareRequest` and `reassignSlot` — but `reassignSlot` delegates to `satisfyHealthcareRequest` internally rather than gating independently, so there is exactly **one** place `matches` actually needs verifying, not two:

```haskell
reassignSlot
  :: OpenAppointment
  -> BookedSlot      -- appointment's current slot; caller's responsibility to pass the correct one, not checked here
  -> AvailableSlot   -- proposed new slot
  -> Maybe (AvailableSlot, BookedSlot, OpenAppointment)
reassignSlot (OpenAppointment aid req _) (BookedSlot oldDetails _) newSlot =
  (\(bs, oa) -> (AvailableSlot oldDetails, bs, oa)) <$> satisfyHealthcareRequest newSlot aid req
```

With that delegation in place, `matches` itself is:

```haskell
matches slot req = slot.healthcareServiceId == req.healthcareServiceId
                 && matchesDoctorRequirement slot req.details.doctorRequirement
                 && matchesTime req.priority slot.start
```

Two tempting fixes are both wrong, for related reasons:

- **Adding a new exported `Domain.hs` function that takes the raw internal state directly** is equivalent to unsealing the constructor — it grants the same fabrication capability to every caller, not just the Persistence layer, defeating the reason the type was sealed in the first place.
- **Adding a constructor or field to a real domain type purely to support reconstruction** leaks a Persistence-layer concern backward into the Domain layer.

**The correct approach: rebuild the value by replaying it through the type's own already-safe exported functions**, fabricating only the arguments needed to make the gating predicate *provably* always succeed — verified against the predicate's actual current body, not assumed:

```haskell
-- BookedSlot's constructor (BookedSlot slot appointmentId) never reads
-- `request` at all — only `matches` does, to gate whether
-- satisfyHealthcareRequest fires.
-- healthcareServiceId is real (must equal the slot's own, or matches
-- fails). doctorRequirement = AnyDoctor and priority = Routine
-- RoutineAnytime are the unique constructors that make
-- matchesDoctorRequirement/matchesTime unconditionally True, verified
-- against their current bodies — not assumed. id/patientId/narrative/
-- createdAt/triagedAt are sentinel — discarded either way, since only the
-- BookedSlot half of the result is kept. fromJust is safe here
-- specifically because the Maybe is proven, not merely expected, to be
-- Just — this is the one place in generated Persistence code where
-- fromJust is acceptable, and only because of this proof.
rebuildBookedSlot :: SlotDetails -> AppointmentId -> BookedSlot
rebuildBookedSlot details aid =
  fst . fromJust $ satisfyHealthcareRequest (AvailableSlot details) aid placeholderRequest
  where
    placeholderRequest = TriagedHealthcareRequest
      { details  = HealthcareRequestDetails
          { id = HealthcareRequestId nil, patientId = PatientId nil
          , narrative = "", doctorRequirement = AnyDoctor
          , createdAt = posixSecondsToUTCTime 0 }
      , healthcareServiceId = details.healthcareServiceId
      , priority  = Routine RoutineAnytime
      , triagedAt = posixSecondsToUTCTime 0
      }
```

Any placeholder used this way must: be defined entirely within the Persistence layer (never exported, never visible to `Domain.hs` or any other module); use hardcoded sentinel literals (e.g. `Data.UUID.nil`, a fixed epoch timestamp) rather than parameters, so nothing about it looks configurable or meaningful; and carry a comment stating exactly which fields are real, which are inert, and — for the `fromJust`-style case above — the specific proof that the gating predicate always succeeds, not just an assumption that it does.

## `no-delete-on-consumption` (Rule 10) — A row's mere existence is *not* the discriminator here; requests are never deleted on consumption

An earlier version of this skill had a rule with the opposite name and behavior — a matched request's row was deleted the moment it was consumed, and existence alone meant "waiting." That doesn't apply to the current domain at all; naming this rule for what it now does, rather than reusing a number, is exactly to prevent that confusion from recurring.

The current domain's deliberate choice: `healthcare_requests` rows are **never deleted**, and there is **no third `state` value** for "matched" — confirmed against the current `Domain.hs`, nothing transitions a request back to waiting, and nothing marks it matched in place either.

Instead, "currently waiting" is a **derived** condition: a triaged request with no corresponding `appointments` row.

```sql
SELECT hr.*
FROM healthcare_requests hr
LEFT JOIN appointments a ON a.healthcare_request_id = hr.id
WHERE hr.state = 'triaged' AND a.id IS NULL;
```

`appointments.healthcare_request_id` is `UNIQUE`, so this join can never produce more than one `appointments` row per request — a triaged request is consumed by at most one appointment, ever. A failed `reassignSlot` does not free the original request back to this query's result set; it produces an entirely new `healthcare_requests` row via re-triage, with no stored lineage back to the original (deliberate — `Domain.hs` doesn't track that lineage, and the schema doesn't invent it; see the `healthcare_requests` comment in `migrations/0001_init.sql`).

Do not reintroduce a `'matched'` state value or a soft-delete flag to represent this — the anti-join is the intended query shape, matching the fact that `Domain.hs` itself has no notion of a request being flagged matched, only of an `OpenAppointment` existing that happens to reference it.

## The Persistence module

All Persistence-layer code lives in a single module, `src/Persistence.hs` (module name `Persistence`) — mirroring `Domain.hs`'s own single-file convention. Do not create one file per aggregate; add new `Row` types and functions to this one file as the domain grows. Add `Persistence` to `triage.cabal`'s `exposed-modules` (or `other-modules`, if it's not meant to be part of the library's public interface) the first time this file is created.

For each domain aggregate with its own table(s), generate, within `Persistence.hs`:

1. **A `Row` type** whose fields match the table's columns exactly (e.g. `HealthcareServiceRow`, `SlotRow`, `HealthcareRequestRow`, `AppointmentRow`).
2. **`toDomain :: Row -> Either DecodeError DomainType`** — decodes a row into the real domain value, following `fail-loudly-on-decode`.
3. **`fromDomain :: DomainType -> Row`** — encodes a domain value for storage. Always total; nothing about going from a valid domain value to its storage shape can fail, since the domain value is already known-valid.
4. **Fetch and store functions** — `fetchX :: <connection> -> XId -> IO (Maybe X)`, `storeX :: <connection> -> X -> IO ()`, mapping through `toDomain`/`fromDomain` and the actual SQL. The specific Haskell DB library (`postgresql-simple`, `hasql`, etc.) has not been decided — leave the connection type and query mechanism as an explicit open parameter rather than assuming one. Ask before committing to a library if it isn't already established elsewhere in the project.
5. **A dedicated waitlist fetch**, `fetchWaitlist :: <connection> -> IO (Either DecodeError [TriagedHealthcareRequest])`, implementing `no-delete-on-consumption`'s anti-join and decoding each resulting row via the same `toDomain` path as any other triaged `HealthcareRequestRow`. This is the function `checkWaitlist`'s caller is expected to use to obtain its input list.
6. **Transactional pairing for `satisfyHealthcareRequest`/`reassignSlot`**, per `transactional-cross-table-consistency` — the store function(s) covering these must write the affected `slots` and `appointments` rows within one transaction. Do not split this across two separately-committed calls.

See `references/persistence-pattern.md` for worked examples of the `Row`/`toDomain`/`fromDomain` pattern, including `sealed-type-replay`'s reconstruction technique for `BookedSlot`.

## When unsure

If a rule above doesn't cover a case that comes up, prefer the option that mirrors `Domain.hs`'s own structure most directly, and flag the ambiguity to the user rather than inventing a convention silently. When adding a genuinely new rule, give it a name in this same style before writing content under it — don't leave it number-only, and don't renumber existing rules to make room for it.