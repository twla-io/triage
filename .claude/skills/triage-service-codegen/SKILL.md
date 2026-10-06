---
name: triage-service-codegen
description: Generate the service (orchestration) layer, src/Service.hs, from triage's Domain.hs and Persistence.hs. Use this skill whenever creating, extending, or reviewing a Service.hs function that composes Domain.hs's pure functions with Persistence.hs's fetch/store functions — including naming a new wrapper, choosing its error/outcome type, or deciding whether a write needs a concurrency guard. Trigger this even if the user just says "add a service function for X" or "wire up booking" without mentioning Service.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or Persistence-layer generation — see triage-db-codegen instead.
---

# triage-service-codegen

Derive `src/Service.hs` from two sources:
- **`Domain.hs`** says *what* happens: its transitions, smart constructors and functions, and which facts a caller is the authority on.
- **`Persistence.hs`** says *how* it is stored: its writes, the outcomes they report, and its reads. It is itself derived from `Domain.hs` (`triage-db-codegen`).

This skill says only how those become use cases. It names no Domain type; `e.g.` marks an illustration, never a requirement.

- Read both files fresh every time. Existing `Service.hs` is output to check against these rules, never an example to copy.
- These are decisions already made: apply them, don't offer alternatives. Reasons are in `docs/decisions.md`.
- Service uses only what `Persistence.hs` exports and never writes SQL. A use case that needs a read `Persistence.hs` lacks adds it there first, by `triage-db-codegen`'s `reads-follow-cases`.
- If the sources leave something a rule needs undetermined, stop and ask. The fix belongs in `Domain.hs` or `Persistence.hs`, not in an invented convention.
- Rules apply to existing code. After a rule or a source changes, check every function against every rule, comments included.

## Use cases

