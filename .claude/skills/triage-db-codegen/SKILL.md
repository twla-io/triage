---
name: triage-db-codegen
description: Generate the database schema and Persistence-layer module from triage's Domain.hs. Use this skill whenever creating, regenerating, or extending SQL table definitions or a Persistence module (Row types, toDomain/fromDomain, fetch/store functions) for the triage domain model. Trigger this even if the user just says "create the database tables" or "write the persistence layer" without mentioning Domain.hs explicitly, as long as the triage domain model is the source.
---

# triage-db-codegen

`Domain.hs` is the single source of truth. The database schema and the Persistence module are both **derived** from it — read `Domain.hs` first, every time, rather than working from memory of a previous generation (including this skill's own worked examples, which have already gone stale once before and will again).

This skill encodes specific decisions already made for `triage`, not a menu of strategies. Apply these rules directly; don't offer alternatives.

**Rules are identified by name, not number.** Numbers below are positional only. Always cross-reference by name (e.g. `nullability-as-discriminator`), never by number.

| Name | One-line summary |
|---|---|
| `discriminator-column-tables` | Sum types → one table, discriminator column, nullable payload columns |
| `nullability-as-discriminator` | Presence/absence sum types → nullable column(s) alone, no redundant discriminator |
| `ord-ranking-check` | Only add SQL-level rank encoding if something actually sorts in SQL |
| `join-tables-not-arrays` | Multi-valued fields → join tables, never array columns |
| `fail-loudly-on-decode` | Decode errors are explicit, never clamped/defaulted |
| `atomic-multi-table-write` | Multi-table writes enforced by transaction discipline, not a trigger |
| `id-types-plain` | ID newtypes need no helper functions |
| `minimal-types-minimal-tables` | Don't add speculative columns beyond what `Domain.hs` has |
| `sealed-type-replay` | Reconstruct sealed types by replaying through existing exported functions — currently no live case |
| `no-delete-on-consumption` | Healthcare requests are never deleted or flagged matched; "waiting" is a derived anti-join |
| `deleted-on-match` | Slots have no post-match existence; a matched slot's row is deleted, not flagged |
| `sealed-value-decomposition` | Extracting fields from an already-held sealed value needs a read-only `Domain.hs` accessor — replay doesn't apply |
| `uniqueness-races-are-outcomes` | A write whose success depends on a row's observed shape staying put needs affected-rows detection, never a caught exception |

## Architecture this skill fits into

```
Domain        — pure, sealed types, smart constructors, zero awareness of JSON/DB/anything external
Transport     — DTOs for wire formats (JSON), toDomain/fromDomain at the boundary (separate skill, not this one)
Persistence   — Row types matching storage shape, toDomain/fromDomain at the boundary (this skill)
```

`Domain.hs` has no serialization of any kind — no `ToJSON`/`FromJSON`, no `Generic` deriving for that purpose. Nothing in this skill should assume otherwise or reintroduce that coupling.

## A note on churn in this file

`Domain.hs` has changed twice already since this skill was first written: once removing the offer/decline waitlist mechanism, and again removing `Slot`/`BookedSlot` as a sum type entirely (`AvailableSlot` is now the only slot type, with no post-match existence at all — see `deleted-on-match`). Rules in this file have been retired, added, and had their live cases disappear as a result (`sealed-type-replay` currently has nothing to replay; `atomic-multi-table-write` no longer means "keep two FKs in sync" the way it once did). This is expected, not a sign of instability — re-read `Domain.hs` fresh every time rather than trusting that a rule's original justification still holds.

## `discriminator-column-tables` (Rule 1) — Sum types become one table, a discriminator column, and nullable state-specific columns

For every multi-constructor domain type without a separate status field, generate **one table**, not one table per constructor. The live cases in the current domain:

- `HealthcareRequest` (`Submitted | Triaged`) -> `healthcare_requests`, `state IN ('submitted', 'triaged')`.
- `Appointment` (`Open | Closed`) -> `appointments`, `state IN ('open', 'closed')`.

`Slot` is **not** a case of this rule anymore — `AvailableSlot` is the only slot type, so there's nothing to discriminate. See `deleted-on-match`.

Write **one `CHECK` constraint per valid constructor shape**, derived mechanically from the constructors themselves — every combination of which nullable columns are set must correspond to exactly one constructor. See `migrations/0001_init.sql` for the current worked example — that file is the live reference; when generating SQL, derive it fresh from `Domain.hs` and write it to `migrations/` at the repo root, numbered sequentially.

This isn't redundant with `Domain.hs`'s own type-level guarantee — it's a backstop against backdoor writes (manual SQL, bad migrations, anything bypassing the generated Persistence module) that the type system can no longer see once data has left Haskell.

## `nullability-as-discriminator` (Rule 2) — Presence/absence sum types encode via nullability alone — no redundant discriminator

Where a sum type's cases differ *solely* by the presence or absence of a payload, a single nullable column — or a small fixed set of them — already carries full information about which case applies. Adding a parallel `TEXT` discriminator column next to it duplicates information the nullability pattern already states.

Two live cases:

- **`DoctorRequirement` (`AnyDoctor | SpecificDoctor DoctorId`)**: `required_doctor_id UUID NULL REFERENCES doctors(id)`. `NULL` means `AnyDoctor`; a set value means `SpecificDoctor`.
- **`RoutineDue` (`RoutineAnytime | RoutineNotBefore UTCTime | RoutineNotAfter UTCTime | RoutineWithin UTCTime UTCTime`)**: two nullable columns, `due_not_before` / `due_not_after`, give exactly 2² = 4 nullability combinations — a genuine bijection:

  | `due_not_before` | `due_not_after` | case |
  |---|---|---|
  | NULL | NULL | `RoutineAnytime` |
  | set | NULL | `RoutineNotBefore` |
  | NULL | set | `RoutineNotAfter` |
  | set | set | `RoutineWithin` |

  `EmergencyDue`/`UrgentDue` reuse `due_not_after` (structurally identical to `RoutineNotAfter`) rather than getting their own columns.

A third case as of this revision: **`CloseReason`'s `Cancelled AppointmentParty UTCTime`** carries a cancellation timestamp that only `Cancelled` has (`Completed` has none, `NoShow` has a party but no timestamp). `cancelled_at` is a single nullable column, populated only when `close_reason = 'cancelled'`, `NULL` otherwise — the same presence/absence pattern, just with one column instead of a pair.

When a new nullable field is proposed, check first whether it's actually encoding a presence/absence sum type per this rule before reaching for a separate discriminator column.

## `ord-ranking-check` (Rule 3) — Check `Ord`-bearing types against their derived ranking only if something actually sorts by it at the SQL level

`HealthcareRequestPriority` and `RoutineDue` both derive `Ord` with non-trivial rankings, but **ordering happens exclusively in `Domain.hs`** — `checkWaitlist`'s `sortOn priority` runs in memory over already-decoded values, fetched via a plain (unordered) query. No integer tier-rank column exists in this schema, and none should be added, unless a future query genuinely needs `ORDER BY` on priority at the SQL level.

## `join-tables-not-arrays` (Rule 4) — Multi-valued fields become join tables, never array columns

No domain field currently needs this rule. Kept for if/when a future `Set a`/`[a]` field appears: such a field becomes a separate join table with real foreign key constraints, never a native array column, even though Postgres supports them.

## `fail-loudly-on-decode` (Rule 5) — Decoding fails loudly, never clamps or coerces silently

Any function reading a column value back into a domain type must produce an explicit error on anything that doesn't correspond to a valid domain value.

```haskell
data DecodeError = InvalidDuration Int | InvalidTier Text | InvalidState Text | ...
  deriving (Show, Eq)

decodeDuration :: Int -> Either DecodeError Duration
decodeDuration 15 = Right QuarterOfAnHour
decodeDuration 30 = Right HalfAnHour
decodeDuration 60 = Right OneHour
decodeDuration n  = Left (InvalidDuration n)
```

This matters specifically because of `discriminator-column-tables`'s threat model: a `CHECK` constraint defends against backdoor writes at insert time, but anything that somehow still gets through must surface as a decode failure when read back — not get silently coerced into a default that hides the corruption. Where `Domain.hs` itself exposes a smart constructor for the value being decoded (e.g. `mkRoutineWithin`), the decode function must go through it rather than constructing the value directly.

Two named error constructors worth calling out specifically, both defensive rather than expected to ever fire: `InvalidPriorityShape` (an emergency/urgent tier row with a `due_not_before` set, or missing its `due_not_after` — structurally impossible per the CHECK constraint, checked anyway as the last line of defense) and `InvalidTriagedRowShape` (a `state = 'triaged'` row missing one of its required triage columns — same category of "should be impossible, read is the last line of defense").

## `atomic-multi-table-write` (Rule 6) — Multi-table writes are enforced by transaction discipline, not a trigger

This rule's *mechanism* changed with the `Slot` redesign — worth reading the history, not just the current rule, since the reasoning generalizes.

**Previously**: `slots.appointment_id` and `appointments.slot_id` were two independent columns in two different tables that had to stay in agreement — a genuine cross-table *consistency* problem, solved by writing both in one transaction (no trigger).

**Now**: `appointments` doesn't reference `slots` at all — a matched slot is deleted (`deleted-on-match`), and `appointments` hard-copies the doctor/time/duration facts directly. There's no consistency pair left to keep in sync. But the underlying discipline still applies to a different problem: **matching is an atomic insert-and-delete** — the `appointments` row must be inserted and the `slots` row deleted **in the same transaction**, or a crash between the two steps leaves either a phantom available slot for an already-matched request, or a matched appointment whose slot was never actually claimed.

Same standard as before: whatever `Persistence.hs` function performs a match (or a `reassignSlot`-driven rebind) must hold one `Connection` for the whole operation via `withTransaction`, not check out separate connections per statement. No trigger — this is enforced by the shape of the function itself (see `SKILL.md`'s Persistence module section on where `withTransaction` boundaries live).

## `id-types-plain` (Rule 7) — ID types need no special handling

Domain ID newtypes (`DoctorId`, `PatientId`, `HealthcareServiceId`, `HealthcareRequestId`, `SlotId`, `AppointmentId`) are not sealed — their constructors are exported. Extract the underlying `UUID` with plain pattern matching; no helper function or typeclass is needed.

## `minimal-types-minimal-tables` (Rule 8) — Minimal domain types get minimal tables

`Doctor` and `Patient` are deliberately minimal in `Domain.hs` (`id` and `name` only). Their tables must match — do not add columns speculatively. If `Domain.hs` gains a field, the table gains the matching column; not before.

## `sealed-type-replay` (Rule 9) — Reconstructing a sealed type's hidden state replays through existing exported functions, never a new raw constructor — currently no live case

This rule previously had exactly one live case: `BookedSlot`, reconstructed by replaying a fabricated `TriagedHealthcareRequest` through `satisfyHealthcareRequest` to satisfy its `matches` gate. **`BookedSlot` no longer exists** — the `Slot` redesign removed it entirely, along with the sealing it needed.

Every type in the current `Domain.hs` is open: `AvailableSlot`, `OpenAppointment`, and (as of the commit that removed `closeAppointment`) `ClosedAppointment` are all exported with `(..)`. None of them need replay — reconstruction from a row is plain direct construction, and encoding for storage is plain pattern matching, no domain function involved either direction.

This rule is kept in the skill, not deleted, because it's a real technique that will matter again the moment `Domain.hs` seals something new — but there is nothing to apply it to right now. Don't force a case onto this rule just to have an example; if nothing is sealed, say so and move on, the same way this section now does.

## `sealed-value-decomposition` (new) — Extracting fields from an already-held sealed value needs a read-only `Domain.hs` accessor; `sealed-type-replay` doesn't apply

This is a different problem from `sealed-type-replay`, even though both involve a sealed constructor, and it's worth being precise about the distinction rather than reaching for replay out of habit whenever a sealed type is involved:

- `sealed-type-replay` is about **reconstruction**: building a sealed value *from storage*, where you don't yet have the value and need to produce one via a gate function (`satisfyHealthcareRequest`'s `matches` check, historically, for the now-removed `BookedSlot`).
- `sealed-value-decomposition` is about **decomposition**: you already have a fully-valid sealed value in memory (e.g. a `RoutineDue` that's actually a `RoutineWithin`) and need to pull its fields back out to encode it for storage. There is no gate to replay through here — nothing to construct, nothing to prove — the value already exists and is already valid. Replay-through-a-function is simply the wrong tool for this direction.

The live case: `RoutineDue`'s `RoutineWithin` constructor is not exported (`RoutineDue (RoutineAnytime, RoutineNotBefore, RoutineNotAfter)` — `RoutineWithin` deliberately excluded, protecting `mkRoutineWithin`'s `from <= to` invariant at construction time). `encodePriority` needs `RoutineWithin`'s two `UTCTime` fields to populate `due_not_before`/`due_not_after` when writing a `Routine (RoutineWithin lo hi)` value — but can't pattern-match on it from outside `Domain.hs`.

The fix, and the only correct one: a **read-only accessor in `Domain.hs` itself**, added deliberately and validated (not fabricated silently in `Persistence.hs`, and not achieved by exporting the constructor, which would reopen the construction-time invariant to every caller):

```haskell
-- Read-only extraction over an already-valid value — cannot construct or
-- fabricate a RoutineWithin, so this does not reopen mkRoutineWithin's
-- from <= to invariant. Exists so downstream layers (e.g. Persistence) can
-- encode an in-memory RoutineDue without needing RoutineWithin's
-- constructor exported.
routineWithinBounds :: RoutineDue -> Maybe (UTCTime, UTCTime)
routineWithinBounds (RoutineWithin from to) = Just (from, to)
routineWithinBounds _                       = Nothing
```

This surfaced during real `Persistence.hs` generation (Claude Code correctly refused to fabricate an extraction path and flagged it instead), was routed to the domain-modeling discussion rather than patched around, and came back as this accessor. That's the correct path any time this pattern recurs: a sealed constructor that needs its fields read back out for encoding is a `Domain.hs` gap, not a `Persistence.hs` problem to solve by any other means (no `unsafeCoerce`, no re-deriving the value's shape by other means, no exporting the constructor "just for this one case").

