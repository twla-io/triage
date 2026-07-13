---
name: triage-api-codegen
description: Conventions for generating a REST, GraphQL, or RPC API from triage's Domain.hs — the medical appointment scheduling domain model. Use this skill whenever designing, generating, or scaffolding API endpoints, routes, request/response schemas, or service methods derived from Domain.hs types. Trigger this even if the user just says "build the API" or "add an endpoint for booking" without mentioning Domain.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or UI generation — see triage-db-codegen and triage-ui-codegen instead.
---

# triage-api-codegen

`Domain.hs` is the single source of truth for the `triage` scheduling domain, with `Service.hs` as the orchestration layer above it. The API surface should be **derived** from both, not designed independently — read `Domain.hs` and `Service.hs` fresh before generating or extending anything here, rather than trusting this skill's own worked examples, which have already gone stale once before (an earlier version described an offer/decline waitlist mechanism — `freeSlot`, `bookAppointment`, `giveOffer`, `declineOffer` — that predates the current six-state `IntakeRequest` model entirely).

**Unlike `triage-db-codegen` and `triage-service-codegen`, no API layer has ever been built against this domain model.** There is no `Transport.hs`, no `aeson` dependency, no routes, nothing (confirmed by grep). So the rules below are a mix of structural conventions (generic API-design practices that don't depend on this domain's specifics) and genuinely open questions — they are not decisions checked against working code the way the other two skills' rules are. Where something is undecided, it's flagged as an open question, not silently resolved.

**Rules are identified by name, not number.** Always cross-reference by name (e.g. `checkwaitlist-not-an-endpoint`), never by position in the table below.

| Name | One-line summary |
|---|---|
| `commands-vs-queries-naming` | Open question — `Service.hs` currently exports zero pure reads, so there's nothing to derive a naming convention from yet |
| `checkwaitlist-not-an-endpoint` | `checkIntakeWaitlist` never gets its own route — it's the body of whatever handler responds to a slot becoming available |
| `opaque-uuid-ids` | IDs are plain UUID strings on the wire, never wrapped — generic convention, retained but not re-verified |
| `error-vs-outcome-mapping` | `ServiceError` and the outcome types (`MatchOutcome`, `SlotCreationOutcome`) must map to two different response shapes — which shapes, not yet decided |

## Architecture this skill fits into

```
Domain        — pure, sealed types, smart constructors, zero awareness of JSON/DB/anything external
Persistence   — Row types matching storage shape, toDomain/fromDomain at the boundary (triage-db-codegen)
Service       — orchestration: composes Domain's pure functions with Persistence's fetch/store functions
                 (triage-service-codegen)
Transport?    — DTOs for wire formats (JSON), toDomain/fromDomain at the boundary — does not exist yet;
                 whether it's this skill's job to introduce or a separate skill's is itself an open question,
                 see below
API           — routes/resolvers/RPC handlers over Service.hs (this skill)
```

`Domain.hs` has no serialization of any kind — no `ToJSON`/`FromJSON`, no `Generic` deriving for that purpose — and nothing generated from this skill should assume otherwise or reintroduce that coupling.

## `commands-vs-queries-naming` — Open question, not a decision to make now

An earlier version of this rule claimed the Command/Query split was mechanically derivable from `Domain.hs`'s export list, which used to group functions under `-- Commands` and `-- Queries` section comments. **That grouping no longer exists.** The current export list groups by domain concept instead (`ID wrappers`, `Priority / Due constraints`, `Intake Request`, `Slot`, `Protocol`, ...) — there is nothing left to mechanically derive a Command/Query naming convention from.

More fundamentally: **`Service.hs` currently exports zero pure reads.** All 11 of its current operations (`createDoctor`, `createPatient`, `createHealthcareService`, `createAvailableSlot`, `submitIntakeRequest`, `acceptSubmittedIntakeRequest`, `rejectSubmittedIntakeRequest`, `matchWaitlistToSlot`, `matchAcceptedIntakeRequestToSlot`, `reclaimAppointedIntakeRequest`, `closeAppointedIntakeRequest`) mutate — verified against `Service.hs`'s actual export list and each function's body. The two read functions that exist at all (`fetchIntakeRequest`, `fetchIntakeWaitlist`) live in `Persistence.hs` and are not exposed at the `Service.hs` layer.

**This is deliberately left as an open question, not a naming decision made here.** There is no rule to propose a replacement derivation for, because an API layer generated today would have no `Service.hs`-level read operations to name consistently in the first place — a `GET` endpoint for, say, fetching one intake request's current state would have to be built against `Persistence.fetchIntakeRequest` directly, bypassing `Service.hs` entirely, which is itself a design question (does a read need to go through `Service.hs` at all, or is `Persistence.hs` a legitimate direct dependency for reads?) that belongs to a `Service.hs` design pass, not to API-codegen. Don't invent a Command/Query naming convention to fill this gap — flag it and ask, per this skill's own closing rule.

## `checkwaitlist-not-an-endpoint` — `checkIntakeWaitlist` is a protocol decision, not an endpoint

