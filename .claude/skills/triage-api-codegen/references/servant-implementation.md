# Servant Implementation

This is the implementation-level companion to `rest.md`: `rest.md` settles *what* the routes and status codes are; this document settles *how* they're built in Haskell — framework, file layout, handler environment, error-translation middleware, and request-body shapes. Everything below is decided, not illustrative.

## 1. Framework: Servant

Servant, not Scotty or Yesod. The deciding factor is compile-time route/handler correspondence — a mismatch between the route type and the handler that serves it is a type error, not a runtime 404 or a silent wrong-handler dispatch. That property matches this codebase's existing philosophy more than either alternative:

- Scotty's routing is runtime-only — routes and handlers are wired by value, not checked by the type system, which is exactly the class of bug (`opaque-uuid-ids`-adjacent, but at the routing layer instead of the ID layer) this codebase has otherwise avoided by construction (sealed types, exhaustive `case` matches, `doctor_calendar`'s `EXCLUDE` constraint enforcing overlap-freedom in the database rather than in application code).
- Yesod brings a heavier feature set (templating, scaffolding, a wider dependency footprint) than a 2-3-doctor-scale API needs — the same no-speculative-infrastructure reasoning CLAUDE.md already applies to event sourcing and CQRS applies here too.

Servant's route-type-as-contract is the one of the three that extends the "push invariants into the type system" approach already used throughout `Domain.hs` up into the API layer, rather than introducing a different verification philosophy at the boundary.

## 2. File organization: single `src/Api.hs`

One file, not split across `Api/Doctor.hs`, `Api/IntakeRequest.hs`, etc. — matches `Domain.hs`/`Persistence.hs`/`Service.hs`/`Transport.hs` all being single, internally-sectioned files rather than directories of modules.

Within `Api.hs`, route types are grouped per resource — `DoctorAPI`, `PatientAPI`, `HealthcareServiceAPI`, `SlotAPI`, `IntakeRequestAPI`, `CalendarAPI` — composed into one top-level `API` type via `:<|>`. Each resource's route type, its handlers, and its sub-server wiring (`ServerT DoctorAPI AppM`, etc.) are interleaved within that resource's own banner-commented section, the same convention `Persistence.hs`/`Service.hs` already use (`-- ═══...` section banners grouping a type with its own functions) — **not** a signatures-then-bodies split where every route type is declared up top and every handler body follows in a separate block further down.

