---
name: triage-db-codegen
description: Generate the database schema and Persistence-layer module from triage's Domain.hs. Use this skill whenever creating, regenerating, or extending SQL table definitions or a Persistence module (Row types, toDomain/fromDomain, fetch/store functions) for the triage domain model. Trigger this even if the user just says "create the database tables" or "write the persistence layer" without mentioning Domain.hs explicitly, as long as the triage domain model is the source.
---

# triage-db-codegen

Derive `migrations/` and `src/Persistence.hs` from `src/Domain.hs`.

`Domain.hs` is the only specification: every type, name, case and transition comes from it. This skill says only **how** a kind of Haskell construct is stored and read back, plus project conventions `Domain.hs` can't express. It names no Domain type; `e.g.` marks an illustration, never a requirement.

- Read `Domain.hs` fresh every time. Existing SQL and Haskell are output to check against these rules, never examples to copy.
- These are decisions already made: apply them, don't offer alternatives. Reasons are in `docs/decisions.md`.
- If `Domain.hs` leaves something a rule needs undetermined (a value without a name, two readings of a name), stop and ask. The fix belongs in `Domain.hs`, not in an invented convention.
- Rules apply to existing code. After a rule or `Domain.hs` changes, check every table and function against every rule, comments included.
- Write SQL to `migrations/` at the repo root, numbered sequentially.

## Names

### `names-come-from-domain`
1. **Values.** A value is named by its record field, or by its constructor if the constructor has exactly one field; a sealed type's values, by its exported read-only accessors. A value takes the innermost name above it. An ID newtype is not a name: it is the value itself, and gives the foreign key; a column holding one ends in `_id` (unless its name already does). A sealed newtype over one value is not a name either: it is the value itself, encoded through its accessor and decoded through its smart constructor; its invariant is a `CHECK` on the column named above it.
2. **Columns.** A column is its value's name in snake_case. Records nested in a row are flattened into it, with no prefix. Within one table, values with the same name share one column. `Domain.hs` uses the same name only for the same fact.
3. **Tables.** A table is named after the collection its rows form. If `Domain.hs` has a type whose elements are exactly these rows, the table takes its name in snake_case. Otherwise it takes the row type's name, pluralized.
4. **Stored enumeration values** are constructor names in snake_case.
5. **Conventions:** a table's own sum type is discriminated by a column named `state`; Postgres objects the schema adds (constraints, triggers, functions) are named `<table>_<purpose>`.

**Check:** every table and column name traces back to a `Domain.hs` name through these five points.

## Storage

### Representations
- Newtype over `UUID` → `UUID`; the `id` field is the primary key, and a value of another entity's ID type is a foreign key to that entity's table.
- `UTCTime` → `TIMESTAMPTZ`; `Text` → `TEXT`; `Maybe a` → nullable.
- An enumeration of amounts of time (a type with a conversion to `NominalDiffTime`) → `SMALLINT` whole minutes, with `CHECK (col IN (…))` over its values.
- Any other enumeration (only nullary constructors) → `TEXT` with `CHECK (col IN (…))`.
- An enumeration derives `Enum, Bounded` in `Domain.hs`; its stored values, its `CHECK (col IN (…))` and its decoder are all listed from `[minBound .. maxBound]`. One that doesn't is a gap in `Domain.hs`: stop and ask.
- A sum type with fields can't derive `Enum, Bounded`: its stored values are listed from its constructors by hand, and its encoder is a total `case`, so `-Wall` flags a new constructor until the lists are updated.

### `minimal-types-minimal-tables`
A table has exactly the columns its Domain type's values give it. Nothing speculative.

### `join-tables-not-arrays`
A multi-valued field (`Set a`, `[a]`) becomes a join table with foreign keys, never an array column.