## `no-delete-on-consumption` (Rule 10) — A row's mere existence is *not* the discriminator for healthcare requests; they are never deleted on consumption

`healthcare_requests` rows are **never deleted**, and there is **no third `state` value** for "matched" — nothing transitions a request back to waiting, and nothing marks it matched in place either.

"Currently waiting" is a **derived** condition: a triaged request with no corresponding `appointments` row.

```sql
SELECT hr.*
FROM healthcare_requests hr
LEFT JOIN appointments a ON a.healthcare_request_id = hr.id
WHERE hr.state = 'triaged' AND a.id IS NULL;
```

`appointments.healthcare_request_id` is `UNIQUE`, so this join can never produce more than one `appointments` row per request. A failed `reassignSlot` doesn't free the original request back to this query's result set; re-triage reuses the **same** `healthcare_requests` row (`details.id` is preserved from the closed appointment's embedded request, so `persistTriagedRequest` updates the existing row in place — see `docs/decisions.md`'s corrected "No lineage tracking..." entry). There is no lineage to track because there's only ever one row for that request, not two.

This rule is the deliberate mirror image of `deleted-on-match` — the same "does the schema honor what `Domain.hs` actually asserts about a thing's persistence" discipline, applied to two aggregates that turned out to need opposite answers. Don't let the two rules' existence talk you into treating them as interchangeable, or into assuming one implies the other for a third aggregate — check `Domain.hs`'s own wording each time.

