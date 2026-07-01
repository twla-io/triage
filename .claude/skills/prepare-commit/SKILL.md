---
name: prepare-commit
description: Prepare a commit — analyze the current git diff, regenerate README.md's generated domain-model section if src/Domain.hs changed in a way that affects it, flag (don't auto-edit) any docs/ files that may now be stale, draft a commit message from the actual diff, and stage the files. Use this whenever the user says "prepare a commit", "commit these changes", "help me commit", "get ready to commit", "stage this", or similar — before any actual `git commit` runs. Always stop and show the user the diff/message before committing; never push.
---

# Prepare commit

Manual, on-demand version of the readme-sync + decision-logging workflow —
run this instead of relying on a hook. Nothing here executes automatically;
it only runs when invoked.

## Step 1 — see what actually changed

```
git status
git diff HEAD
git diff --staged
```

Look at both staged and unstaged changes — don't assume everything you're
about to commit is what's currently staged. If there's nothing to commit,
say so and stop.

## Step 2 — does `src/Domain.hs` need a README regen?

If `src/Domain.hs` is not in the diff at all, skip to Step 3.

If it is, don't guess from the diff hunk alone whether README needs
updating — the diff shows what changed, not what's now inconsistent. Instead:

1. Read the **full current** `src/Domain.hs` (not just the diff) — same
   rule as the `readme-sync` skill: always read the file, never work from
   memory of what it used to contain.
2. Read the current README.md's generated section (between the
   `<!-- DOMAIN-MODEL:START -->` / `END` markers).
3. Compare. The regen is warranted if the diff touched anything
   README's generated section actually describes: exported types, exported
   constructors (sealed vs. open), field names, the `Ord`/protocol function
   signatures, or the codegen-skills pointer. It's **not** warranted if the
   diff only changed something internal that isn't exported, or changed a
   comment, or changed an internal helper's implementation without touching
   its type.
4. If warranted, regenerate the generated section following the
   `readme-sync` skill's rules exactly (scope, sourcing, TODO-on-ambiguity).
   Show the user a diff of the change before writing it, unless they've
   already said to just proceed.
5. If not warranted, say explicitly why not (e.g. "Domain.hs changed but
   only in an internal helper not covered by README's generated section —
   no regen needed") rather than silently skipping.

## Step 3 — flag (don't touch) other docs

Check whether the diff plausibly makes any of these stale, and if so, name
the specific claim that might now be wrong — don't edit them yourself:

- `docs/domain-model.md` — narrative description of types/behavior.
- `docs/decisions.md` — especially: does this diff look like it's
  implementing something that was still listed as an "open question"? If
  so, point that out — the user may want to move it from open question to
  decided, but that's their call, not something to do silently as a
  side-effect of preparing a commit.
- `docs/modeling-principles.md` — flag only if the diff seems to violate a
  stated principle (e.g. state-specific data added to a shared type); don't
  flag routine changes that follow it.

Present these as a short list for the user to act on or dismiss, separate
from the commit itself.

## Step 4 — draft the commit message

Write the message from what the diff actually contains — don't describe
intent you're inferring, describe the change. If the diff spans unrelated
concerns (e.g. a Domain.hs change plus an unrelated formatting fix), say so
and suggest splitting into separate commits rather than writing one message
that papers over two changes.

Keep it in the repo's existing style if there's commit history to infer one
from (`git log --oneline -10`); default to a short imperative summary line
plus a body only if the change needs explanation beyond the summary.

## Step 5 — stage and stop

`git add` the relevant files (including the regenerated README.md if Step 2
produced one). Show the final `git status` and the drafted commit message.

**Stop here.** Do not run `git commit` or `git push` without the user
explicitly confirming the message and approving the commit. This skill
prepares a commit; it does not create one unattended.