---
name: triage-ui-codegen
description: Conventions for generating a frontend UI or UX flow from triage's Domain.hs — the medical appointment scheduling domain model. Use this skill whenever designing, generating, or scaffolding UI components, forms, screens, or client-side state derived from Domain.hs types (e.g. a doctor-facing waitlist view, a slot-booking screen, an appointment management UI). Trigger this even if the user just says "build the booking screen" or "design the waitlist UI" without mentioning Domain.hs explicitly, as long as the triage domain model is the source. Do not use this skill for database schema or API generation — see triage-db-codegen and triage-api-codegen instead.
---

# triage-ui-codegen

`Domain.hs` is the single source of truth for the `triage` scheduling domain. UI affordances, form structure, and client-side state should all be **derived** from it, not designed independently from screenshots or vague descriptions of "what the doctor wants to see."

## Invariants (non-negotiable)

### Available actions must mirror exactly which transitions are type-valid for the current state

This is the most important rule in this skill, and the one most likely to be silently violated. If a `Slot` is `Available`, the only valid action is `bookSlot` — never show a "decline" or "cancel" control, because no domain function accepts an `AvailableSlot` for those operations. If a `Slot` is `Booked`, the relevant actions come from `Appointment`'s lifecycle (`Cancelled`, `Rescheduled`, `NoShow`, `Completed`), not from any Slot-level transition.

Concretely: **build the set of enabled controls from the current state's type, not from a general-purpose "what can a slot do" menu with conditions sprinkled on top.** A `case` over the `Slot`/`Appointment`/`WaitlistEntry` constructor should produce the exact list of valid actions — if a new constructor is added to a domain type later, the UI should fail to compile (in a typed frontend) or at minimum visibly need updating, not silently render a stale action list.

### Client-side state mirrors the domain's sum types directly

Don't model a `Slot`'s state in the frontend as independent booleans (`isPending`, `isOffered`, `isAvailable`, `isBooked`) that could disagree with each other. Mirror the discriminated union directly — a TypeScript discriminated union, a single enum field with state-specific optional fields gated by it, or equivalent in whatever framework is used. The whole reason the Haskell side encodes state as separate types instead of a status flag is to make invalid combinations unrepresentable; reintroducing independent booleans on the frontend throws that guarantee away at the last mile.

### Structural absence stays absent in the UI, not just hidden

`EmergencyEntry` has no doctor-preference field — not `Nothing`, structurally absent. The UI for registering an emergency waitlist entry should not display a disabled or empty doctor-preference selector; the control shouldn't exist on that form at all. If a form is shared across `Urgent`/`Routine`/`Emergency` registration, the doctor-preference field should be conditionally rendered based on which entry type is selected, not present-but-disabled.

### `DueAt`'s four cases are a mode choice, not two independent date pickers

```haskell
data DueAt = Anytime | NotBefore UTCTime | NotAfter UTCTime | Within UTCTime UTCTime
```

Present this as an explicit choice (e.g. a select: "Anytime / Not before / Not after / Within a range") that then reveals exactly the date input(s) that mode needs — one field for `NotBefore`/`NotAfter`, two for `Within`, none for `Anytime`. Don't present two independent optional "from"/"to" date fields and leave the user to infer which combination means what; that reintroduces ambiguity the sum type was specifically designed to remove (see `Domain.hs`'s comment on why `DueAt` has four named cases instead of `Maybe (UTCTime, UTCTime)`).

### Priority gets consistent visual treatment

`AppointmentPriority`/the waitlist entry tiers use Emergency/Urgent/Routine throughout the domain and the existing presentation materials use a consistent color mapping: **red = Emergency, amber = Urgent, green = Routine**. Any new UI surfacing priority (a waitlist view, a doctor's queue) should reuse this mapping rather than inventing a new one — consistency here matters because the doctor and staff will see both the presentations and the actual product.

## Strategy choices — confirm with the user before assuming

- **Frontend framework** — not assumed by this skill. Ask, or check the existing codebase, before generating React/Vue/Svelte/etc.-specific code.
- **Component granularity** — whether state-to-affordance mapping (see `references/state-to-affordance-mapping.md`) lives in one shared component per entity type or is duplicated per screen. Prefer one shared mapping if multiple screens need to render the same entity's available actions, to avoid the actions list drifting out of sync between screens.

## Reference

- `references/state-to-affordance-mapping.md` — a complete table of every `Slot`/`Appointment`/`WaitlistEntry` state and the actions valid in that state, derived directly from `Domain.hs`'s Commands. Use this as the source for any "what buttons should this screen show" question rather than re-deriving it ad hoc.

## When unsure

If a UI requirement isn't covered above, prefer a design that makes invalid states impossible to reach through the UI (matching how the domain model makes them impossible to construct) over one that allows them and validates after the fact. Flag the ambiguity to the user rather than silently picking.
