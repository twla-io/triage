---
name: triage-service-codegen
description: Generate the service (orchestration) layer, src/Service.hs, from triage's Domain.hs and Persistence.hs. Use this skill whenever creating, extending, or reviewing a Service.hs function that composes Domain.hs's pure functions with Persistence.hs's fetch/store functions — including naming a new wrapper, choosing its error/outcome type, or deciding whether a write needs a concurrency guard. Trigger this even if the user just says "add a service function for X" or "wire up booking" without mentioning Service.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or Persistence-layer generation — see triage-db-codegen instead.
---

# triage-service-codegen

`Domain.hs` is the single source of truth; `Persistence.hs` is derived from it per `triage-db-codegen`. `Service.hs` sits above both — it orchestrates `Domain.hs`'s pure functions with `Persistence.hs`'s fetch/store functions, one function per real-world use case. Read `Domain.hs` and `Persistence.hs` fresh before generating or extending anything here, per the same discipline `triage-db-codegen` states for itself — this file's own worked examples will go stale exactly the way that one's did.

This skill encodes specific decisions already made for `triage`'s `Service.hs`, not a menu of strategies. Apply these rules directly; don't offer alternatives.

**Rules are identified by name, not number.** Cross-reference by name (e.g. `verifies-the-precondition`), never by position in the table below.

| Name | One-line summary |
|---|---|
| `function-per-use-case` | One `Service.hs` function per orchestration operation, named after what it does |
| `verifies-the-precondition` | Naming test for a `Service.hs`/`Domain.hs` verb pair: the name goes to whichever one actually verifies the precondition it would claim |
| `error-vs-outcome-types` | `ServiceError` for bugs/misuse/infrastructure failure; named outcome types for legitimate concurrent/business branches — never folded together |
| `pool-in-connection-scoped` | Every public function takes `ConnectionPool`, checks out one `Connection` via `withResource`, holds it for the whole operation — never a bare `Connection` parameter |
| `guard-every-fetch-then-write-gap` | Any fetch-then-write operation needs an affected-rows/existence guard at write time, regardless of whether a literal DB constraint sits underneath — flag this when *proposing* the function, don't wait for it to be caught after the fact |
| `caller-supplied-facts` | Timestamps, reasons, and other facts the caller already knows are always parameters, never minted internally (no `getCurrentTime` inside a `Service.hs` function) |

## Architecture this skill fits into

```
Domain        — pure, sealed types, smart constructors, zero awareness of JSON/DB/anything external
Persistence   — Row types matching storage shape, toDomain/fromDomain, fetch/store functions (triage-db-codegen)
Service       — orchestration: composes Domain's pure functions with Persistence's fetch/store functions,
                 one function per real-world use case (this skill)
```

`Service.hs` imports both `Domain` and `Persistence` and is the only layer that does — it's where a `ConnectionPool` gets checked out, where new IDs get minted, and where a raw `Persistence.hs` outcome (a decode error, an affected-rows result) gets translated into something a caller reasons about in business terms.

## `function-per-use-case` — One function per orchestration operation, named after what it does

Established at `Service.hs`'s creation over alternatives (a generic command-dispatch function, a typeclass per aggregate): one function per real-world operation (`submitHealthcareRequest`, `triageSubmittedRequest`, `matchWaitlistToSlot`, `reassignAppointmentSlot`, `closeAppointment`), each independently callable, each owning its own unit of work. Propose the shape of a new function's *signature* before writing it, and flag it explicitly, per the same discipline that shaped the first two functions in this file — this is exactly the kind of decision that's expensive to unwind once several functions exist against it.

## `verifies-the-precondition` — Naming test for a Service.hs/Domain.hs verb pair

When a `Service.hs` wrapper and the `Domain.hs` verb it calls could plausibly share a name, **the test is which one actually verifies the precondition a shared name would be claiming** — not "which layer is this," not "does this collide in Haskell's namespace." Whichever function performs the check that the name implies gets the name; the other keeps its own, unmodified name.

**Worked example:** `Domain.triageHealthcareRequest` takes a bare `HealthcareRequestDetails` — it has no way to check, and doesn't check, that those details ever existed in a stored `Submitted` state; it's a pure transformation, agnostic to provenance. Naming it (or its wrapper) around "submitted" would claim a precondition it doesn't verify. The `Service.hs` wrapper, by contrast, is defined entirely by that check: it fetches the stored request, confirms `Right (Just (Submitted details))`, and rejects `RequestAlreadyTriaged` otherwise. So: `Domain.triageHealthcareRequest` stays unchanged (correctly named for what it verifies — nothing, beyond its own field types); the wrapper is `triageSubmittedRequest` (correctly named for what it verifies — that the request is actually `Submitted` before triaging it).