`checkIntakeWaitlist :: AvailableSlot -> [TriagedIntakeRequest] -> Maybe AppointedIntakeRequest` belongs inside the handler for "a slot just became available" — never exposed as a public endpoint on its own. In the current codebase, its real caller is `Service.matchWaitlistToSlot :: ConnectionPool -> AvailableSlot -> IO (Either ServiceError MatchOutcome)`, which fetches the waitlist, runs `checkIntakeWaitlist`, and persists the result atomically. Whatever handler creates a new `AvailableSlot` (i.e. whatever calls `Service.createAvailableSlot`) is the natural place to also call `matchWaitlistToSlot` — expose the event ("a slot was created"), not the scan itself.

## `opaque-uuid-ids` — IDs are opaque UUID strings on the wire

Request and response bodies use plain UUID strings for `DoctorId`, `PatientId`, `HealthcareServiceId`, `IntakeRequestId`, `SlotId` — never a wrapped object, never the Haskell type name as a JSON key. Different ID types must stay distinguishable in the API's type system (e.g. branded types in TypeScript, distinct path parameter names) even though they share a wire format.

**Retained, not re-verified against a working implementation** — this is a generic API-design convention independent of this domain's specifics, carried forward unchanged from the previous version of this skill, but there is no Transport layer or route yet to confirm it against.

## `error-vs-outcome-mapping` — Two response shapes, mirroring Service.hs's own split

`Service.hs` already draws a hard line between two categories of "this didn't just succeed" (its own `error-vs-outcome-types` convention, see `triage-service-codegen`):

- **`ServiceError`** — a bug, a caller's wrong assumption about a resource's state, or a genuine infrastructure failure. Current constructors (verified against `Service.hs`): `PersistenceDecodeError`, `RequestNotFound`, `RequestNotSubmittedAnymore`, `RequestNotAccepted`, `RequestNotYetTriaged`, `RequestNotAppointed`, `RequestAlreadyClosed`.
- **Named outcome types** — a legitimate branch of business logic, never an error. Current constructors: `MatchOutcome`'s `Matched`, `NoEligibleRequest`, `RequestIneligible`, `SlotAlreadyClaimed`, `RequestAlreadyClaimed`; `SlotCreationOutcome`'s `SlotCreated`, `SlotConflict`.

Whatever API layer gets generated must preserve this split as two genuinely different response shapes — a `ServiceError` should never be indistinguishable on the wire from, say, `NoEligibleRequest` (an entirely normal outcome of an automatic waitlist scan finding no match) or `SlotConflict` (a legitimate concurrent-write outcome, not a caller mistake). Collapsing both categories into one generic 4xx/error envelope would erase a distinction `Service.hs` went to real effort to keep.

**What this rule does NOT decide:** the actual HTTP status codes, error envelope shape, or whether outcome types map to 2xx-with-a-discriminator-field vs. some other non-error shape. That mapping is a genuinely open question — flag it explicitly rather than picking codes here.

## Strategy choices — pick one, or ask the user

- `references/rest.md` — Commands become `POST`/`PATCH` endpoints; reads (where they eventually exist — see `commands-vs-queries-naming`) become `GET` endpoints. Default choice if there's an existing REST API elsewhere in the codebase.
- `references/event-sourced.md` — a documented, available option, **not currently favored**. `docs/decisions.md`'s "Event sourcing: explored, rejected (2026-06)" entry already settled this question — for cost reasons unrelated to API design specifically — and nothing since has reopened it. Revisit only if scale assumptions genuinely change; do not treat this as a partially-adopted direction.

If the team already has an API style in use elsewhere, match it rather than introducing a new one for this domain alone.

## Open questions — do not resolve these speculatively

Per CLAUDE.md's workflow discipline, none of the following should be decided in code without validating with the user first:

- **Command/Query naming convention** — see `commands-vs-queries-naming` above; blocked on a `Service.hs` design pass (does a read-side operation belong in `Service.hs` at all?), not an API-codegen decision.
- **Transport/DTO layer ownership** — whether a `Transport.hs` DTO-twin-type layer gets built as part of this skill, or is a separate skill's responsibility introduced when API generation actually starts building routes.
- **Six-state JSON serialization shape** — how `IntakeRequest`'s six states (`Submitted`/`Rejected`/`Accepted`/`Appointed`/`Withdrawn`/`Closed`) serialize over JSON: a tagged sum, a discriminator field alongside a flat shape, or one response shape per state. Not decided.
- **Error/outcome wire mapping** — see `error-vs-outcome-mapping` above; the two-category split is settled, the actual status codes and envelope format are not.
- **`reclaimAppointedIntakeRequest`'s API surface** — whether it's its own directly-callable endpoint, or only reachable as a step behind a higher-level action (e.g. a "reassign" endpoint that internally calls `reclaimAppointedIntakeRequest` then `matchAcceptedIntakeRequestToSlot`, per `docs/decisions.md`'s "Reassignment and displacement both compose from reclaimAppointedIntakeRequest" entry). Not decided.

## When unsure

Prefer the option that keeps the API a thin, faithful mirror of `Service.hs`'s actual operations and their real error/outcome split over one that reshapes it for convenience. Flag ambiguity to the user rather than silently picking — this file has more open questions than `triage-db-codegen`/`triage-service-codegen` precisely because no API code has ever been built here to check assumptions against.