## `deleted-on-match` (new) — Slots have no post-match existence; a matched slot's row is deleted, not flagged

`Domain.hs`'s own comment on `AvailableSlot`: *"a slot has no existence independent of matching: it is available until claimed, then fully absorbed into the appointment... the original slot ceases to be referenced or exist once matched."* `OpenAppointment` hard-copies `DoctorId`/`UTCTime`/`Duration` directly rather than referencing a slot by ID — so once matched, nothing in the domain model ever again asks "what slot was this."

Consequence for the schema: `slots` has **no `state` column and no `appointment_id`** — every row means exactly one thing, "available, not yet matched." The moment `satisfyHealthcareRequest` or `reassignSlot` matches a slot, `Persistence.hs` deletes that row as part of the same transaction that inserts (or updates) the `appointments` row (`atomic-multi-table-write`).

Two things this deliberately does **not** do, both real decisions rather than oversights:

- **No automatic recreation of a vacated slot on reassignment.** When `reassignSlot` moves an appointment to a new slot, the old time does not automatically reappear as a fresh `AvailableSlot`. If the vacated time should become bookable again, that's a separate, explicit call to the normal slot-creation operation — not something a reassignment triggers as a side effect. This mirrors `Domain.hs`'s own refusal to decide this (*"that's the caller's concern, not `Domain.hs`'s"*).
- **No historical/audit record of a slot's existence after it's matched.** Once deleted, there is no row anywhere recording that a given doctor/time/duration slot ever existed and got booked — that fact now lives only inside the `appointments` row it became, with no back-reference. If audit/reporting on slot lifecycle is ever needed, it requires a separate mechanism (e.g. an append-only log) — it cannot be recovered from `slots` after the fact.

