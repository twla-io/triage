---
name: triage-db-codegen
description: Generate the database schema and Persistence-layer module from triage's Domain.hs. Use this skill whenever creating, regenerating, or extending SQL table definitions or a Persistence module (Row types, toDomain/fromDomain, fetch/store functions) for the triage domain model. Trigger this even if the user just says "create the database tables" or "write the persistence layer" without mentioning Domain.hs explicitly, as long as the triage domain model is the source.
---

# triage-db-codegen

`Domain.hs` is the single source of truth. The database schema and the Persistence module are both **derived** from it — read `Domain.hs` first, every time, rather than working from memory of a previous generation.

This skill encodes specific decisions already made for `triage`, not a menu of strategies. Apply these rules directly; don't offer alternatives.

## Architecture this skill fits into

```
Domain        — pure, sealed types, smart constructors, zero awareness of JSON/DB/anything external
Transport     — DTOs for wire formats (JSON), toDomain/fromDomain at the boundary (separate skill, not this one)
Persistence   — Row types matching storage shape, toDomain/fromDomain at the boundary (this skill)
```

`Domain.hs` has no serialization of any kind — no `ToJSON`/`FromJSON`, no `Generic` deriving for that purpose. Nothing in this skill should assume otherwise or reintroduce that coupling.

## Sum types become one table, a discriminator column, and nullable state-specific columns (`discriminator-column-tables`, Rule 1)

For every multi-constructor domain type without a separate status field (`Slot`, `AppointmentRequest`'s priority variants, `Appointment`), generate **one table**, not one table per constructor:

```sql
state TEXT NOT NULL CHECK (state IN ('pending', 'available', 'booked')),
-- nullable columns for each constructor's extra payload
```

For each domain type, write **one `CHECK` constraint per valid constructor shape**, derived mechanically from the constructors themselves — every combination of which nullable columns are set must correspond to exactly one constructor:

```sql
CHECK (
  (state = 'pending'   AND appointment_id IS NULL) OR
  (state = 'available' AND appointment_id IS NULL) OR
  (state = 'booked'    AND appointment_id IS NOT NULL)
)
```

This isn't redundant with `Domain.hs`'s own type-level guarantee — it's a backstop against backdoor writes (manual SQL, bad migrations, anything bypassing the generated Persistence module) that the type system can no longer see once data has left Haskell. See `migrations/0001_init.sql` at the repo root for the current generated schema — derive future migrations fresh from `Domain.hs` rather than copying it verbatim, numbered sequentially (`migrations/0002_...sql`, etc.), not into `skills/`.

## Nullable columns can be the discriminator by themselves — no separate column needed when nullability alone is a bijection (`nullability-as-discriminator`, Rule 2)

Distinct from `discriminator-column-tables`: that rule adds an explicit `state` column because the nullable payload columns *alone* don't injectively determine the constructor (e.g. `HealthcareRequestPriority`'s `Emergency`/`Urgent`/`Routine (RoutineNotAfter _)` all produce the identical `(due_not_before, due_not_after)` shape — see `ord-ranking-check`'s worked example). `nullability-as-discriminator` is the narrower, opposite case: a field whose own nullable column(s) already form a complete bijection with a small sum type, so no extra column is needed at all.

Two live examples:

- `DoctorRequirement` (`AnyDoctor | SpecificDoctor DoctorId`) encodes as a single nullable FK: `NULL = AnyDoctor`, a set value = `SpecificDoctor`. No `has_doctor_requirement` column.
- `RoutineDue` (`RoutineAnytime | RoutineNotBefore | RoutineNotAfter | RoutineWithin`) encodes via the *joint* nullability of two columns (`due_not_before`, `due_not_after`) — all four NULL/set combinations are valid and each maps to exactly one constructor.

Before applying this instead of `discriminator-column-tables`, verify the bijection actually holds: enumerate every constructor's nullable-column pattern and confirm none collide. If two constructors could produce the same pattern, the field needs `discriminator-column-tables`'s explicit column instead — don't assume nullability alone is safe just because it worked for one field.

## Check `Ord`-bearing types against their derived ranking, not just valid values (`ord-ranking-check`, Rule 3)

If a domain type stored as a column has a derived `Ord` instance and anything ever sorts by it, the column's encoding must preserve that ranking under the database's native ordering — checking "is this a valid value" is not sufficient.

`HealthcareRequestPriority`'s custom `Ord` instance gives `Emergency < Urgent < Routine` (`Domain.hs`'s `compare`, not a bare `deriving Ord`). A naive `TEXT` column sorts alphabetically — `'emergency' < 'routine' < 'urgent'` — which **disagrees** with the domain order on where `Routine` and `Urgent` fall. Where the DB itself sorts or compares by the column, the fix is an integer encoding matching the derived rank directly:

```sql
priority SMALLINT NOT NULL CHECK (priority IN (0, 1, 2))  -- 0=Emergency, 1=Urgent, 2=Routine
```

Before choosing a column type for any enum-shaped value, check: does this type derive (or define) `Ord`, and does anything in `Domain.hs` or the application ever sort or compare by it *at the database layer*? If yes, the encoding must be checked against the actual derived ranking, not assumed safe because the values themselves are constrained.

