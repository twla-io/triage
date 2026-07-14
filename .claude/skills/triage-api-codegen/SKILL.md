---
name: triage-api-codegen
description: Conventions for generating a REST, GraphQL, or RPC API from triage's Domain.hs — the medical appointment scheduling domain model. Use this skill whenever designing, generating, or scaffolding API endpoints, routes, request/response schemas, or service methods derived from Domain.hs types. Trigger this even if the user just says "build the API" or "add an endpoint for booking" without mentioning Domain.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or UI generation — see triage-db-codegen and triage-ui-codegen instead.
---

# triage-api-codegen

`Domain.hs` is the single source of truth for the `triage` scheduling domain, with `Service.hs` as the orchestration layer above it. The API surface should be **derived** from both, not designed independently — read `Domain.hs` and `Service.hs` fresh before generating or extending anything here, rather than trusting this skill's own worked examples, which have already gone stale once before (an earlier version described an offer/decline waitlist mechanism — `freeSlot`, `bookAppointment`, `giveOffer`, `declineOffer` — that predates the current six-state `IntakeRequest` model entirely).

**Unlike `triage-db-codegen` and `triage-service-codegen`, no API layer has ever been built against this domain model.** There is no `Transport.hs`, no `aeson` dependency, no routes, nothing (confirmed by grep). So the rules below are a mix of structural conventions (generic API-design practices that don't depend on this domain's specifics) and design decisions settled through dedicated conversations rather than checked against working code — unlike the other two skills' rules, none of these have been verified against a real, already-built API. Where something is genuinely undecided, it's flagged rather than silently resolved.

**Rules are identified by name, not number.** Always cross-reference by name (e.g. `checkwaitlist-not-an-endpoint`), never by position in the table below.

| Name | One-line summary |
|---|---|
| `commands-vs-queries-naming` | Settled — reads are `fetch`-prefixed, name-identical to their `Persistence.hs` counterparts; every `Persistence.hs` read now has a `Service.hs` wrapper, no exceptions remaining |
| `checkwaitlist-not-an-endpoint` | `checkIntakeWaitlist` never gets its own route — it's the body of whatever handler responds to a slot becoming available |
| `opaque-uuid-ids` | IDs are plain UUID strings on the wire, never wrapped — generic convention, retained but not re-verified |
| `tagged-flat-serialization` | Every discriminated `Domain.hs` type serializes as one flat JSON object per case with a uniform `"type"` field — never a nested `contents` wrapper, never a case-specific discriminator name |
| `verb-minimalism` | `GET`/`POST` only — no `PUT`, `PATCH`, `DELETE`, or `HEAD`; both excluded verbs are structurally absent from the domain, not just unused |
| `action-endpoints-not-generic-patch` | Mutations route as action-suffixed `POST`s (`/accept`, `/reject`, ...), never `PATCH` with a state field |
| `error-vs-outcome-mapping` | Decided — `400` malformed request, `404` unknown route, `200` for every `Service.hs` answer (success or `ServiceError`/outcome, discriminated in-body), `500` outside the domain's vocabulary |

## Architecture this skill fits into

```
Domain        — pure, sealed types, smart constructors, zero awareness of JSON/DB/anything external
Persistence   — Row types matching storage shape, toDomain/fromDomain at the boundary (triage-db-codegen)
Service       — orchestration: composes Domain's pure functions with Persistence's fetch/store functions
                 (triage-service-codegen)
Transport     — DTOs for wire formats (JSON), toDomain/fromDomain at the boundary — does not exist yet;
                 generating it is this skill's responsibility, not a separate skill's (see below)
API           — routes/resolvers/RPC handlers over Service.hs (this skill)
```

`Domain.hs` has no serialization of any kind — no `ToJSON`/`FromJSON`, no `Generic` deriving for that purpose — and nothing generated from this skill should assume otherwise or reintroduce that coupling.

