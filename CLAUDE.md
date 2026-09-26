# triage

Medical appointment scheduling system: Haskell backend (Servant + PostgreSQL)
and a React frontend. "triage" refers to the priority-sorting waitlist
protocol — name is provisional.

## Purpose — Domain.hs is a specification, not just an implementation

`src/Domain.hs` is the pure domain model and the single source of truth for
its types and transition functions. Its types, export list, and smart
constructors are written to make domain rules machine-legible: Claude Code
reads this file as the spec and derives the downstream layers (DB schema,
Persistence, Service, Transport/API, UI) from it via the codegen skills below.

When editing `Domain.hs` you're writing the thing every other layer is
derived from. An ambiguity or missing invariant propagates into every
generated layer.

## Commands

Toolchain is **cabal** (no `stack.yaml`). `cabal.project` pins
`with-compiler: ghc-9.10.3`, which must already be on PATH
(e.g. `ghcup install ghc 9.10.3`).

Run successfully when this file was last updated (2026-09-26):
- `cabal build all`
- `cabal test` — hspec/QuickCheck: pure `Domain` properties plus a check
  that every API body's `ToJSON` matches its Swagger schema. No database
  tests exist.
- `cd frontend && npm run build` (`tsc -b && vite build`)

Inferred from configuration, not run:
- `cabal repl`
- Apply schema: `psql <db-url> -f migrations/0001_init.sql`. Migrations are
  a manual step; nothing runs them at startup.
- `cabal run triage-server` — needs Postgres. Reads `TRIAGE_DB_URL`
  (default `postgresql://localhost/triage`) and `TRIAGE_PORT` (default
  8080). Swagger UI at `/swagger-ui`, spec at `/swagger.json`.
- `cd frontend && npm run dev` — Vite on 5173; API base URL from
  `VITE_API_BASE_URL`, default `http://localhost:8080`.
- `cd frontend && npm run generate-types` — regenerates
  `src/api/types.ts` from the running backend's `/swagger.json`.
- `docker build .` — backend image only; frontend hosting is undecided.

## Modules and dependencies

Direct imports between internal modules (no cycles):
- `Domain` — imports none of the others
- `Persistence` → `Domain`
- `Service` → `Domain`, `Persistence`
- `Transport` → `Domain`, `Service` (for `CalendarEntry` only)
- `Api` → `Domain`, `Persistence`, `Service`, `Transport`
- `app/Main.hs` → `Api`

- **`src/Domain.hs`** — pure types and functions; depends only on
  `base`/`text`/`time`/`uuid`. No IO, SQL, or JSON awareness.
- **`src/Persistence.hs`** + **`migrations/0001_init.sql`** —
  postgresql-simple. Row types with row-shaped `toDomainX`/`fromDomainX`
  (decoding fails loudly with `DecodeError`); fetch/insert/persist
  functions all take a plain `Connection`.
- **`src/Service.hs`** — one function per use case, each taking a
  `ConnectionPool`: fetch, check the stored state, call the Domain function
  (or construct the Domain case directly), persist. Mints IDs; takes
  timestamps as parameters. Reports caller mistakes/failures as
  `ServiceError` and legitimate concurrent results as outcome types
  (`MatchOutcome`, `SlotCreationOutcome`). Also exposes read pass-throughs
  and the `CalendarEntry` view.
- **`src/Transport.hs`** — aeson DTO twin types with hand-written
  `ToJSON`/`FromJSON`/`ToSchema` and JSON-shaped `toDomainX`/`fromDomainX`.
  Domain types carry no JSON instances. Imports `Service` for
  `CalendarEntry`.
- **`src/Api.hs`** — Servant REST routes, handlers, config, CORS, Swagger.
  Handlers supply timestamps (`getCurrentTime`). Mutations respond with an
  `{"outcome", "detail"}` envelope. `app/Main.hs` just calls `Api.main`.