### `discriminator-column-tables`
An entity is a type carrying its own ID newtype as `id`, directly or through an embedded stage. An entity that is a sum type (its cases being stages of one identity) becomes **one** table: a `state` column plus every case's values as nullable columns. A column required in every case is `NOT NULL` in the table itself. The stage types are its cases, not entities of their own. A nested sum type gets a discriminator column, named after the field that holds it, only when its cases can't be told apart by which columns are set (`nullability-as-discriminator`).

**Derive:** build a table of constructors × columns, marking each cell *required*, *NULL* or *optional*:
- a column of an embedded stage is *required*;
- a column of a stage the constructor doesn't contain is *NULL*;
- a column is *optional* only if it is a `Maybe` field, or belongs to a nested sum type (with its own CHECK, or needing none);
- *NULL* wins over *optional*: a column is optional only inside a stage the constructor contains;
- a nested discriminator column is *required* wherever the stage holding its field is present.

Write one named CHECK per constructor, `state <> 'x' OR (…)`, naming every non-optional column except those `NOT NULL` in the table. Postgres requires every CHECK on a table to hold, so each must be an implication. A case whose payload records which stage it came from gets one CHECK per inner constructor. A nested sum type gets one CHECK over its discriminator and fields; one whose every combination is valid needs no CHECK, and its columns are *optional*. A nested type's CHECK constrains rows where its stage is present; the per-state CHECKs make its columns NULL elsewhere.

These CHECKs are the backstop for writes that bypass `Persistence.hs`.

**Check:** a DB test reads the table's real columns from `information_schema`, fails on any column missing from its classification table, and, for every constructor, requires a stray value in each NULL column and a missing value in each required column to be rejected.

### `nullability-as-discriminator`
A nested sum type whose cases each set a different combination of required columns gets no discriminator column. Which columns are set tells the case; an extra column would only repeat that, and could contradict it. The type's CHECK lists each case's combination. An inner case is identified by the combination of columns it sets; a case that sets none, by none of its siblings' columns being set. CHECKs and decoding use the same combination. If two cases set the same columns, it needs a discriminator (`discriminator-column-tables`).

### `ord-ranking-check`
An `Ord` instance is evaluated in memory. Add a rank column only when a query must `ORDER BY` it.

### `cross-table-invariants-need-a-shadow-table`
Only a sealed type's invariant becomes a constraint.
- **Single value:** an invariant a sealed type declares over one value becomes a `CHECK`.
- **Translating the condition:** the `CHECK` is the smart constructor's condition, operator for operator. A `Data.Char` class predicate becomes its POSIX bracket class in a regex: `isSpace` → `[:space:]`, `isDigit` → `[:digit:]`, `isAlpha` → `[:alpha:]`, `isUpper` → `[:upper:]`, `isLower` → `[:lower:]`. A quantifier over the text becomes a regex match: `T.any p` → `col ~ '[[:p:]]'`, and `not (T.all p)` → `col ~ '[^[:p:]]'`. Postgres's classes depend on the locale and may accept a few Unicode characters that `Data.Char` rejects. This is acceptable, because decoding goes back through the smart constructor, so the `CHECK` may be looser but never stricter.
- **Collection:** one declared over a collection of stored rows (a sealed collection type) becomes an `EXCLUDE` or `UNIQUE` constraint. A check in Service is never enough.
- **Across two tables:** when the collection's rows live in two tables, a trigger-maintained shadow table, named after the collection type, holds one row per element. Its columns are fixed by convention:
  - the key the invariant groups by, named as that value;
  - `during`, the element's extent (e.g. a `TSTZRANGE`);
  - `source`, the element type's constructor that the row came from;
  - one unique foreign key per source table, named after that table's ID type in snake_case (`ON DELETE CASCADE` where the source row can be deleted).

  A CHECK ties `source` to exactly one key, and the invariant is the constraint. The table has no primary key (its unique foreign keys identify a row) and no foreign key on the grouping key (the source rows carry it). An `EXCLUDE` mixing `=` on a scalar with `&&` needs `btree_gist`.