**`Transport.hs` is this skill's responsibility, not a separate `triage-transport-codegen` skill — resolved.** Unlike `Persistence.hs` (needed regardless of whether an API ever exists, since the domain must be stored either way) and `Service.hs` (needed to orchestrate `Domain`+`Persistence` regardless of whether an API exists), `Transport.hs` has no independent reason to exist except to serve an API — a DTO layer with no consumer is inert. `triage-db-codegen` and `triage-service-codegen` split cleanly along layer boundaries because each of those layers has an independent reason to exist; `Transport` doesn't, so generating it is part of API design rather than a peer layer earning its own skill.

## `commands-vs-queries-naming` — Settled: reads are `fetch`-prefixed, name-identical to Persistence.hs

An earlier version of this rule claimed the Command/Query split was mechanically derivable from `Domain.hs`'s export list, which used to group functions under `-- Commands` and `-- Queries` section comments. **That grouping no longer exists.** The current export list groups by domain concept instead (`ID wrappers`, `Priority / Due constraints`, `Intake Request`, `Slot`, `Protocol`, ...) — there is nothing left to mechanically derive a Command/Query naming convention from that way.

**This rule used to be blocked on `Service.hs` exporting zero pure reads. That premise no longer holds.** `Service.hs` now exports eleven read functions (verified against its current export list): `fetchDoctor`, `fetchPatient`, `fetchHealthcareService`, `fetchDoctors`, `fetchPatients`, `fetchHealthcareServices`, `fetchAvailableSlots`, `fetchAppointedIntakeRequests`, `fetchIntakeRequest`, `fetchIntakeWaitlist`, `fetchCalendarView`. All eleven keep their `Persistence.hs` counterparts' names verbatim — `fetch`-prefixed, no Command/Query-style renaming, no precondition-driven divergence — because per `triage-service-codegen`'s `verifies-the-precondition` rule (see that skill's own note on why it doesn't apply to reads), these pass-throughs have no `Domain.hs` verb to collide with in the first place, so there was never a naming decision to make for them beyond "keep the `Persistence.hs` name."

**The naming convention itself is settled, not an open question anymore:** every `Service.hs` read is `fetch<Noun>`, singular or plural depending on cardinality (`fetchDoctor` vs. `fetchDoctors`), matching its `Persistence.hs` counterpart's name exactly. An API layer generated today has a real, checkable pattern to mirror for all eleven — a `GET` endpoint's handler/route name can derive directly from the `Service.hs` function name.

**The one remaining gap flagged in the previous version of this rule is now closed.** `fetchIntakeRequest` and `fetchIntakeWaitlist` — previously imported unqualified into `Service.hs` and used only internally by `acceptSubmittedIntakeRequest`, `rejectSubmittedIntakeRequest`, `matchAcceptedIntakeRequestToSlot`, `reclaimAppointedIntakeRequest`, `closeAppointedIntakeRequest` (`fetchIntakeRequest`), and `matchWaitlistToSlot` (`fetchIntakeWaitlist`) — now both have their own `Service.hs`-level wrappers in the READS section, same thin `fetch`-prefixed pass-through shape as the other nine. **Every `Persistence.hs` read now has a `Service.hs` wrapper, no exceptions remaining.** An API layer generated today can build a `GET /intake-requests/:id` and a waitlist-listing route against `Service.fetchIntakeRequest`/`Service.fetchIntakeWaitlist` directly, without reaching past `Service.hs` into `Persistence.hs` — the situation this rule originally warned about no longer exists for any current read.

## `checkwaitlist-not-an-endpoint` — `checkIntakeWaitlist` is a protocol decision, not an endpoint

`checkIntakeWaitlist :: AvailableSlot -> [TriagedIntakeRequest] -> Maybe AppointedIntakeRequest` belongs inside the handler for "a slot just became available" — never exposed as a public endpoint on its own. In the current codebase, its real caller is `Service.matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)`, which fetches the waitlist, runs `checkIntakeWaitlist`, and persists the result atomically. Whatever handler creates a new `AvailableSlot` (i.e. whatever calls `Service.createAvailableSlot`) is the natural place to also call `matchWaitlistToSlot` — expose the event ("a slot was created"), not the scan itself.

