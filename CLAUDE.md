# CLAUDE.md

Instructions for Claude Code working in this repository. Read this before making
any change to `src/Domain.hs` or writing a commit message.

## What this project is

`triage` is a Haskell domain model for medical appointment scheduling, built
through extensive design discussion with a practicing doctor as domain expert.
The name is provisional — open to renaming if a better one arises.

The core idea: instead of reserving dedicated emergency slots (which sit idle
on quiet days), every slot is offered to the highest-priority matching request
on a waitlist. See `src/Domain.hs`'s inline comments for the reasoning behind
each type — they explain the current rule and the one reason it matters, not
the history of how it was decided. Match that style in any comments you add.

## Before generating downstream code

If you're generating a database schema, an API, or a UI from this domain
model, read the relevant skill first — don't improvise conventions that are
already decided:

- `skills/triage-db-codegen` — database schema generation
- `skills/triage-api-codegen` — API generation
- `skills/triage-ui-codegen` — UI/UX generation

Each separates fixed invariants (always apply) from genuine architecture
choices (confirm with whoever owns that layer before assuming one).

## Domain modeling principles

These are non-negotiable when touching `src/Domain.hs`:

1. **State-specific data belongs on the state type, not on shared details.**
   E.g. `declinedBy` lives on `PendingSlot`, not `SlotDetails` — `SlotDetails`
   is the immutable core, true in every lifecycle state.

2. **Embed previous state in next state rather than duplicating fields.**
   E.g. `OfferedSlot { slot :: PendingSlot, ... }` — an `OfferedSlot` IS a
   `PendingSlot` with a claim placed on it. Carries history for free; the
   reverse transition becomes a pure unwrap.
   When two types must always be produced as a pair, reinforce this at the
   module boundary: hide both constructors and expose a single function that
   produces both. `OfferedSlot` and `AppointmentRequestWithOffer` are the
   example — `giveOffer` is the only way to produce either.

3. **Possession framing over identity framing**, when a type wraps something
   that hasn't changed identity. `AppointmentRequestWithOffer` and `HasOffer`
   are correct because the request doesn't become a different kind of thing
   when it gets an offer — it's the same request, now carrying one.
   `OfferedAppointmentRequest` and `offerRequest` were wrong for exactly this
   reason and were renamed.

4. **Type signatures should read as domain narrative without explanation.**
   If a type requires ceremony to understand, the model is wrong. No
   ambiguity, no room for misinterpretation — this is a deliberate goal, not
   over-engineering.

5. **Do not add domain rules speculatively.** If a rule sounds plausible but
   wasn't actually validated with the doctor, leave it out — cheaper to add
   later than to carry unvalidated complexity now. (`escalateToUrgent` was
   added, then removed for exactly this reason — see git history.)

6. **Don't keep complexity that doesn't earn its keep.** A wrapper function
   that adds zero behavior beyond what it wraps (e.g. the removed
   `sortWaitlist = sort`) should be deleted, not kept for symmetry.

## Comments

Public, open-source audience — assume the reader has no access to any design
conversation that produced the code. A comment should state the current rule
and, if non-obvious, the one reason it matters. It should never narrate how a
decision was reached, what was tried before, or reference a removed feature's
backstory. If a comment only makes sense to someone who was part of the
original discussion, cut it or rewrite it so it doesn't need that context.

## Naming

Before introducing a name, check it doesn't collide with an existing
constructor elsewhere in the module — Haskell constructors must be globally
unique per module, and this has bitten us before (`Emergency`/`Urgent`/
`Routine` colliding between `AppointmentPriority` and the waitlist type;
`Offered` colliding between `Slot` and `WaitlistRecord`).

## Commit messages

The body must explain **why** a change was made, not just restate what the
diff shows. If a commit is a pure rename or cleanup with no behavior change,
say so explicitly — that tells a reviewer the commit is safe to skim.

- Subject line: imperative mood ("Rename X to Y", not "Renamed" or "Renaming"),
  under ~70 characters
- Body: one bullet per logical change, each explaining the reasoning, not
  just the mechanics
- End with a line stating whether behavior changed, when it's not obvious

## Build

```
cabal build
cabal test
```

This project uses plain Cabal, not Stack. No specific reason is recorded for
that choice — just match it rather than introducing Stack tooling alongside it.