**Checked retroactively against the other two wrappers, both already correctly named under this test:**
- `reassignSlot` / `reassignAppointmentSlot`: `Domain.reassignSlot` checks only structural eligibility (`matches`) against values already in hand — it can't and doesn't verify the appointment is genuinely still `Open` in storage, or the new slot genuinely still available. `reassignAppointmentSlot` verifies both. The "Appointment" folded into the name reflects precision about *what* is being reassigned (the slot binding, never the appointment's identity) rather than a literal fetched precondition, but it passes the same spirit of the test.
- `checkWaitlist` / `matchWaitlistToSlot`: `Domain.checkWaitlist` takes a bare `[TriagedHealthcareRequest]` — it has no way to check, and doesn't check, that the list it's given is actually "the waitlist" (`no-delete-on-consumption`'s derived anti-join, from `triage-db-codegen`). `matchWaitlistToSlot` is what performs that real fetch (`fetchWaitlist`) before scanning it, so it's the one entitled to "waitlist" in its own name.

**A real, separate consequence, not the test itself:** Haskell's flat top-level namespace has no OOP-style receiver (no `appointment.reassignSlot(...)`) to disambiguate two identically-named functions the way a method call would in a language with one. If the precondition test alone left two functions with the same literal name, that name collision would still need resolving — but it doesn't dictate *which* alternate name to pick. That choice always comes from the precondition test above.

## `error-vs-outcome-types` — ServiceError vs. named outcome types, kept strictly separate

Two categories of "this didn't just succeed," never merged:

- **`ServiceError`** (returned as `Left`): a bug, a caller's wrong assumption about a resource's state, or a genuine infrastructure failure. Live cases: `PersistenceDecodeError` (wraps `Persistence.DecodeError`), `AppointmentNotFound`, `AppointmentAlreadyClosed`, `RequestNotFound`, `RequestAlreadyTriaged`.
- **Named outcome types** (`MatchOutcome`, `ReassignmentOutcome`, ...): a legitimate branch of business logic the caller reacts to, typically differently per constructor — never an error, never folded into `Left`. Live cases: `NoEligibleRequest`, `SlotAlreadyClaimed`, `RequestAlreadyClaimed`, `Ineligible`, `NewSlotAlreadyClaimed`.

The dividing line is not "did `Persistence.hs` report a problem" — both categories can originate there. It's whether the caller is being told about *its own mistake or a real failure* (`ServiceError`) or about *reality moving between two valid, concurrent operations* (an outcome constructor). A lost concurrency race is never the caller's fault and never a bug, so it is never a `ServiceError` — see `persistClosedAppointmentIfOpen`'s `AlreadyClaimed`, which `closeAppointment` reports as the *same* `AppointmentAlreadyClosed` the initial fetch would have produced, precisely because from the caller's perspective both mean the same thing ("this appointment is not open"), not because a race outcome is secretly a `ServiceError` in disguise.

Distinct constructor names throughout — Haskell data constructors share one namespace per module (unlike record fields under `DuplicateRecordFields`), so the same name can't be reused across two sum types in the same module, nor across modules once both are imported unqualified. `MatchOutcome`'s `SlotAlreadyClaimed` and `ReassignmentOutcome`'s `NewSlotAlreadyClaimed` are deliberately different names for this reason, not stylistic variation.

## `pool-in-connection-scoped` — ConnectionPool in, one Connection held for the whole operation

Every public `Service.hs` function takes `ConnectionPool`, never a bare `Connection` — this is `Persistence.hs`'s own stated reason for `ConnectionPool` existing at all (see its module header). Each function checks out exactly one `Connection` via `withResource pool $ \conn -> ...` and threads that same `conn` through every `Persistence.hs` call it makes, including any internal `withTransaction`. A function that took `Connection` directly could only ever be composed by a caller that already had one checked out — `Service.hs` functions are meant to be the composition root, not something composed into a larger one.

## `guard-every-fetch-then-write-gap` — Flag concurrency guards when proposing, not after being caught

Any `Service.hs` operation shaped "fetch a row, check something about it, then write" has a gap between the check and the write where a concurrent operation can invalidate what was checked. This needs an affected-rows or existence guard on the write itself — regardless of whether a literal `UNIQUE` constraint or other DB-level rule sits underneath. See `triage-db-codegen`'s `uniqueness-races-are-outcomes`, which states the `Persistence.hs`-side mechanism (`deleteSlot`'s existence check, `insertIfUnclaimed`'s `UNIQUE` check, `persistClosedAppointmentIfOpen`'s state check — three different mechanisms serving the identical purpose).

**The process failure this rule is actually about:** twice in this codebase's history so far, this gap was found only *after* a function was proposed and half-built without it (the `healthcare_request_id` race in `persistMatchedAppointment`, and the double-close race in `closeAppointment`), not during the initial proposal. The fix is procedural, not just technical: **when proposing any new `Service.hs` function that fetches then writes, explicitly ask "what changes between the fetch and the write, and does it matter" as part of the proposal itself** — the same way a signature or an error type gets proposed and flagged before implementation. Don't wait for it to surface in review.

## `caller-supplied-facts` — Timestamps, reasons, and similar facts are parameters, never minted internally

No `Service.hs` function calls `getCurrentTime` (or equivalent) internally to produce a `UTCTime` it then persists. `createdAt`, `triagedAt`, and `CloseReason`'s `Cancelled`-carried timestamp are all caller-supplied parameters — established by `submitHealthcareRequest`, `triageSubmittedRequest`, and `closeAppointment` alike. This is a different category from ID generation (`newAppointmentId` and friends, minted internally per `Persistence.hs`'s own note on why that responsibility moved to `Service.hs`): an ID is arbitrary and has no meaning outside being unique, so minting it here is pure orchestration; a timestamp asserts *when something actually happened*, which the caller is closer to and more authoritative about than this layer — minting it here would silently substitute "when this function happened to run" for "when the event actually occurred," which are not always the same moment.

Where a whole `Domain.hs` value already carries the fact in question (`AvailableSlot`'s `start`, `CloseReason`'s `Cancelled` timestamp), take that value whole rather than decomposing it into separate parameters and reconstructing it — the caller already assembled it correctly; re-threading its fields individually only invites the two copies drifting apart.

## When unsure

If a rule above doesn't cover a case that comes up, prefer the option that mirrors an existing `Service.hs` function's shape most directly, and flag the ambiguity to the user rather than inventing a convention silently — same standard as `triage-db-codegen`. When adding a genuinely new rule, give it a name in this same style before writing content under it.