## `opaque-uuid-ids` — IDs are opaque UUID strings on the wire

Request and response bodies use plain UUID strings for `DoctorId`, `PatientId`, `HealthcareServiceId`, `IntakeRequestId`, `SlotId` — never a wrapped object, never the Haskell type name as a JSON key. Different ID types must stay distinguishable in the API's type system (e.g. branded types in TypeScript, distinct path parameter names) even though they share a wire format.

**Retained, not re-verified against a working implementation** — this is a generic API-design convention independent of this domain's specifics, carried forward unchanged from the previous version of this skill, but there is no Transport layer or route yet to confirm it against.

## `tagged-flat-serialization` — One flat JSON object per case, discriminated by a uniform `"type"` field — resolved

Every discriminated `Domain.hs` type — `IntakeRequest`'s six states, `IntakeRequestPriority`'s three tiers, `RoutineDue`'s four cases, `CloseReason`'s three reasons, `AppointmentParty`'s two parties — serializes as **one flat JSON object per case**, never a nested `"contents"`-style wrapper. The discriminator field is named `"type"` **uniformly at every nesting level** — not `"state"` for `IntakeRequest`, `"tier"` for priority, and so on. One parsing rule applies at every depth of the wire format, not one rule per type.

**Field name: `"type"`, not `"tag"`.** `"type"` was chosen specifically because it's the more broadly recognized convention across client stacks — it matches JSON Schema/OpenAPI's own discriminator examples and common real-world API precedent (e.g. Stripe's object-typing fields, GeoJSON's `"type"` member) more closely than `"tag"` would, which reads as more of an FP-ecosystem convention (e.g. Haskell `aeson`'s `TaggedObject` default field name) than a general API-design one. This API's consumers aren't assumed to be Haskell clients, so the wire vocabulary should follow general API convention over the serialization library's own internal naming default.

Fields shared across states/cases use **identical JSON keys everywhere they appear** — e.g. every `IntakeRequest` state that carries a `patientId` calls it `"patientId"` in every one of those states' shapes, never renamed per-state. This is what makes flattening safe for a client: a field's meaning and name never depend on which case produced it.

**The discriminator's *value* (e.g. `"appointed"`, `"routine"`) is a separate, independently-chosen small wire vocabulary — not required to match the Haskell constructor name verbatim.** Coupling the wire value to the exact constructor name would break API clients on a future internal-only rename; this codebase has already renamed constructors/types for naming-precision reasons unrelated to any API concern (e.g. the `HealthcareRequestId` → `IntakeRequestId` rename, per `docs/decisions.md`'s "IntakeRequest: Appointment folded into one sum type, one identity" entry). The wire format should stay insulated from that kind of internal rename, the same way `Persistence.hs`'s row types are already independent of `Domain.hs`'s exact field names rather than mirroring them verbatim.

**No field is ever spuriously `null` standing in for "hasn't reached this stage yet."** A single-object-with-many-nullable-fields encoding was considered and rejected: it would reintroduce, at the wire boundary, exactly the anti-pattern `Domain.hs`'s own embedding chain (`SubmittedIntakeRequest -> TriagedIntakeRequest -> AppointedIntakeRequest`) was built to prevent at the type level. The wire format must be at least as precise as the domain model it's derived from, not less.

