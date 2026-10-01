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

Run successfully when this file was last updated (2026-09-30):
- `cabal build all`
- `cabal test` — runs the three suites below.
  - `cabal test triage-test` — hspec/QuickCheck: pure `Domain` properties
    plus a check that every DTO's, request body's and answer's `ToJSON`
    matches its own OpenAPI 3 schema. No database needed. Run 2026-10-01:
    85 examples, 0 failures.
  - `cabal test triage-db-test` — the SQL behind Persistence/Service against
    a real PostgreSQL (`test-db/Spec.hs`): creates a throwaway database,
    applies `migrations/0001_init.sql`, drops it afterwards. Needs a local
    server the current user can create databases on; extra libpq keywords
    via `TRIAGE_TEST_PG`. Run 2026-10-01: 32 examples, 0 failures.
  - `cabal test triage-schema-test` — the CHECK constraints on
    `intake_requests` against a real PostgreSQL, raw SQL only (no
    dependency on the library): each case's column shape from a
    classification table written from `Domain.hs`. `TRIAGE_SCHEMA_FILE`
    overrides the schema file. Run 2026-10-01: 20 examples, 0 failures.
- `cd frontend && npm run build` (`tsc -b && vite build`)

Inferred from configuration, not run:
- `cabal repl`
- Apply schema: `psql <db-url> -f migrations/0001_init.sql`. Migrations are
  a manual step; nothing runs them at startup.
- `cabal run triage-server` — needs Postgres. Reads `TRIAGE_DB_URL`
  (default `postgresql://localhost/triage`) and `TRIAGE_PORT` (default
  8080). Swagger UI at `/swagger-ui`, OpenAPI 3 spec at `/openapi.json`.
- `cd frontend && npm run dev` — Vite on 5173; API base URL from
  `VITE_API_BASE_URL`, default `http://localhost:8080`.
- `cd frontend && npm run generate-types` — with the backend running,
  regenerates `src/api/types.ts` from its `/openapi.json`
  (openapi-typescript v7). Run 2026-10-01. Don't hand-edit `types.ts`.
- `docker build .` — backend image only; frontend hosting is undecided.

## Modules and dependencies

Direct imports between internal modules (no cycles):
- `Domain` — imports none of the others
- `Persistence` → `Domain`
- `Service` → `Domain`, `Persistence`
- `Transport` → `Domain`
- `Api` → `Domain`, `Persistence`, `Service`, `Transport`
- `app/Main.hs` → `Api`

- **`src/Domain.hs`** — pure types and functions; depends only on
  `base`/`containers`/`text`/`time`/`uuid`. No IO, SQL, or JSON awareness.
- **`src/Persistence.hs`** + **`migrations/0001_init.sql`** —
  postgresql-simple. Row types with row-shaped `toDomainX`/`fromDomainX`
  (decoding fails loudly with `DecodeError`); fetch/insert/persist
  functions all take a plain `Connection`.
- **`src/Service.hs`** — one function per use case, each taking a
  `ConnectionPool`: fetch, check the stored state, call the Domain function
  (or construct the Domain case directly), persist. Mints IDs; takes
  timestamps as parameters. Reports caller mistakes/failures as
  `ServiceError` and legitimate concurrent results as outcome types
  (`TransitionOutcome`, `MatchOutcome`, `SlotCreationOutcome`). A request found
  past the state an operation expects is `MovedOn`/`IntakeRequestMovedOn`;
  one in a state that can't follow it is `IntakeRequestInWrongState`. Also
  exposes read pass-throughs and the `DoctorCalendarEntry` view.
- **`src/Transport.hs`** — aeson DTO twin types with hand-written
  `ToJSON`/`FromJSON`/`ToSchema` and JSON-shaped `toDomainX`/`fromDomainX`.
  Domain types carry no JSON instances.
- **`src/Api.hs`** — Servant REST routes, handlers, config, CORS, OpenAPI spec.
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
  a `TriagedIntakeRequest`. `mkRoutineWindow` enforces
  `routineNotBefore <= routineNotAfter`.
  `mkDoctorCalendar`/`addAvailableSlot` enforce no overlap per doctor
  within a `DoctorCalendar` value; `addAvailableSlot` creates a new slot
  with its service's duration. Types do *not* prove a value matches
  what is currently stored.
- **Pure functions (Domain):** `matches` / `matchIntakeRequestToSlot` check
  service, doctor requirement, and time window; `matchByPriority` picks
  the highest-priority eligible request. Reject, stale, withdraw and close
  are direct construction, with no Domain function. Every lifecycle path is
  one-way; displacing or rescheduling a patient is a close plus a new
  request.
- **Service:** verifies the stored state before each transition (e.g.
  accept/reject require `Submitted`, match/stale require `Accepted`,
  close requires `Appointed`; slot creation checks
  `addAvailableSlot` against the doctor's stored calendar), and checks that
  every patient, doctor and service id it's given exists (`PatientNotFound`,
  `DoctorNotFound`, `HealthcareServiceNotFound`). These checks are separate
  reads, not held in a transaction with the write.
- **Persistence writes:** every lifecycle transition (accept, reject,
  match, mark-stale, close) uses an `UPDATE` conditioned on the
  expected current state, with an affected-rows check (`ClaimOutcome`), so
  a concurrent change surfaces as an outcome instead of being overwritten.
  The state guard gives both legality and freshness because no transition
  leads back to an earlier state and every update changes the state.
  Matching (delete slot + update request) runs in one transaction with
  rollback (`persistAppointedIntakeRequest`).
- **Database:** a `CHECK` on `intake_requests` enforces each state's column
  shape, plus the tier/deadline and close-reason shapes; durations limited
  to 15/30/60 minutes; foreign keys. `doctor_calendar` (maintained by
  triggers) plus an `EXCLUDE` constraint prevents overlapping slot or
  appointment intervals per doctor. A `CHECK` also enforces
  `RoutineWindow`'s `routineNotBefore <= routineNotAfter` (Persistence and
  Transport re-check it when decoding). The DB does **not** check transition order.

## Sealing in Domain.hs — selective, and that's the point

Constructors are hidden only where an identified invariant needs
protection. Currently two sealed cases:
- `RoutineWindow` (carried by `RoutineDue`'s `RoutineWithin`) — built only
  via `mkRoutineWindow` (`routineNotBefore <= routineNotAfter`). It has no
  record fields, since record update would bypass the check; the named,
  read-only accessors `routineNotBefore`/`routineNotAfter` let other layers
  encode it.
- `DoctorCalendar` — built only via `mkDoctorCalendar` and grown only via
  `addAvailableSlot` (no two entries of a doctor overlap). This invariant
  spans stored rows, so the database (`doctor_calendar`'s `EXCLUDE`) is
  what enforces it for stored data; the type declares it.

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
- `triage-api-codegen` — `Transport.hs` + `Api.hs`
- `triage-ui-codegen` — `frontend/`

Skill text can fall behind the code; it has before. Where a skill's
description of *current state* conflicts with code, trust the code and
point out the conflict. Don't silently follow either one.

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
- Persistence or architecture changes: `docs/decisions.md` holds the
  current decisions and what each one rejected. To check whether an idea
  was tried and dropped earlier, also search `docs/decisions-history.md`.
  It's never a description of the current code.
- Open questions live at the bottom of `docs/decisions.md`. Don't resolve
  them in code without the domain expert.