`appointments` additionally enforces `UNIQUE (doctor_id, start_time)` scoped to `state = 'open'` (a partial index) — since nothing at slot-creation time cross-checks against existing open appointments, this is the actual backstop against a double-booking making it all the way to two live appointments for the same doctor at the same time.

## `uniqueness-races-are-outcomes` (new) — A write whose success depends on a row's observed shape staying put needs affected-rows detection, never a caught exception

If a `UNIQUE` constraint exists specifically to enforce a domain invariant (not just data hygiene) — e.g. `appointments.healthcare_request_id UNIQUE` enforcing "a request is matched at most once" — the `Persistence.hs` function writing against it must detect a violation via a conditional insert (`INSERT ... WHERE NOT EXISTS (...)`, checking `n > 0`, same pattern as `deleteSlot`), not by letting the database throw and catching/ignoring a `SqlError`. `deleted-on-match`'s `deleteSlot` was the first instance of this pattern; treat it as the template, not a one-off.

When adding a new `UNIQUE` constraint anywhere in the schema, ask explicitly: is this hygiene (duplicate prevention on data that's never concurrently contested) or a race guard (two legitimate concurrent operations could both pass business-logic checks and only collide at the DB)? If the latter, it needs this treatment and a corresponding named outcome in whatever `Service.hs` function writes through it.

The rule isn't limited to constraints literally named `UNIQUE` in the schema — `deleteSlot` (the original instance) guards a row's mere *existence* at delete time, not a `UNIQUE` violation, and `persistClosedAppointmentIfOpen` (below) guards a *state* (`state = 'open'`) rather than either. What all three share, and what actually triggers this rule, is: a write whose success depends on the row still being in the shape the caller last observed it in, where a concurrent writer could have changed that shape in between. Any such write needs the conditional-write-plus-affected-rows-check treatment, whether or not a `UNIQUE` constraint happens to be involved.

**Live case:** `insertIfUnclaimed` in `Persistence.hs` guards `appointments.healthcare_request_id UNIQUE` this way for `persistMatchedAppointment` — two concurrent waitlist-to-slot matches can both pick up the same triaged request (via two different slots' scans) before either commits; the conditional insert's affected-row count, not a caught constraint-violation exception, is what tells `persistMatchedAppointment` which one lost. This also interacts with `atomic-multi-table-write`: because the slot-delete and the request-insert are two independent race checks inside the same operation, losing the *second* one after the *first* already succeeded requires rolling back the first, not just reporting the loss. `persistMatchedAppointment` still uses `withTransaction` for this (not manual `begin`/`commit`/`rollback` — that would give up `withTransaction`'s blanket rollback-on-any-exception safety for the narrower "rolls back only on the paths I explicitly coded" behavior, reintroducing the exact risk `atomic-multi-table-write` exists to prevent). Instead, an internal, unexported exception type (`MatchAbort`) is thrown to unwind out of `withTransaction`'s action and trigger its own rollback, then caught immediately outside it and translated back into the corresponding `MatchPersistOutcome` — the exception never escapes the function, so it doesn't cross a module boundary and doesn't touch this file's "no exceptions for business errors" discipline.

**Second live case:** `persistClosedAppointmentIfOpen` guards a plain state-transition race, no `UNIQUE` constraint involved at all — `Service.closeAppointment` fetches an appointment, confirms it's `Open`, then writes; between the fetch and the write, a concurrent second close on the same row could pass the same fetch-time check and silently overwrite which reason the appointment closed for. The `UPDATE` is conditioned on `state = 'open'` (`WHERE id = ? AND state = 'open'`), and `AlreadyClaimed` (zero rows affected) is reported back as the same `AppointmentAlreadyClosed` the initial fetch would have produced — the caller doesn't need to distinguish "already closed when I checked" from "closed by someone else a moment later." Chosen over the slot-creation race (still deferred, pending practice validation) because this one silently destroys information (which `CloseReason` won) rather than just producing a visible, correctable duplicate row.

## The Persistence module

All Persistence-layer code lives in a single module, `src/Persistence.hs` (module name `Persistence`) — mirroring `Domain.hs`'s own single-file convention. Do not create one file per aggregate; add new `Row` types and functions to this one file as the domain grows.

Conventions established for this module, settled across the schema and Persistence-writing sessions, apply uniformly with no case-by-case exceptions:

- **DB library: `postgresql-simple`.**
- **Every function takes a plain `Connection`, never `ConnectionPool`, with no exceptions.** `ConnectionPool` (`type ConnectionPool = Pool Connection`) exists only for whatever calls into this module from outside (`Service.hs`, not yet written) to check out a `Connection` via `withResource` for a unit of work — including holding one connection across a whole `withTransaction` block spanning multiple `Persistence.hs` calls. A function that took `ConnectionPool` directly could only ever run as its own isolated unit of work, foreclosing composition into a larger transaction.
- **Row↔domain mapping is written by hand, never derived.** `FromRow` instances are hand-written field-by-field (`SomeRow <$> field <*> field <*> ...`, one line per column, commented with the column name) rather than `Generic`-derived. Writes use explicit tuples/lists at the `execute` call site, never a shared `ToRow` instance — this keeps the column list and the value list visible together at every call site, at the cost of some repetition across functions writing the same row shape.
- **`<$>`/`fmap` is the default** for a function with exactly one fallible sub-computation feeding pure construction. Reserve `do`-notation/`>>=` for genuinely multiple sequential fallible steps, or for chaining a fallible `IO` action's result into a further fallible computation (e.g. `fetchAppointment`'s health-request lookup feeding into `toDomainAppointment`).
- **Decode failures return `Either DecodeError X`, never throw.** No exceptions for "this row didn't decode."
- **Dedicated functions per domain operation, never a generic update dispatching on the value's shape.** E.g. `insertAvailableSlot`/`persistBookedSlot`(historical)/`persistFreedSlot`(historical), or `insertSubmittedRequest`/`persistTriagedRequest` — named to mirror the `Domain.hs` verb that produced the value being persisted, one clear meaning per function, no runtime dispatch a reader has to trace into.
- **Transaction boundaries live inside the function that needs them, not pushed up to the caller.** A function performing an operation requiring `atomic-multi-table-write` (e.g. persisting a match, a reassignment) calls `withTransaction conn $ do { ... }` internally — the caller passes in a `Connection` and gets one atomic operation; it isn't responsible for remembering to wrap anything itself. This was a deliberate choice: "the business action already defines its transactional scope."
- **ID generation** (`newAppointmentId`, `newHealthcareRequestId`, etc.) lives in `Service.hs`, not here — minting a new ID is an orchestration decision, not a fetch or a store. `Persistence.hs` only ever receives an already-minted ID as an argument; it never generates one.

For each domain aggregate with its own table(s), generate within `Persistence.hs`:

1. A `Row` type whose fields match the table's columns exactly, using unprefixed field names (`DuplicateRecordFields` + `OverloadedRecordDot`, matching `Domain.hs`'s own style) rather than `row`-prefixed names.
2. `toDomainX :: XRow -> Either DecodeError X` (suffixed per-aggregate, not bare `toDomain` — this is one flat module, not isolated per-aggregate examples, so names must not collide) — **but only where a decode failure is actually possible.** `Doctor`/`Patient` (`minimal-types-minimal-tables`) have no field that can fail to decode — no sum type, no enum, no invariant beyond what the field types already enforce — so their `toDomainX` functions are plain and total: `toDomainDoctor :: DoctorRow -> Doctor`, no `Either` wrapper. Don't blanket-wrap every `toDomainX` in `Either` out of habit; add it only where `fail-loudly-on-decode` actually has something to guard against.
3. `fromDomainX :: X -> XRow` — split by constructor where the domain type is a sum type with meaningfully different producers (e.g. `fromDomainSubmitted`/`fromDomainTriaged`, `fromDomainOpen`/`fromDomainClosed`), since the writing caller already knows which constructor it holds. Kept as one function only where the read direction has no such foreknowledge (e.g. `toDomainHealthcareRequest` stays unified, branching on `state`, since a fetch doesn't know in advance what it will find).
4. Fetch and store functions, mapping through `toDomainX`/`fromDomainX`.
5. A dedicated waitlist fetch, `fetchWaitlist`, implementing `no-delete-on-consumption`'s anti-join.
6. Atomic multi-table operations (matching, reassignment) per `atomic-multi-table-write`, transaction boundary owned internally.

See `references/persistence-pattern.md` for worked examples.

## When unsure

If a rule above doesn't cover a case that comes up, prefer the option that mirrors `Domain.hs`'s own structure most directly, and flag the ambiguity to the user rather than inventing a convention silently. When adding a genuinely new rule, give it a name in this same style before writing content under it. When a rule's live case disappears because `Domain.hs` changed, say so explicitly in the rule itself (as `sealed-type-replay` now does) rather than deleting the rule or leaving it silently describing something no longer true.