**Why grouped, stated explicitly:** `Server API` is a value whose handler list is matched against the `API` type's branches *positionally* — `:<|>` has no name-based correspondence Servant can check between "this branch of the type" and "this handler in the list." A flat `API` type with all ~21 routes as siblings in one `:<|>` chain means a single reordering (adding a route in the middle, or reordering during a refactor) silently misaligns some handler with the wrong route — a runtime bug a type-driven framework was chosen specifically to avoid. Grouping per resource bounds this risk to 3-6 branches per resource's own sub-`:<|>` chain instead of ~21 (Service.hs itself exposes 22 operations across reads and mutations per `SKILL.md`'s own counts, but `matchWaitlistToSlot` is deliberately not one of them as its own route, per `checkwaitlist-not-an-endpoint` — see `rest.md`) — a misalignment within one resource's own small group is far more likely to be caught by inspection or by the first failing request against that resource, rather than silently propagating across the whole API.

## 3. Handler environment: `AppM = ReaderT ConnectionPool Handler`

No wrapper environment record. `AppM` is bare `ReaderT ConnectionPool Handler` — not `ReaderT AppEnv Handler` with an `AppEnv` record wrapping the pool (plus, speculatively, whatever else a "real" app environment might eventually hold: logging, config, feature flags). Nothing beyond the connection pool is needed by any handler today, so nothing else is introduced. A wrapper record gets added only if and when something concrete actually requires it — the same no-speculative-infrastructure discipline CLAUDE.md already states for the domain layer (don't reach for event sourcing/CQRS sized for a problem this isn't) applies identically here: don't reach for an environment record sized for an app this isn't, yet.

**This deliberately does not inherit `Service.hs`'s own convention of an explicit `ConnectionPool` parameter on every function.** The two conventions solve different problems:

- `Service.hs` functions are library-style entry points, called from multiple contexts (`test/Spec.hs`, and `Api.hs`'s own handlers) — an explicit parameter keeps them composable and directly callable from anywhere without needing a particular monad stack in scope.
- `Api.hs` handlers are called from exactly one place — Servant's own request dispatch — so there's no composability to protect by keeping the pool explicit there too. Threading it implicitly via `ReaderT` removes repetitive plumbing with no corresponding loss, since the call site diversity that motivates `Service.hs`'s explicit-parameter convention doesn't exist at the handler layer.

## 4. Error/outcome translation middleware

`Service.hs` functions return in exactly three shapes, and each needs different treatment when translated into an HTTP response:

- **(a) bare `IO a`** — reads with no decode risk (`fetchDoctor`, `fetchDoctors`, etc., over `DoctorRow`/`PatientRow`, which have no invariant to fail against — see `Persistence.hs`). Nothing to translate; the handler just runs it and returns `200` with the value.
- **(b) `IO (Either DecodeError a)`** — reads that can fail to decode a stored row (`fetchHealthcareService`, `fetchAvailableSlots`, `fetchIntakeRequest`, `fetchCalendarView`, ...). No `ServiceError` is involved at all here — a `DecodeError` is unconditionally `500`, per `error-vs-outcome-mapping`'s own `500` case (`PersistenceDecodeError`/anything outside the domain's vocabulary).
- **(c) `IO (Either ServiceError a)`** — mutations. Here the split is *not* uniform: only `PersistenceDecodeError` (one constructor of `ServiceError`) is `500`; every other `ServiceError` constructor (`RequestNotFound`, `RequestNotSubmittedAnymore`, ...) is a `200` with a discriminated body, per `error-vs-outcome-mapping`.

Four shared `AppM`-returning helpers exist: `runRead` for (b), and `runService`/`runMatchOutcome`/`runSlotCreation` for (c) and its two outcome-typed relatives (see below) — plus `envelope`/`envelopeEmpty` as small shared response builders, not counted as outcome-translation helpers in their own right since neither one, alone, decides what's `500` versus `200`. A single, uniform helper covering every shape doesn't work precisely because they disagree about whether *every* Left is `500` or only one constructor of it is, and (for `MatchOutcome`/`SlotCreationOutcome` below) about whether there's an `Either`/`ServiceError` layer at all.

**Why a naive `Either ServiceError a`-preserving `runService` was rejected:** a version that merely throws a `500` as a side effect when it sees `PersistenceDecodeError`, while still returning `Either ServiceError a` as its type, leaves `PersistenceDecodeError` sitting in the return type as a case that can never actually reach the caller (it was already handled, by throwing, before returning) — a phantom, unreachable branch every caller would still have to pattern-match against to be exhaustive, for a case that can't occur. `runService` instead needs to narrow away that constructor before handing anything back to its caller.

**Settled: `runService` takes a success tag string and a `toDetail` conversion function — not `onSuccess`/`onError` continuations, and not a `NonDecodeServiceError`-narrowed type.** The deciding check was whether the error side genuinely varies per call site, and it doesn't: every non-decode `ServiceError` constructor (`RequestNotFound`, `RequestNotSubmittedAnymore`, `RequestNotAccepted`, `RequestNotYetTriaged`, `RequestNotAppointed`, `RequestAlreadyClosed`) carries the same shape — an `IntakeRequestId` — and needs identical rendering regardless of which mutation handler produced it. Passing a per-call-site `onError` continuation would only invite two handlers rendering the same error differently by accident — exactly the inconsistency centralizing this middleware in the first place was meant to prevent. What *does* genuinely vary per call site is only the success side: the value's own DTO conversion, and the success outcome's tag name. This resolves the phantom-case problem more completely than either original option: both `NonDecodeServiceError`-narrowing and `onError` continuations still leave the *same* six-constructor mapping re-derived — identically — across all ~10 mutation call sites. This shape instead writes that mapping exactly once, exhaustively, with no wildcard, and callers supply only what's actually handler-specific.

`handleServiceError` is factored out as its own function specifically so `runService` and the two outcome-typed helpers below can share it without duplicating the same seven-way match three times:

```haskell
handleServiceError :: ServiceError -> AppM Value
handleServiceError (PersistenceDecodeError e)       = throwError err500 { errBody = encode e }
handleServiceError (RequestNotFound rid)            = pure (envelope "requestNotFound" rid)
handleServiceError (RequestNotSubmittedAnymore rid) = pure (envelope "requestNotSubmittedAnymore" rid)
handleServiceError (RequestNotAccepted rid)         = pure (envelope "requestNotAccepted" rid)
handleServiceError (RequestNotYetTriaged rid)       = pure (envelope "requestNotYetTriaged" rid)
handleServiceError (RequestNotAppointed rid)        = pure (envelope "requestNotAppointed" rid)
handleServiceError (RequestAlreadyClosed rid)       = pure (envelope "requestAlreadyClosed" rid)

runService :: ToJSON dto => Text -> IO (Either ServiceError a) -> (a -> dto) -> AppM Value
runService successTag action toDetail = do
  result <- liftIO action
  case result of
    Left se -> handleServiceError se
    Right a -> pure (envelope successTag (toDetail a))

envelope :: ToJSON dto => Text -> dto -> Value
envelope tag detail = object ["outcome" .= tag, "detail" .= toJSON detail]

envelopeEmpty :: Text -> Value
envelopeEmpty tag = object ["outcome" .= tag, "detail" .= Null]
```

`envelopeEmpty` exists for outcome constructors with no payload — `"detail"` is always present as a key, its value is `null` rather than the key being omitted, the same "key always present, value nullable" convention already established for `CloseReasonDTO`'s `note` field.

**`runMatchOutcome`**, for `matchAcceptedIntakeRequestToSlot`/`matchWaitlistToSlot`'s `IO (Either ServiceError MatchOutcome)` shape. `MatchOutcome` is its own 5-constructor sum type on the success side, not a single value the caller converts via `toDetail` — `runService`'s tag/`toDetail` parameterization was built for one uniform success shape, so it doesn't fit here; this needs its own exhaustive match instead:

```haskell
runMatchOutcome :: IO (Either ServiceError MatchOutcome) -> AppM Value
runMatchOutcome action = do
  result <- liftIO action
  case result of
    Left se                     -> handleServiceError se
    Right (Matched appointed)   -> pure (envelope "matched" (fromDomainAppointedIntakeRequest appointed))
    Right NoEligibleRequest     -> pure (envelopeEmpty "noEligibleRequest")
    Right RequestIneligible     -> pure (envelopeEmpty "requestIneligible")
    Right SlotAlreadyClaimed    -> pure (envelopeEmpty "slotAlreadyClaimed")
    Right RequestAlreadyClaimed -> pure (envelopeEmpty "requestAlreadyClaimed")
```

**`runSlotCreation`**, for `createAvailableSlot`'s bare `IO SlotCreationOutcome` shape — no `ServiceError`/`Either` at all (confirmed against `Service.hs` directly: `SlotCreated AvailableSlot | SlotConflict`):

```haskell
runSlotCreation :: IO SlotCreationOutcome -> AppM Value
runSlotCreation action = do
  outcome <- liftIO action
  pure $ case outcome of
    SlotCreated slot -> envelope "slotCreated" (fromDomainAvailableSlot slot)
    SlotConflict     -> envelopeEmpty "slotConflict"
```

**A real design question was raised and settled here: should `POST /slots` (`createAvailableSlot`) also invoke `matchWaitlistToSlot` and combine both results into one response?** `checkwaitlist-not-an-endpoint` (`SKILL.md`) already says the handler that creates a slot is the natural place to also call `matchWaitlistToSlot` — but "the natural place to call it" and "compose its result into the same response" are different questions, and this rejects the second. Composing the two at the API layer would mean `Api.hs` implementing an orchestration decision `Service.hs` itself doesn't make: `createAvailableSlot` and `matchWaitlistToSlot` are two fully independent `Service.hs` functions, and nothing in `Service.hs` composes them into one call. A newly created `AvailableSlot` has two genuinely independent paths to being consumed — a manual claim via `matchAcceptedIntakeRequestToSlot`, or automatic dispatch via `matchWaitlistToSlot` — and neither is a default the other subsumes; composing them into one API response would silently privilege the automatic path over the manual one. **The actual, current answer:** `POST /slots`'s response reflects *only* `createAvailableSlot`'s own `SlotCreationOutcome`, via `runSlotCreation`, full stop. Whether and how a newly created slot gets matched against the waitlist afterward is left open — unaddressed by this endpoint, for later. (`checkwaitlist-not-an-endpoint`'s own text in `SKILL.md` may still read as implying composition; that text hasn't been updated with a cross-reference to this resolution in this pass — flagging that as outstanding rather than silently leaving the two documents in tension.)

**A related idea was also raised and rejected: remodeling `MatchOutcome`/`SlotCreationOutcome` as `Either`-shaped types, to parallel `ServiceError`'s own `Either` shape.** Rejected because `Either`'s `Left` carries a near-universal failure connotation that would misrepresent most of `MatchOutcome`'s non-`Matched` constructors — `NoEligibleRequest`, `SlotAlreadyClaimed`, `RequestAlreadyClaimed`, `RequestIneligible` — none of which are failures, they're outcomes, exactly the blurring `error-vs-outcome-types` (`triage-service-codegen`) already exists to prevent. This is the same underlying lesson as `docs/decisions.md`'s `TriageOutcome` rejection, approached from the opposite direction: that entry rejected a shared wrapper type across two *different* functions' outcomes because each call site already commits to one outcome, leaving a structurally-unreachable branch at every call site — a false signal. Here, the near-miss is reaching for a generic/shared container (`Either`) over a purpose-built type (`MatchOutcome`/`SlotCreationOutcome`) for aesthetic symmetry with `ServiceError`, rather than because `Either`'s own semantics actually fit what these two types represent.

**Response envelope for mutations:** every mutation endpoint's `200` body is `{"outcome": <string>, "detail": <payload>}` — one generic shape reused across every mutation endpoint, not a bespoke response DTO per endpoint (e.g. not a hand-rolled `AcceptResponseDTO`, `RejectResponseDTO`, ... one per route). This is consistent with `tagged-flat-serialization`'s own governing principle — one parsing rule at every nesting level, not one rule per type — applied here at the level of "how does a client parse any mutation's response" rather than just "how does a client parse any `Domain.hs` sum type." It also keeps the `ServiceError`/outcome-type → wire mapping fully centralized in this middleware, rather than re-derived piecemeal per handler through each one choosing its own field names. Reads have no equivalent envelope — a read's `200` body is just the plain resource payload (a `DoctorDTO`, a list of them, ...), since a successfully-decoded read has no `ServiceError`/outcome-type ambiguity left to discriminate in the body.

The four-code scheme (`400`/`404`/`200`/`500`) itself is `error-vs-outcome-mapping` (`SKILL.md`), unchanged here — this section is what actually implements that already-settled rule in Servant terms, not a restatement of the rule itself.

## 5. Request-body DTOs: caller-supplied facts only, never timestamps

Every `UTCTime` parameter in a `Service.hs` mutation's signature — `submitIntakeRequest`'s `createdAt`, `acceptSubmittedIntakeRequest`'s `triagedAt`, `rejectSubmittedIntakeRequest`'s `rejectedAt`, `CloseReason`'s embedded `Cancelled` timestamp, and so on — is supplied by the **handler** calling `getCurrentTime`, never accepted as a request-body field. There is no case among the mutation endpoints where a client legitimately needs to assert a timestamp rather than the server recording "now" — accepting a client-supplied timestamp in any of these bodies would only invite clock-skew or spoofing issues, with no corresponding benefit to weigh against that risk.

The settled request-DTO shape per mutation:

| `Service.hs` function | Request body |
|---|---|
| `createDoctor` / `createPatient` | `{name}` |
| `createHealthcareService` | `{name, duration: DurationDTO}` |
| `createAvailableSlot` | `AvailableSlotDTO`, reused directly |
| `submitIntakeRequest` | `{patientId, narrative, doctorRequirement: DoctorRequirementDTO}` |
| `acceptSubmittedIntakeRequest` | `{healthcareServiceId, priority: IntakeRequestPriorityDTO}` |
| `rejectSubmittedIntakeRequest` | `{reason}` |
| `matchAcceptedIntakeRequestToSlot` | `AvailableSlotDTO`, reused directly |
| `reclaimAppointedIntakeRequest` | no body |
| `closeAppointedIntakeRequest` | `{closeReason: CloseReasonRequestDTO}` |

**`CloseReasonRequestDTO`** is a new, separate type — not `CloseReasonDTO` reused. It mirrors `CloseReasonDTO`'s three cases (`Completed`/`Cancelled`/`NoShow`) minus `Cancelled`'s timestamp field, since that timestamp is exactly the kind of server-supplied fact excluded above. A `closeReasonFromRequest :: CloseReasonRequestDTO -> UTCTime -> CloseReason` function converts one into a real `CloseReason` once the handler has called `getCurrentTime` and has a timestamp to supply for the `Cancelled` case.

**Why a separate type rather than loosening `CloseReasonDTO` itself:** `CloseReasonDTO`'s existing `FromJSON` correctly requires `cancelledAt` to be present when parsing a `Cancelled` case — that's the right behavior for a *response* DTO, where a fully-formed `CloseReason` (including when it was cancelled) is what's being deserialized. Making `cancelledAt` optional so the same type could double as a request body would weaken that guarantee for the response-parsing direction too, since both directions share the one `FromJSON` instance — there's no way to loosen it only for requests without also loosening it for responses. A second, request-only type keeps the response type's existing correctness intact.

## 6. Retroactive fix this design surfaced: `Duration`'s wire shape in `Transport.hs`

Designing the request-body table above (`createHealthcareService`'s `duration: DurationDTO`) surfaced a genuine bug in already-committed `Transport.hs` code: `Duration` had been serializing as a raw `durationMinutes :: Int` — a magic number a client would need to separately know the meaning of (15/30/60) — rather than as a tagged enum. That `Int` shape had been mistakenly carried over from `Persistence.hs`'s storage convention (where minutes-as-`Int` is the right column type) without re-examining whether it also fit the wire layer, where it didn't: every other closed enum in `Transport.hs` (`AppointmentParty`, `CloseReason`, `IntakeRequestPriority`'s tiers) already got `tagged-flat-serialization`'s proper `{"type": ...}` treatment, and `Duration` deserved the same, not an exception. This has since been fixed: `Duration` now serializes via `DurationDTO` (`{"type": "quarterOfAnHour"}` / `{"type": "halfAnHour"}` / `{"type": "oneHour"}`), and — as a side effect, not a goal in itself — `HealthcareServiceDTO`'s and `AvailableSlotDTO`'s `toDomain` functions became fully total (`Duration` was the only decode-failure source either of them had; an unrecognized wire tag now fails to parse before either `toDomain` function ever runs, rather than surfacing as an `Either TransportError` value they'd have to construct).

