---
name: triage-ui-codegen
description: Conventions for generating a frontend UI or UX flow from triage's Domain.hs — the medical appointment scheduling domain model. Use this skill whenever designing, generating, or scaffolding UI components, forms, screens, or client-side state derived from Domain.hs types (e.g. a doctor-facing waitlist view, a slot-booking screen, an appointment management UI). Trigger this even if the user just says "build the booking screen" or "design the waitlist UI" without mentioning Domain.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or API generation — see triage-db-codegen and triage-api-codegen instead.
---

# triage-ui-codegen

`Domain.hs` is the single source of truth for the `triage` scheduling domain. UI affordances, form structure, and client-side state should all be **derived** from it (and from the routes `Api.hs` actually exposes), not designed independently from screenshots or vague descriptions of "what the doctor wants to see."

## Invariants (non-negotiable)

### Available actions must mirror exactly which transitions are defined for the current state

This is the most important rule in this skill, and the one most likely to be silently violated. An `IntakeRequest`'s valid actions are exactly the transitions `Domain.hs` defines out of its current case — nothing more. A `Submitted` request can be accepted or rejected, never matched to a slot (there's no triage yet). An `Appointed` request can be closed or reclaimed, never accepted again. `Rejected`, `Withdrawn`, `Stale` and `Closed` are terminal: show them read-only, with no action controls at all.

Concretely: **build the set of enabled controls from the current state, not from a general-purpose "what can a request do" menu with conditions sprinkled on top.** A `switch` over the request's `type` should produce the exact list of valid actions; if a new case is added to `IntakeRequest` later, the UI should fail to type-check (with the generated API types) or at minimum visibly need updating, not silently render a stale action list. See `references/state-to-affordance-mapping.md` for the table.

### Client-side state mirrors the domain's sum types directly

Don't model a request's state in the frontend as independent booleans (`isAccepted`, `isAppointed`, `isClosed`) that could disagree with each other. Mirror the discriminated union directly — the API already serializes every sum type as one flat object with a `"type"` field (`tagged-flat-serialization` in `triage-api-codegen`), which maps straight onto a TypeScript discriminated union. The whole reason the Haskell side encodes state as separate types instead of a status flag is to make invalid combinations unrepresentable; reintroducing independent booleans on the frontend throws that guarantee away at the last mile.

### Show every outcome the server can answer with

Mutations answer `200` with `{"outcome": tag, "detail": …}` for success, errors and outcomes alike (`error-vs-outcome-mapping`). A form that only checks for HTTP errors silently swallows answers like `requestNotSubmittedAnymore` or `requestChangedSinceRead`. Show any outcome other than the expected success tag, with readable text where it helps — `requestChangedSinceRead` means the request changed since the screen loaded, so the user should reload and decide again.

### `RoutineDue`'s four cases are a mode choice, not two independent date pickers

```haskell
data RoutineDue = RoutineAnytime | RoutineNotBefore UTCTime | RoutineNotAfter UTCTime | RoutineWithin UTCTime UTCTime
```

Present this as an explicit choice (e.g. a select: "Anytime / Not before / Not after / Within a range") that then reveals exactly the date input(s) that mode needs — one field for not-before/not-after, two for within, none for anytime. Don't present two independent optional "from"/"to" fields and leave the user to infer which combination means what; that reintroduces the ambiguity the sum type exists to remove. `Emergency` and `Urgent` priorities carry exactly one deadline each — one date field, no mode choice.

### Priority gets consistent visual treatment

`IntakeRequestPriority`'s tiers use a consistent color mapping: **red = Emergency, amber = Urgent, green = Routine** (`frontend/src/components/PriorityBadge.tsx`). Any new UI surfacing priority should reuse that component or mapping rather than inventing a new one.

### The doctor requirement is set at triage

The submit form has no doctor control: a patient's preference goes in the narrative. The triage (accept) form sets `doctorRequirement` — what matching will enforce — for any priority, defaulting to any doctor. When Emergency or Urgent gets a specific doctor, warn that the request will wait for that doctor even if others are free before its deadline: it's allowed, but it should be a deliberate choice.

## Strategy choices

- **Frontend stack** — React 18 + TypeScript + Vite, Mantine, TanStack Query, react-router (see `frontend/package.json`). Follow it; don't introduce another framework.
- **Component granularity** — keep one state-to-actions mapping per entity, shared by every screen that renders that entity's actions, so the action lists can't drift apart between screens.

## Reference

- `references/state-to-affordance-mapping.md` — every `IntakeRequest` case, the actions valid in it, and the `Domain.hs` transition and route behind each. Use it as the source for any "what buttons should this screen show" question rather than re-deriving it ad hoc.

## When unsure

If a UI requirement isn't covered above, prefer a design that makes invalid states impossible to reach through the UI (matching how the domain model makes them impossible to construct) over one that allows them and validates after the fact. Flag the ambiguity to the user rather than silently picking.
