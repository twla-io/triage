# triage

Medical appointment scheduling system in Haskell. "triage" refers to the
priority-sorting waitlist protocol — name is provisional.

## Purpose — Domain.hs is a specification, not just an implementation

`src/Domain.hs` is the single source of truth for the domain model and every
valid state transition in it. Sealed types + smart constructors exist to
encode domain rules directly into the type system — not primarily for
defensive Haskell hygiene, but so the rules are machine-legible. Claude Code
reads this file as the spec and generates the downstream layers (DB schema,
Persistence, Service, API, UI/UX) from it via the codegen skills below.

This means: when editing `Domain.hs`, you're not writing implementation,
you're writing the thing every other layer gets derived from. Precision here
has a multiplier effect — an ambiguity or missing invariant propagates into
every generated layer.

## Commands

<!-- TODO: fill in with actual invocations once confirmed -->
- Build: `cabal build` (or `stack build` — confirm which toolchain this repo uses)
- Test: `cabal test`
- REPL: `cabal repl`

## Before generating downstream layers

`src/Domain.hs` carries this header comment — follow it:

> For conventions on generating downstream layers from these types, see:
> `triage-db-codegen` (database schema), `triage-service-codegen` (Service.hs
> orchestration layer), `triage-api-codegen` (REST/GraphQL/RPC API),
> `triage-ui-codegen` (frontend). Read the relevant skill before generating
> any of these from this module.

## Workflow discipline (non-negotiable)

- One decision at a time. Don't bundle multiple design changes into one turn.
- No code for unvalidated requirements. If a rule sounds plausible but wasn't
  discussed with the domain expert (the doctor), leave it out — cheaper to add
  later than to carry unvalidated complexity now.
- Model perfection is a deliberate goal, not over-engineering. If a type
  requires ceremony to explain, the model is wrong — fix the model, don't
  write a comment.
- Scale target is 2-3 doctors. Don't reach for infrastructure (event
  sourcing, CQRS, etc.) sized for a problem this isn't.

## Before touching code, read the relevant doc

- Working in `src/Domain.hs`? Read `docs/domain-model.md` and
  `docs/modeling-principles.md` first.
- Proposing a persistence or architecture change? Read `docs/decisions.md`
  first — check whether this was already explored and rejected.
- Open questions that don't yet have an answer live at the bottom of
  `docs/decisions.md`, not scattered in chat history.

## Sealing in Domain.hs — selective, and that's the point

Constructors are hidden (export list omits `(..)`) only where there's an
invariant to protect. Currently the only sealed case in the whole file:
- `RoutineDue`'s `RoutineWithin` case — construct only via
  `mkRoutineWithin`, which enforces `from <= to`.

No other type currently requires sealing.

Everywhere else (`IntakeRequestPriority`, `AvailableSlot`,
`SubmittedIntakeRequest`, `TriagedIntakeRequest`, `AppointedIntakeRequest`,
`IntakeRequest`, ...) constructors are exported openly via `(..)` —
deliberate, because those types have no invariant beyond what their own
field types already enforce. Under the spec-for-codegen framing above, this
distinction isn't incidental: sealed vs. open *is* part of the spec — it
tells the generating agent exactly where validation logic needs to exist
downstream and where it doesn't. Don't seal a type "for consistency" without
identifying the actual invariant it protects — that would be adding a false
signal to the spec.

## Layering

Two layers today, not three: pure `Domain` (this file) → `Persistence`
(`src/Persistence.hs`, with its own `toDomainX`/`fromDomainX` boundary
functions — row-shaped, not JSON-shaped) → `Service` (`src/Service.hs`),
which orchestrates both. Confirmed by reading all three files in full — no
stale references to pre-redesign types remain anywhere in the chain.

There is currently no Transport layer, no DTO twin types, and no `aeson`
dependency, because nothing in this repo has an external JSON-facing
boundary yet (no API exists). A Transport layer is the right thing to
introduce when API generation actually starts (see `triage-api-codegen`),
shaped by whatever that API layer concretely needs — not before, and not
speculatively now. Don't build one ahead of that need.