The triggers must keep the shadow table equal to the collection. A source row belongs to the collection while its case's payload is the element constructor's field type; a later stage that only embeds it does not. A trigger watches updates only where the source table is updated; it has no column list, so a new column can't be missed. Domain time intervals are half-open, `[start, end)`, which is `tstzrange`'s default.

**Check:** a DB test writes a violating row directly, bypassing Domain, and expects the database to reject it.

## Row lifetime

### `no-delete-on-consumption`
A value that its next stage embeds whole is never deleted. The transition updates its row in place. No row is flagged as "used"; the current stage is the discriminator.

### `deleted-on-match`
A value that a transition consumes without any Domain type keeping it (its facts are copied, not embedded) is deleted by that transition. The write takes the consumed value as an argument, as the Domain function does, and deletes it before writing the successor, which may take over its extent. Nothing recreates it, and nothing records its past existence.

## Writes

### `updates-follow-domain-transitions`
An `UPDATE` may change a row's case from A to B only if `Domain.hs` defines A → B, as a function or constructor. It is guarded with `WHERE id = ? AND state = 'A'`, one source case per write, never `state IN (…)`. Each entity table gets one insert; a sum-typed entity is inserted only in its entry case.

- **Finding A:** A is the case whose *whole* payload is exactly the transition's input type.
  - A constructor that embeds an earlier stage is not that stage.
  - Look through a wrapper to each inner constructor.
- **Terminal cases:** a case whose payload nothing consumes is terminal.
- **Field access** never defines a transition.
- **Stop and ask** if two non-terminal cases share a payload type.

Derive the transition table fresh from `Domain.hs` each time; don't keep a copy.