## 7. `main` and wiring

**`AppConfig`** is a plain record — `dbConnectionString`, `serverPort` — loaded from environment variables (`TRIAGE_DB_URL`, `TRIAGE_PORT`) with defaults.

**A deliberate asymmetry in how missing/bad config is handled:**
- `TRIAGE_DB_URL` missing → silently falls back to a local-dev default connection string.
- `TRIAGE_PORT` present but malformed (not parseable as a port number) → fails loudly at startup, not a silent fallback to a default port.

The reasoning: a wrong port that silently defaulted could run unnoticed — the server comes up, appears healthy, and is simply listening somewhere nobody expects, which is a much harder failure to notice than a crash. A startup crash on bad config is immediately actionable and costs nothing at boot, since nothing has served a single request yet. The two knobs get different treatment because the cost of getting each wrong silently is different, not because of any general rule that env vars should always/never default.

**Connection pool:** sized at 10 connections, 60-second idle timeout — explicitly flagged as an unrefined placeholder appropriate to current scale (2-3 doctors), not a tuned value. Revisit if/when connection contention or idle-churn actually becomes observable, not preemptively.

**`hoistServer`** converts `ServerT API AppM` into `Server API` by supplying `runAppM pool` (running the `ReaderT` down to `Handler`) once, at server-construction time — not per-handler. Every handler is written against `AppM`, and the one `hoistServer` call is what threads the pool through all of them uniformly.

**`main` only starts the server.** Running migrations (`migrations/0001_init.sql`) is explicitly a separate, manual/external step — never invoked from application code, not even as a "check and apply if needed" convenience on startup. This keeps "ensure the schema is correct" and "start serving requests" as distinct concerns with distinct operators (a deploy/ops step vs. the application process itself), rather than conflating schema migration with application startup.