This condition can fail even when the type clearly has a meaningful `Ord`. `healthcare_requests.tier` stores `HealthcareRequestPriority`'s tier as plain `TEXT` (`'emergency'|'urgent'|'routine'`) rather than the ranked-int encoding above — verified against `Domain.hs`'s `checkWaitlist`, whose `sortOn priority` runs in Haskell over an already-decoded `[TriagedHealthcareRequest]` list, never as a SQL `ORDER BY`. No comparison happens at the database layer for this column, so this rule's precondition doesn't hold and `TEXT` is correct. Don't apply the int encoding reflexively just because a type derives `Ord` — check where the comparison actually happens first.

## Multi-valued fields become join tables, never array columns (`join-table-not-array`, Rule 4)

No domain field currently needs this rule — `PendingSlot.declinedBy` was the original motivating case, and it was removed entirely along with the offer mechanism (see `Domain.hs`'s comment on `PendingSlot`). The rule is kept here for if/when a future `Set a`/`[a]` field appears: such a field becomes a separate join table with real foreign key constraints, never a native array column (e.g. Postgres `UUID[]`), even though Postgres supports them.

Reasons, in order of how much they actually matter: an array column cannot carry a foreign key constraint at all (a stray, non-existent UUID in the array is invisible to the database forever); no cascading delete; no uniqueness guarantee against duplicate entries; awkward, index-dependent reverse queries; concurrent-write hazards on the same array. A join table closes all of these for free.

## Decoding fails loudly, never clamps or coerces silently (`fail-loudly-on-decode`, Rule 5)

Any function reading a column value back into a domain type must produce an explicit error on anything that doesn't correspond to a valid domain value — never round, clamp, or default it into something plausible-looking.

```haskell
data DecodeError = InvalidDuration Int | InvalidPriority Int | ...
  deriving (Show, Eq)

decodeDuration :: Int -> Either DecodeError Duration
decodeDuration 60 = Right OneHour
decodeDuration 30 = Right HalfAnHour
decodeDuration n  = Left (InvalidDuration n)
```

This matters specifically because of `discriminator-column-tables`'s threat model: a `CHECK` constraint defends against backdoor writes at insert time, but anything that somehow still gets through (a constraint added after data already existed, a constraint disabled during a migration) must surface as a decode failure when read back — not get silently coerced into a default that hides the corruption.

Where `Domain.hs` itself exposes a smart constructor for the value being decoded (e.g. `mkWithin` for `DueAt`'s `Within` case), the decode function must go through it rather than constructing the value directly — the same validation that protects in-memory construction has to protect the read-from-storage path too.

## Cross-table consistency needs a trigger only when nothing else catches the mismatch (`transactional-cross-table-consistency`, Rule 6)

No current case needs this rule — it addressed `slots.offered_to` / `appointment_requests.offered_slot_id` disagreeing, both of which were removed along with the entire offer mechanism. Kept here for if/when a future pair of columns across two tables are supposed to agree:

- If a domain function already re-validates the relationship at the point it matters and fails gracefully — rely on that, plus the convention that both columns are always written together in one transaction by the same Persistence-layer function. No trigger.
- If no such function exists, and a disagreement would be silently acted upon by some other operation with no defense — that's the case that justifies a trigger, the same standard already applied to `discriminator-column-tables`'s `CHECK` constraints.

Don't add a trigger by default "to be safe" — that's the same unnecessary-complexity mistake this domain model has avoided elsewhere (see `Domain.hs`'s own comments on `escalateToUrgent`, `sortWaitlist`). Justify it against an actual unguarded failure mode, or skip it.

## ID types need no special handling (`id-newtype-passthrough`, Rule 7)

Domain ID newtypes (`DoctorId`, `PatientId`, `ServiceId`, `SlotId`, `AppointmentId`, `AppointmentRequestId`) are not sealed — their constructors are exported. Extract the underlying `UUID` with plain pattern matching (`let DoctorId u = someDoctorId in u`); no helper function or typeclass is needed for this, and adding one would be unnecessary indirection around something that already works.

## Minimal domain types get minimal tables (`minimal-types-minimal-tables`, Rule 8)

`Doctor` and `Patient` are deliberately minimal in `Domain.hs` (`id` and `name` only, pending a future external system). Their tables must match — do not add columns speculatively (email, specialty, contact info, etc.) that aren't in the domain type. If `Domain.hs` gains a field, the table gains the matching column; not before.

## Reconstructing a sealed type's hidden state replays through existing exports, never a new raw constructor (`sealed-type-replay`, Rule 9)

Some domain types are sealed because their internal state must only ever be reached through validated paths. `PendingSlot` no longer needs this at all — it's an open, single-field `newtype` now, and reconstructing one from storage is just `PendingSlot details`, no replay needed. But `BookedSlot` and `OpenAppointment` are still sealed, and reconstructing either still hits the same problem: two tempting fixes are both wrong, for related reasons:

- **Adding a new exported `Domain.hs` function that takes the raw internal state directly** is equivalent to unsealing the constructor — it grants the same fabrication capability to every caller, not just the Persistence layer, defeating the reason the type was sealed in the first place.
- **Adding a constructor or field to a real domain type purely to support reconstruction** leaks a Persistence-layer concern backward into the Domain layer.

**The correct approach: rebuild the value by replaying it through the type's own already-safe exported functions**, supplying placeholder values only for arguments that are *provably* never read by the specific call path — verified by checking what those functions actually use, not assumed. For `BookedSlot`:

```haskell
-- bookAppointment's BookedSlot half never reads patientId — only the
-- (fabricated, discarded) Appointment half does. Verified against the
-- current bookAppointment body before relying on this.
rebuildBookedSlot :: SlotDetails -> AppointmentId -> BookedSlot
rebuildBookedSlot details aid =
  fst (bookAppointment (releaseSlot (PendingSlot details)) aid (PatientId nil))
```

For `OpenAppointment` — simpler than before, since `assignAppointment` is now total (no `Maybe` to satisfy):

```haskell
rebuildOpenAppointment :: AppointmentId -> PatientId -> AppointmentPriority -> SlotId -> OpenAppointment
rebuildOpenAppointment aid realPid realPrio realSlotId =
  case assignAppointment placeholderSlot placeholderRequest aid of
    (_, Open oa) -> oa
  where
    placeholderRequest = case realPrio of
      Emergency -> EmergencyRequest details
      Urgent    -> UrgentRequest    details
      Routine   -> RoutineRequest   details Nothing Anytime
      where details = AppointmentRequestDetails
              { id = AppointmentRequestId nil, patientId = realPid
              , serviceId = ServiceId nil, createdAt = posixSecondsToUTCTime 0 }
    placeholderSlot = PendingSlot SlotDetails
      { id = realSlotId, doctorId = DoctorId nil, serviceId = ServiceId nil
      , start = posixSecondsToUTCTime 0, duration = OneHour }
```

Any placeholder used this way must: be defined entirely within the Persistence layer (never exported, never visible to `Domain.hs` or any other module); use hardcoded sentinel literals (e.g. `Data.UUID.nil`, a fixed epoch timestamp) rather than parameters, so nothing about it looks configurable or meaningful; and carry a comment stating exactly which fields are real and which are inert, and why the inert ones are provably never read by the specific functions being replayed through.

## A row's mere existence is the discriminator — never delete or flag on consumption (`no-delete-on-consumption`, Rule 10)

`healthcare_requests` is two-valued (`submitted`/`triaged`) only — there is no third "matched" state and no schema-level path back from matched to waiting, confirmed against `Domain.hs`: nothing transitions a triaged-and-matched request back to waiting.

Don't add a status column or a soft-delete flag to capture "already matched." **Never delete or flag the row** on match — a match is represented entirely by the existence of a corresponding `appointments` row referencing it via `healthcare_request_id`. "Currently waiting" is a derived query: a `triaged` request with no matching `appointments` row (an anti-join), not a stored flag. This reverses an earlier delete-on-match design from a prior `appointment_requests` table — see `docs/decisions.md`'s "healthcare_requests lifecycle" entry.

## The Persistence module

All Persistence-layer code lives in a single module, `src/Persistence.hs` (module name `Persistence`) — mirroring `Domain.hs`'s own single-file convention. Do not create one file per aggregate; add new `Row` types and functions to this one file as the domain grows. Add `Persistence` to `triage.cabal`'s `exposed-modules` (or `other-modules`, if it's not meant to be part of the library's public interface) the first time this file is created.

For each domain aggregate with its own table(s), generate, within `Persistence.hs`:

1. **A `Row` type** whose fields match the table's columns exactly (e.g. `ServiceRow`, `SlotRow`, `AppointmentRequestRow`, `AppointmentRow`).
2. **`toDomain :: Row -> Either DecodeError DomainType`** — decodes a row into the real domain value, following `fail-loudly-on-decode`.
3. **`fromDomain :: DomainType -> Row`** — encodes a domain value for storage. Always total; nothing about going from a valid domain value to its storage shape can fail, since the domain value is already known-valid.
4. **Fetch and store functions** — `fetchX :: <connection> -> XId -> IO (Maybe X)`, `storeX :: <connection> -> X -> IO ()`, mapping through `toDomain`/`fromDomain` and the actual SQL. For `HealthcareRequest` specifically, per `no-delete-on-consumption` there is no delete or status flip on match — add a `fetchWaitlist` function running the anti-join instead of branching the store side on match. The specific Haskell DB library (`postgresql-simple`, `hasql`, etc.) has not been decided — leave the connection type and query mechanism as an explicit open parameter rather than assuming one. Ask before committing to a library if it isn't already established elsewhere in the project.

See `references/persistence-pattern.md` for worked examples of the `Row`/`toDomain`/`fromDomain` pattern, including `sealed-type-replay`'s reconstruction technique for `BookedSlot` and `OpenAppointment`.

## When unsure

If a rule above doesn't cover a case that comes up, prefer the option that mirrors `Domain.hs`'s own structure most directly, and flag the ambiguity to the user rather than inventing a convention silently.
