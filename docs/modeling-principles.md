# Modeling principles

Not specific to this repo — these are house rules for domain modeling in
Haskell-and-similar type systems. Worth keeping in sync with `pattermino` and
any other project using the same discipline.

## State-specific data belongs on the state type

If a field is only meaningful in one lifecycle state, it lives on that
state's type — never hoisted onto a shared "details" type just because it's
convenient to read from one place.

Example: `declinedBy :: Set WaitlistEntryId` belongs on `PendingSlot`, not on
`SlotDetails`. `SlotDetails` should be the immutable core that's true across
*every* lifecycle state — the moment it carries a field that's meaningless in
some states, it's stopped being that.

## Embed previous state, don't duplicate fields

When a state is "the previous state plus a claim placed on it," model it as
literally containing the previous state:

```haskell
data OfferedSlot = OfferedSlot
  { slot      :: PendingSlot
  , offeredTo :: WaitlistEntryId
  }
```

`OfferedSlot` *is* a `PendingSlot` with an offer on top. This gets history
for free (no re-deriving "what was this before") and turns operations like
`expireOffer` into pure unwraps (`slot . offeredSlot`) instead of manual
field-by-field reconstruction.

## Types should read as domain narrative

A type signature shouldn't need an explanatory comment to be understood by
someone who knows the domain. If it does, the model is wrong — restructure
the type, don't paper over it with prose. No ambiguity, no room for
misinterpretation: model precision is the deliberate goal here, not
incidental rigor.

## Don't add mechanisms speculatively

A rule that sounds plausible (priority escalation, auto-retry, whatever) does
not go into the model until it's been validated with the actual domain
expert. Unvalidated complexity is expensive to carry and cheap to add later —
the asymmetry always favors leaving it out until confirmed.