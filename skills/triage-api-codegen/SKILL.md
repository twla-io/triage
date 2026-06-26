---
name: triage-api-codegen
description: Conventions for generating a REST, GraphQL, or RPC API from triage's Domain.hs — the medical appointment scheduling domain model. Use this skill whenever designing, generating, or scaffolding API endpoints, routes, request/response schemas, or service methods derived from Domain.hs types. Trigger this even if the user just says "build the API" or "add an endpoint for booking" without mentioning Domain.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or UI generation — see triage-db-codegen and triage-ui-codegen instead.
---

# triage-api-codegen

`Domain.hs` is the single source of truth for the `triage` scheduling domain. The API surface should be **derived** from it, not designed independently.

## Invariants (non-negotiable)

### Functions are either Commands or Queries — never both, never ambiguous

`Domain.hs`'s export list groups every function under `-- Commands` (state transitions: `freeSlot`, `bookAppointment`, `giveOffer`, ...) or `-- Queries` (pure, read-only: `matches`, `satisfiesDueAt`, `requestId`, `priorityOf`, ...). A Command always returns a new domain value, never `Bool` or a primitive. Map Commands to mutating operations and Queries to read operations — never the reverse, regardless of which API style is chosen below.

### `checkWaitlist` is a protocol decision, not an endpoint

`checkWaitlist :: PendingSlot -> [AppointmentRequest] -> UTCTime -> MatchAppointmentRequestResult` belongs inside the handler for "a slot just became free" — never exposed as a public endpoint on its own. Expose the *event* that triggers it (slot created, appointment cancelled), and run the protocol plus its atomic write inside that handler.

### IDs are opaque UUID strings on the wire

Request and response bodies use plain UUID strings for `DoctorId`, `PatientId`, etc. — never a wrapped object, never the Haskell type name as a JSON key. Different ID types must stay distinguishable in the API's type system (e.g. branded types in TypeScript, distinct path parameter names) even though they share a wire format.

### No error path exists for the domain transition itself

Every transition is total — it cannot fail given a valid input of the right type. Any error response in generated API code comes from a boundary condition (an ID didn't resolve, the resource isn't in the state the operation requires), never from the domain transition failing on its own terms. Map "wrong state for this operation" to a conflict-style response (e.g. HTTP 409), not a generic validation error — it's the wire-level expression of "the type wouldn't have allowed this."

## Strategy choices — pick one, or ask the user

- `references/rest.md` — Commands become `POST`/`PATCH` endpoints, Queries become `GET` endpoints. Default choice if there's an existing REST API elsewhere in the codebase.
- `references/event-sourced.md` — Commands become commands posted to a handler that emits events; Queries read from a projection. Matches the CQRS/ES shape already sketched for triage's application layer; adds real complexity, worth it mainly if an audit trail of "what happened and when" is genuinely valued.

If the team already has an API style in use elsewhere, match it rather than introducing a new one for this domain alone.

## When unsure

Prefer the option that keeps the API a thin, faithful mirror of the Commands/Queries split over one that reshapes it for convenience — the split already reflects which operations are safe to retry, cache, or expose publicly. Flag the ambiguity to the user rather than silently picking.