### `uniqueness-races-are-outcomes`
A write that succeeds only if a row still has the shape the caller saw (it still exists, or it is still in the same case) detects a lost race from the affected-row count of a conditional statement. It reports the result as an outcome, never as a caught `SqlError`. Each distinct way a write can fail that the caller can act on gets its own outcome constructor: one per guarded row that can lose a race, and one for an `EXCLUDE` violation. Names come from `Domain.hs`: a write with a single guard and nothing else returns `ClaimOutcome = Claimed | AlreadyClaimed`; a write guarding several rows returns `<TargetCase>ClaimOutcome = <TargetCase>Claimed | <Entity>AlreadyClaimed …` (one per guarded row; `<TargetCase>` is the target case's constructor, e.g. `Appointed`); an insert into a collection guarded by a shadow table returns `<Element>InsertOutcome = <Element>Inserted | <Element>Overlaps<Collection>`. Before adding a `UNIQUE` constraint, decide whether it prevents duplicates or guards a race. If it guards a race, it needs this treatment and a named outcome in Service. The one exception is an `EXCLUDE` violation (`23P01`), which has no affected-rows equivalent: the write that can trigger one catches exactly that code and rethrows anything else. Catch it only where a legitimate write can cause it (a new element). A successor that takes over a consumed element's extent cannot; its violation is a bug and propagates.

### `state-guard-is-freshness`
The state guard also proves the row is the one the caller read, because of two properties:
1. no transition leads back to an earlier case;
2. every `UPDATE` changes the case.

So there are no version columns. Check both properties whenever `Domain.hs` changes. If either breaks, stop and ask: a row version is the known answer. Tables that are never updated need nothing.

### `atomic-multi-table-write`
A transition that writes more than one table runs in one `withTransaction`, owned by the function that performs it. If a later step loses its race after an earlier one succeeded, an internal, unexported exception rolls the transaction back and is caught just outside it. Don't use manual `BEGIN`/`ROLLBACK`.

**Check:** a DB test makes the later step lose and asserts the earlier write was rolled back.

## Reading

### `reads-follow-cases`
Generate the reads `Domain.hs` determines:
- **by id:** one per entity table;
- **all:** one per entity that is neither a sum type nor an element of a sealed collection (those are read through the collection, by time range);
- **by case:** for each case of an entity's sum type, all rows in that case, decoded as the case's payload type. A terminal case (nothing leaves it) is read by time range only, over a timestamp its stage adds to every row, else over the timestamp of the nearest stage it embeds;
- **the sealed collection over a range:** the entries whose extent overlaps a time range `[from, to)`, from its source tables in one snapshot (`one-snapshot-per-read`), rebuilt through its smart constructor (`sealed-type-replay`). It is the only read of the collection: callers read it, and a use case growing the collection passes the new element's extent as the range. Its shadow table only enforces the invariant; reading through it is a performance change, made only when measured. The whole collection is never read.

Read names, shared with `triage-service-codegen` (plurals are English plurals): by id `fetch<Entity>`; all `fetch<Entity>s`; by case `fetch<Case><Entity>s`; terminal range `fetch<Case><Entity>sBy<Field>`, two bounds, half-open `[from, to)`; the collection over a range `fetch<Collection>Overlapping`, two bounds, half-open `[from, to)`.

A narrower read (one owner, one service) exists only when a Service use case needs it, and is added then, through `triage-service-codegen`. It is named after the case it returns plus its filter, takes one parameter per value it narrows by, and decodes through the same case decoder.

### `reads-have-a-defined-order`
Every read that returns a list has an `ORDER BY`, ascending; Postgres guarantees no order without one.
- **A range read** sorts by its range's timestamp.
- **Otherwise, a read by case** sorts by the timestamp its case's stage adds; with none, by the nearest embedded stage's.
- **Otherwise** it sorts by the entity's non-ID fields, in declaration order.

A sorting function in `Domain.hs` may reorder the result on top of this, in Service (`triage-service-codegen`).

### `one-snapshot-per-read`
A read built from several queries runs them in one `REPEATABLE READ` transaction.

### `fail-loudly-on-decode`
Decoding returns `Either DecodeError`, one constructor per kind of failure, and never defaults or coerces a value. `DecodeError` has an `Exception` instance, so Service can raise it. Check shapes the CHECKs "make impossible" anyway.

### `sealed-type-replay`
Build a sealed type from storage only through its exported smart constructor. A refusal is a `DecodeError`.

### `sealed-value-decomposition`
Encoding a sealed value uses a read-only accessor that `Domain.hs` exports. If none exists, it's a gap in `Domain.hs`: stop and ask. Never export the constructor or its field names, and never work around it.

### `id-types-plain`
ID newtypes have exported constructors. Unwrap the `UUID` by pattern matching, with no helper functions.

## `Persistence.hs` conventions
- One module. Uses `postgresql-simple`.
- **Connections:** every function takes a plain `Connection`. `type ConnectionPool = Pool Connection` is defined here for Service. Transactions live inside the function that needs one.
- **Rows:** one `Row` type per table that Haskell reads (a shadow table gets none), with unprefixed field names (`DuplicateRecordFields`, `OverloadedRecordDot`). A row field and a `Domain.hs` accessor can share a name (both come from `Domain.hs`): refer to the accessor qualified (`Domain.<name>`) and don't bind locals with either name.
  - `FromRow` is written by hand, one `field` per column, each commented with its column name.
  - Writes pass explicit tuples at the `execute` call. There is no `ToRow`.
- **Decoding:**
  - `toDomain<Type>` returns `Either DecodeError` only where decoding can fail; otherwise it is total.
  - `fromDomain<Stage>` is split per case of a sum type. The read direction is one function that branches on the discriminator.
  - Prefer `<$>` for a single fallible step, and `do` for chained ones.
- **Functions:** creation is `insert<Record>`; a transition is `persist<TargetRecord>`, one function per target stage, never a generic update over any case. When the value records its source case, the function takes that case's guarded statement from the value.
- **IDs** are minted in Service, never here.

## When unsure
Prefer the option that mirrors `Domain.hs` most directly, and flag the ambiguity rather than inventing a convention. A new rule gets a kebab-case name before its text.