### `function-per-use-case`
One public function per use case, each its own unit of work. The use cases are:
1. **Create an entity:** one per entity that is not a stage of another and not an element of a sealed collection (that grows by use case 4). It takes the new entity's fields, mints the id, inserts, and returns the value itself when nothing can fail. For an entity that is a sum type, only its entry case is created, named after that constructor as a verb (e.g. submit).
2. **Perform a transition:** one per transition `Domain.hs` defines (a function or a constructor). It fetches the stored value by id, checks its case (`request-state-answers-follow-the-lifecycle`), builds the next stage through `Domain.hs`, and persists it. A transition whose target records its source case is one use case: it accepts each source case, builds the target from the one it finds, and persists it under that case's guard.
3. **Apply a Domain function over stored values:** one per `Domain.hs` function that decides among stored values (e.g. picking one of many candidates). It fetches the inputs, calls the function, and persists its result through use case 2's write.
4. **Grow a sealed collection:** fetch the collection over the new element's extent (`Persistence.hs`'s `fetch<Collection>Overlapping`, the same read callers use), call the smart constructor, and persist the new element. The database constraint is the backstop. The smart constructor's decline and the constraint's violation are the same fact, so they are the same outcome.
5. **Read:** pass-throughs of `Persistence.hs` reads, under the same names, of these kinds:
   - **by id:** one per entity. A missing id is `<Entity>NotFound`; for an entity deleted on consumption, `Nothing` ("no longer available");
   - **all:** one per entity that is neither a sum type nor an element of a sealed collection (a small reference set);
   - **by case:** one per non-terminal case of a sum-typed entity, as the case's payload type;
   - **by time range:** a terminal case (nothing leaves it, so its rows only accumulate) is read by range only. The range is over a timestamp the case's stage adds to every row; if it adds none, over the timestamp of the stage it embeds. It takes two bounds, half-open `[from, to)`, and is named `fetch<Case><Entity>sBy<Field>`;
   - **the sealed collection:** the collection value itself over a time range `[from, to)`, named `fetch<Collection>Overlapping`. Callers take it apart only through the read-only accessor `Domain.hs` exports (`triage-db-codegen`'s `sealed-value-decomposition`).

   Anything narrower (one owner, one service) exists only when a use case needs it. A read `Persistence.hs` lacks is added there first.

Every use case checks that each id it is given exists (`error-vs-outcome-types`). Before writing a function, propose its signature, and flag it.

### `verifies-the-precondition`
When a Service function and the `Domain.hs` function it calls could share a name, the name goes to whichever one verifies the precondition the name claims. A pure `Domain.hs` function cannot know where its input came from, so a name claiming a stored state (e.g. "submitted", "waitlist") belongs to the Service function that fetched and checked it. Reads have no `Domain.hs` counterpart; they keep `Persistence.hs`'s names.

Names follow `Domain.hs`:
- **a transition** with a `Domain.hs` function takes that function's name with the source case it verifies inserted before the entity (`acceptSubmittedIntakeRequest`, `matchAcceptedIntakeRequestToSlot`). One without is `<verb><SourceCase><Entity>`, the verb from the target constructor (an adjective takes `mark`, e.g. `markAcceptedIntakeRequestStale`). A transition from several source cases names none.
- **a creation** is `create<Entity>`; the entry case of a sum type takes its constructor as a verb (e.g. submit); growing a sealed collection is `create<Element>`.
- **a use case 3 function** takes the `Domain.hs` function's name with the stored input the caller names by id inserted after the verb (e.g. `matchAvailableSlotByPriority`).

### `reads-apply-domain-order`
If `Domain.hs` has a sorting function over a read's element type (`sortBy<Key> :: [a] -> [a]`), the read's Service function applies it to the result. The order shown and the order the Domain decides by are then one implementation. Persistence's `ORDER BY` stays underneath.

## Answers

### `error-vs-outcome-types`
Two kinds of "this didn't simply succeed", never merged:
- **An error** (`Left`): a fact about the caller's request that no concurrent operation can change. Each fact is its own type, named for the fact. A fact about an entity carries what identifies it: `<Entity>NotFound` and `<Entity>Consumed` the id, `<Entity>InWrongState` and `MovedOn` the value as it is. A use case's facts are exactly those its shape implies:
  1. `<Entity>NotFound` for each entity it receives by id (a parameter, or an id inside a parameter's value) that is never deleted. It is checked in Service, never left to a foreign key. An entity deleted on consumption is the outcome `<Entity>Consumed` instead, used by every use case that can find that fact;
  2. `<Entity>InWrongState` if some case of the entity is reachable from none of the use case's source cases (`request-state-answers-follow-the-lifecycle`);
  3. the refusal of a `Domain.hs` function that declines because of the caller's inputs alone, named `<Subject>DoesNot<Verb><Object>` from the function's name (`matchIntakeRequestToSlot` → `IntakeRequestDoesNotMatchSlot`). A refusal caused by stored data, whether candidates read from storage (use case 3) or a sealed collection declining a new element (use case 4), is an outcome.

  With no fact, the use case returns its value directly (no `Either`). With one, that fact type is the `Left`. With several, the `Left` is `<Function>Error`, whose constructors are `<Function><Fact>`, each wrapping its fact.
- **A decode failure is not an error:** stored data violating the spec is a `500`. `decoded` raises `Persistence.hs`'s `DecodeError` as an exception.
- **An outcome** (`Right`): reality moved between two valid operations, which the caller reacts to.
  - A transition with a single guard returns `TransitionOutcome a = Transitioned a | MovedOn <entity>`.
  - A write whose `Persistence.hs` outcome has more constructors gets its own outcome type, one constructor per `Persistence.hs` constructor, translated one-to-one and named for the caller: `<Entity>AlreadyClaimed` becomes `<Entity>MovedOn` (after the re-read) or, for an entity deleted on consumption, `<Entity>Consumed`; `<Element>Overlaps<Collection>` keeps its name.
  - **Names:** the outcome type of a use case that calls a `Domain.hs` function is `<DomainFunction>Outcome` (e.g. `AddAvailableSlotOutcome`). Its success constructor is that function's name with the verb as a past participle, object first (`addAvailableSlot` → `AvailableSlotAdded`, `matchIntakeRequestToSlot` → `IntakeRequestMatchedToSlot`). A decline over stored candidates is `No<Subject><Verb>` (`matchByPriority` → `NoIntakeRequestMatched`).
  - A use case 3 function's outcome wraps the outcome of the write it persists through: one constructor per way its Domain function declines, plus one carrying that write's outcome, named after that outcome's type (e.g. `| MatchIntakeRequestToSlotOutcome MatchIntakeRequestToSlotOutcome`), since it can also carry a fact found before the write. No function's outcome type holds a constructor that function cannot return.

A lost race is never the caller's fault, so it is never an error. **An answer depends on the fact, not on which check found it.** A fact found before the write and the same fact found by the write's guard or constraint get the same outcome (e.g. a slot missing at fetch and a slot whose delete hits no row; a new element the smart constructor declines and one the constraint rejects). Only a fact no concurrent operation can change is an error. Service imports `Persistence` qualified, so its own types take the plain names; constructor names are distinct across every type the module defines or imports unqualified.

### `request-state-answers-follow-the-lifecycle`
When a use case finds a stored value in a case other than the one it expects, it compares the two over `Domain.hs`'s transition graph:
- **The current case is reachable from the expected one:** someone acted first. Answer `MovedOn` with the value as it is now.
- **It is not reachable:** the caller could never have seen the case it acted on. Answer `<Entity>InWrongState`.

Where a case records the stage it came from, reachability follows that record: the value is reachable from the expected case only if its recorded source is, or is reachable from, the expected case.

Write each split as an exhaustive `case` with no wildcard, so a new case forces a decision. Derive it from the graph; never choose answers case by case.

## Writes

### `guard-every-fetch-then-write-gap`
A use case that fetches, checks, then writes has a gap in which another operation can invalidate the check. The write's guard (`Persistence.hs`'s affected-rows outcome) closes it. When the write reports a lost race, read the value once more and answer `MovedOn` with what it is now; since cases only move forward, that read always finds a later case. Never retry: the caller decided from what it saw. The one exception: a use case that accepts several source cases continues from another of its source cases when the re-read finds one (cases only move forward, so this ends); otherwise it answers `MovedOn`. Its write keeps the exact source guard, never `state IN (…)`: the guard also proves the row is what the value was built from. The guards protect the rows written. The candidates a decision was made from are a snapshot: one that arrives after the read is served by the next decision, as if it had arrived after the write. Undoing such a decision is a domain action (close and re-offer), never a mechanism. When proposing any fetch-then-write function, state what can change in the gap as part of the proposal.

### `pool-in-connection-scoped`
Every public function takes `ConnectionPool`, checks out one `Connection` with `withResource`, and uses it for every `Persistence.hs` call it makes. Service functions are the composition root; nothing composes them.

## Parameters

### `caller-supplied-facts`
A fact the caller is the authority on (a timestamp it observed, a reason, a triage judgment, the fields of something being created) is a parameter. Service never calls `getCurrentTime`. Where the caller is the authority on a whole `Domain.hs` value, take it whole rather than as its fields. Ids are different: they carry no meaning, so Service mints them.

### `stored-facts-by-reference`
Something that already exists in storage comes in as its id and is fetched. The caller never supplies its fields or a whole value of it: the database is the authority on facts it holds.

## When unsure
Prefer the option that mirrors `Domain.hs` most directly, and flag the ambiguity rather than inventing a convention. A new rule gets a kebab-case name before its text.