- **`frontend/`** — React 18 + TypeScript + Vite, Mantine, TanStack Query,
  react-router. Pages in `src/pages/`; `src/api/types.ts` is generated
  (don't hand-edit); `src/api/client.ts` is the fetch wrapper.

## Where each guarantee lives

Don't assume the type system alone guarantees valid lifecycle transitions
or protects against races. Enforcement is split:

- **Types / smart constructors (Domain):** each lifecycle stage embeds its
  predecessor whole, so an `AppointedIntakeRequest` can't be built without
  a `TriagedIntakeRequest`. `mkRoutineWithin` enforces `from <= to`. Types
  do *not* prove a value matches what is currently stored.
- **Pure functions (Domain):** `matches` / `matchIntakeRequestToSlot` check
  service, doctor requirement, and time window; `checkIntakeWaitlist` picks
  the highest-priority eligible request. Reject, stale, withdraw, close and
  reclaim (`appointed.triaged`) are direct construction, with no Domain
  function.
- **Service:** verifies the stored state before each transition (e.g.
  accept/reject require `Submitted`, match/stale require `Accepted`,
  reclaim/close require `Appointed`). This check is a separate read, not
  held in a transaction with the write.
- **Persistence writes:** match, reclaim, mark-stale and close use
  state-conditioned `UPDATE`s with affected-rows checks (`ClaimOutcome`),
  so a concurrent change surfaces as an outcome. Matching (delete slot +
  update request) runs in one transaction with rollback
  (`persistMatchedIntakeRequest`). **Accept and reject currently use
  unconditional `UPDATE`s** — no race guard, which conflicts with
  `triage-service-codegen`'s guard-every-fetch-then-write-gap rule. It's a
  known discrepancy, not a pattern to copy.
- **Database:** a `CHECK` on `intake_requests` enforces each state's column
  shape, plus the tier/deadline and close-reason shapes; durations limited
  to 15/30/60 minutes; foreign keys. `doctor_calendar` (maintained by
  triggers) plus an `EXCLUDE` constraint prevents overlapping slot or
  appointment intervals per doctor. The DB does **not** check transition
  order or `RoutineWithin` ordering (Persistence and Transport re-check the
  latter when decoding).

## Sealing in Domain.hs — selective, and that's the point

Constructors are hidden only where an identified invariant needs
protection. Currently the only sealed case: `RoutineDue`'s `RoutineWithin`
— built only via `mkRoutineWithin` (`from <= to`). The read-only
`routineWithinBounds` exists so other layers can encode it without the
constructor.

Other constructors remain open deliberately. Their field types enforce
structural requirements, while matching eligibility is checked by domain
functions. Constructing an `AppointedIntakeRequest` directly does not prove
that matching checks were performed. Sealed vs. open *is* part of the
spec: it tells the generating agent where downstream validation must
exist. Don't seal a type "for consistency" without naming the invariant it
protects, and never derive `FromJSON` generically on a sealed type.

## Codegen skills — read before changing downstream layers

- `triage-db-codegen` — migration + `Persistence.hs`
- `triage-service-codegen` — `Service.hs`
- `triage-api-codegen` — `Transport.hs` + `Api.hs` (plus its `references/`)
- `triage-ui-codegen` — `frontend/`

Some skill text predates the current code (e.g. `triage-api-codegen` still
says no API exists). Where a skill's description of *current state*
conflicts with code, trust the code and point out the conflict. Don't
silently follow either one.

## Workflow discipline (non-negotiable)

- One decision at a time. Don't bundle multiple design changes into one turn.
- No code for unvalidated requirements. If a rule sounds plausible but
  wasn't discussed with the domain expert (the doctor), leave it out.
- Model perfection is a deliberate goal, not over-engineering. If a type
  requires ceremony to explain, the model is wrong — fix the model, don't
  write a comment.
- Scale target is a small practice of 2-3 doctors. Don't reach for
  infrastructure (event sourcing, CQRS, etc.) sized for a problem this isn't.

## Before touching code, read the relevant doc

- `src/Domain.hs`: `docs/domain-model.md` and `docs/modeling-principles.md`.
- Persistence or architecture changes: `docs/decisions.md` — check whether
  the idea was already explored and rejected. Some entries are marked
  superseded; follow the superseding entry.
- Open questions live at the bottom of `docs/decisions.md`. Don't resolve
  them in code without the domain expert.