**Worked example** — an `Appointed` request with a `Routine`/`RoutineWithin` priority, showing recursive discrimination at three nesting levels (`IntakeRequest`'s own `"type"`, `priority`'s, `RoutineDue`'s):

```json
{
  "type": "appointed",
  "id": "...",
  "patientId": "...",
  "narrative": "...",
  "doctorRequirement": {...},
  "createdAt": "...",
  "healthcareServiceId": "...",
  "priority": { "type": "routine", "due": { "type": "routineWithin", "from": "...", "to": "..." } },
  "triagedAt": "...",
  "doctorId": "...",
  "start": "...",
  "duration": 30
}
```

A `Closed` request carries everything an `Appointed` one does, plus a top-level `closeReason` field following the same pattern:

```json
"closeReason": { "type": "cancelled", "by": {"type": "byPatient"}, "cancelledAt": "...", "note": "..." }
```

**Implementation cost, deliberately accepted:** this requires six hand-written `ToJSON`/`FromJSON` cases for `IntakeRequest` — not a single mechanical `deriving (Generic, ToJSON)` with `aeson`'s default encoding — plus similarly hand-written instances for `IntakeRequestPriority`/`RoutineDue`/`CloseReason`. More implementation cost than a default derivation, accepted because it's the only option of those considered that sacrifices neither wire-format flatness (rejected: a nested `"contents"`-wrapper tagged sum, `aeson`'s default `TaggedObject` `sumEncoding`) nor domain precision (rejected: one object with every field present, nullable per state). This is a distinct concern from, but consistent with, `docs/decisions.md`'s "Generic-derived FromJSON on sealed types: rejected as a pattern" entry — that entry blocks `Generic` derivation on sealed `Domain.hs` types for a validation-bypass reason; this rule requires hand-written `Transport.hs` instances even on non-sealed types, for a wire-shape reason.

## `verb-minimalism` — GET and POST only; no PUT, PATCH, DELETE, or HEAD

This API uses exactly two HTTP verbs. Not a stylistic default — checked against the actual domain, and both excluded mutating verbs are structurally absent, not merely unused by convention:

- **No `PUT`.** `PUT`'s overwrite semantics have no referent here — nothing in this domain is a full-resource replace. Even `reclaimAppointedIntakeRequest`, the closest thing to "revert a resource," is a state transition with its own precondition (`state = 'appointed'`) and its own outcome set (e.g. `RequestAlreadyClosed` if the race is lost), not an unconditional overwrite of a resource's fields.
- **No `DELETE`.** The domain is `no-delete-on-consumption` throughout (see `triage-db-codegen`): `intake_requests` rows are never deleted, only transitioned between states. `slots` rows are deleted, but only as an internal side effect of `matchWaitlistToSlot`/`matchAcceptedIntakeRequestToSlot` matching a slot — never via a caller-facing delete intent. There is no operation in `Service.hs` a caller would reach for `DELETE` to express.
- **No `PATCH`, no `HEAD`.** See `action-endpoints-not-generic-patch` below for why `PATCH` specifically is excluded, not just unused.

## `action-endpoints-not-generic-patch` — Action-suffixed POSTs, not PATCH with a state field

`Service.hs`'s 11 mutations are operations with their own precondition contracts (`triage-service-codegen`'s `verifies-the-precondition`), not field-level resource updates. `acceptSubmittedIntakeRequest` isn't "set `state` to `accepted`" — it's an operation with a defined precondition (the request must currently be `Submitted`) and a defined outcome set (`Right TriagedIntakeRequest`, or a specific `ServiceError`). Representing it as `PATCH /intake-requests/:id` with a `{"state": "accepted"}` body would force the API layer to reconstruct an operation-shaped contract from a field-diff at request time — either duplicating `Service.hs`'s precondition logic in the API layer, or becoming RPC wearing a REST verb.

Route each mutation as an action-suffixed `POST` instead: `POST /intake-requests/:id/accept`, `/reject`, `/match`, `/reclaim`, `/close`.

**This also settles a previously-open question:** whether `reclaimAppointedIntakeRequest` gets its own endpoint. It does — `POST /intake-requests/:id/reclaim`, the same shape as every other operation in this list, not something reachable only as a hidden step behind a higher-level action. This rule doesn't decide whether a *caller* (UI, workflow) ever invokes `/reclaim` on its own versus always composing it with a subsequent `/match` call — only that the endpoint itself exists and is directly callable.

## `error-vs-outcome-mapping` — Decided: four HTTP status codes, each answering a different question

`Service.hs` already draws a hard line between two categories of "this didn't just succeed" (its own `error-vs-outcome-types` convention, see `triage-service-codegen`) — `ServiceError` (`PersistenceDecodeError`, `RequestNotFound`, `RequestNotSubmittedAnymore`, `RequestNotAccepted`, `RequestNotYetTriaged`, `RequestNotAppointed`, `RequestAlreadyClosed`) vs. named outcome types (`MatchOutcome`'s `Matched`/`NoEligibleRequest`/`RequestIneligible`/`SlotAlreadyClaimed`/`RequestAlreadyClaimed`; `SlotCreationOutcome`'s `SlotCreated`/`SlotConflict`). The wire mapping for that split is now decided:

- **`400`** — the request never reached a state where `Service.hs` could evaluate it: malformed JSON, a field with the wrong type, a missing required field, an ID that isn't even a valid UUID shape. Rejected before any `Service.hs` function is called.
- **`404`** — the route/path itself doesn't resolve to any known resource *shape* at all — decided entirely by the router, before any `Service.hs` call (e.g. a path segment that isn't a resource this API has).
- **`200`** — `Service.hs` actually ran and produced an answer. This covers **both** success and every `ServiceError`/outcome-type constructor, discriminated by a field in the response body, never by status code. This includes `RequestNotFound`: a request for a well-formed, syntactically valid `IntakeRequestId` that doesn't correspond to any stored row still reaches `Service.hs`, runs `fetchIntakeRequest`, and gets a real `Right Nothing` — a genuine domain answer, not an absence of one. Despite the name, `RequestNotFound` is **not** a `404`. The distinguishing test is whether `Service.hs` had to actually run a query to produce the answer, not whether the English description of the constructor sounds like "not found." This is a deliberate, reasoned departure from the common REST instinct of id-not-found → `404`, not an oversight — stated explicitly here because it's the specific case most likely to get "fixed" back to `404` by default in a future pass without this context.
- **`500`** — outside the domain's vocabulary entirely: `PersistenceDecodeError`, a DB connection failure, anything genuinely unexpected that no `ServiceError`/outcome constructor was written to describe.

## Strategy: REST — decided, not event-sourced

Previously framed as "pick one, or ask the user." Settled, for three independent reasons:

- Every `Service.hs` function is synchronous request/response — there is no subscribe/replay concept anywhere in the current domain model to motivate an event-driven API shape.
- `docs/decisions.md`'s "Event sourcing: explored, rejected (2026-06)" entry already rejected the harder operational cost (event store, replay, projection maintenance) at the *persistence* layer, on cost grounds at 2-3 doctor scale. Choosing event sourcing for the *API* layer now would reintroduce that same cost one layer up, with no new justification beyond what was already weighed and rejected once.
- The audit-trail motivation that would normally argue for event sourcing — "why was this patient offered this slot" — is already addressed structurally, without an event log: `reclaimAppointedIntakeRequest` preserves `IntakeRequestId`/`triagedAt`/priority exactly across reassignment and displacement (see `docs/decisions.md`'s "Reassignment and displacement both compose from reclaimAppointedIntakeRequest" entry). `references/event-sourced.md`'s own "When to choose this" motivating case no longer applies to this domain.

Use `references/rest.md`. `references/event-sourced.md` is retained as a documented, available option — not currently favored, not partially adopted — revisit only if scale assumptions genuinely change, per `docs/decisions.md`'s own closing note on that entry.

## When unsure

Prefer the option that keeps the API a thin, faithful mirror of `Service.hs`'s actual operations and their real error/outcome split over one that reshapes it for convenience. Flag ambiguity to the user rather than silently picking — every rule above was settled through a dedicated design conversation rather than found already true of working code, unlike `triage-db-codegen`/`triage-service-codegen`'s rules, so treat that gap with appropriate caution when generating from this skill for the first time.
