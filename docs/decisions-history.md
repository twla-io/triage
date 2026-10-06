# Decisions — history

Superseded decisions, kept verbatim. Read this only to answer "was this
already tried, and why was it dropped?" — never as a description of the
current system. Names, rules and cross-references here may no longer exist;
`docs/decisions.md` holds the current decisions.

## Rescheduling: reassignIntakeRequestSlot, not a CloseReason variant (2026-07-11)

**Superseded (2026-07-13):** by "Reassignment and displacement both compose
from reclaimAppointedIntakeRequest, not a dedicated transition" below —
`reassignIntakeRequestSlot` no longer exists; a real bug in its
Persistence-layer counterpart led to a simpler design that removes the
dedicated transition entirely rather than fixing it in place. Kept here
for history. The rejection below (a `CloseReason`-variant representation)
still holds independently of which mechanism replaced the
dedicated-transition approach — the new design doesn't reintroduce it
either.

**Decided:** Moving an appointed request to a different slot is modeled as
`reassignIntakeRequestSlot :: AppointedIntakeRequest -> AvailableSlot ->
Maybe AppointedIntakeRequest` — it re-checks the same structural eligibility
(`matches`) against the proposed slot and, on success, produces a new
`AppointedIntakeRequest` with the new slot's doctor/time/duration hard-copied
in. The old slot's facts are discarded, not freed or returned — there is no
slot-level state to transition (see `deleted-on-match`). The request stays
`Appointed` throughout; its `IntakeRequestId` and embedded
`TriagedIntakeRequest` are unchanged.

**Rejected:** the original representation, `CloseReason`'s `Rescheduled
AppointmentParty` constructor — closing the request to reschedule conflated
"this request is done" with "this request moved," losing the appointed
request's identity across the move.

**Why:** a request being rescheduled is still the same request, still
`Appointed` — closing it to represent a slot change would mean an
`AppointedIntakeRequest`'s identity doesn't survive an operation that
shouldn't affect its identity at all.

## RoutineWithin needs a read-only bounds accessor (2026-07)

**Decided:** `routineWithinBounds :: RoutineDue -> Maybe (UTCTime, UTCTime)`
added to `Domain.hs`, since `RoutineWithin`'s constructor is
deliberately unexported (protecting `mkRoutineWithin`'s `from <= to`) but
Persistence still needs to read its bounds back out to encode an
already-valid value. See `sealed-value-decomposition` in
`triage-db-codegen` — this is decomposition, not reconstruction, so
replay-through-a-gate-function doesn't apply; a plain read-only accessor
does.

## Reassignment write gained a state guard, closing a latent race (2026-07-11)

**Found** while redesigning `reassignAppointedIntakeRequestSlot`, unrelated
to the IntakeRequest merge itself: the pre-existing
`persistReassignedAppointment` had no `WHERE state = 'open'` guard on its
UPDATE at all, unlike `persistClosedAppointmentIfOpen`'s equivalent guard —
a concurrent close racing a reassignment could silently overwrite
doctor/time/duration on an already-closed row.

**Decided:** `persistReassignedIntakeRequest` now guards
`WHERE state = 'appointed'`, the same affected-rows pattern as every other
conditional write in this module. `AlreadyClaimed` from this guard is
reported the same way as any other closed-row collision —
`RequestAlreadyClosed`, not a new outcome category.

**Why this belongs here, not just in code comments:** per the
"Concurrent-match races" entry's own closing note, a future session
touching this function without this reasoning on hand could plausibly
"simplify" the guard back out, not realizing it closes a real (if latent)
bug rather than adding unneeded ceremony.

## Reassignment and displacement both compose from reclaimAppointedIntakeRequest, not a dedicated transition (2026-07-13)

**Superseded (2026-09-28):** reclaim was removed; reassignment and displacement are now a close plus a new `IntakeRequest`. See "Reclaim removed; displacing a patient is Closed + a new IntakeRequest" below. (Earlier, in part (2026-09-27): the "No new `Domain.hs` function is needed" point — reclaim got a signature, `reclaimIntakeRequest`. See "Reclaim gets a signature in Domain.hs" below.)

**Found:** `persistReassignedIntakeRequest` had a real bug — it updated
`intake_requests`' `appointed_doctor_id`/`start_time`/`duration_minutes`
to the new slot's values but never deleted the `slots` row that slot came
from. Because `doctor_calendar`'s cross-table `EXCLUDE` constraint (see
"Overlap prevention" above) tracks `slots` rows as live intervals, the
still-present slot row and the newly-written appointment interval for the
same doctor/time would collide against each other, so the write would
reject via the `23P01` exclusion-violation path it's already wired to
catch — the caller would see `NewSlotAlreadyClaimed` for a slot that was
in fact free. Found while investigating a documentation pass on the
`triage-db-codegen` skill, not by design.

**Rejected fix:** simply add the missing `deleteSlot` call to
`persistReassignedIntakeRequest`, wrapped in `withTransaction` like
`persistMatchedIntakeRequest`. This would have worked, but it would make
reassignment a second, parallel implementation of exactly what matching
already does correctly — the same delete-a-slot-and-update-the-request
transaction, duplicated for no gain, now two places to keep in sync
instead of one.

**The actual insight:** `AppointedIntakeRequest` already embeds the
`TriagedIntakeRequest` it came from, unchanged, as its `triaged` field
(see "AppointedIntakeRequest hard-copies doctor/time/duration, embeds
TriagedIntakeRequest whole" above). Reclaiming an `Appointed` request back
to `Accepted` is therefore free — `appointed.triaged` already *is* the
value to return to. No re-triage happens, no new information is produced,
the same `IntakeRequestId`/`triagedAt`/priority survive exactly. No new
`Domain.hs` function is needed for this either, same precedent as
`Rejected`/`Closed`: direct field access, not a wrapped transformation.

**Decided:** `reassignIntakeRequestSlot`, `persistReassignedIntakeRequest`,
and `reassignAppointedIntakeRequestSlot` are removed entirely, replaced by
one new primitive — `reclaimAppointedIntakeRequest` (`Service.hs`), backed
by `persistReclaimedIntakeRequest` (`Persistence.hs`), a single-table
`UPDATE ... WHERE state = 'appointed'` moving the row back to `'accepted'`
and nulling `appointed_doctor_id`/`start_time`/`duration_minutes`. Nothing
about `doctor_calendar` needs to change — its existing trigger already
deletes the corresponding row on any `'appointed'` → non-`'appointed'`
transition.

"Reassignment" and "displacement" are not two different mechanisms
needing their own dedicated transition — they're both compositions of
this one primitive with an operation that already exists and is already
correct:

- **Reassignment** = `reclaimAppointedIntakeRequest`, then
  `matchAcceptedIntakeRequestToSlot` against a different slot, same
  doctor, back-to-back.
- **Displacement** = `reclaimAppointedIntakeRequest` alone — the request
  falls back into the ordinary waitlist (`state = 'accepted'`), no new
  `IntakeRequest`, no lost history.

Whether the vacated original time becomes bookable again is still not
automatic either way — that's a separate, explicit `createAvailableSlot`
call by the caller, per `deleted-on-match`'s existing convention. This was
already true of the old `reassignIntakeRequestSlot` design and isn't
changed by this one.

**A side effect worth naming explicitly:** this resolves half of the
fairness-reversal concern flagged in "IntakeRequest: Appointment folded
into one sum type, one identity" above — the worry that a displaced
patient's original wait time and clinical judgment would be lost unless
the doctor happened to write it into a new request's narrative. That
concern doesn't apply here: displacement now reuses
`reclaimAppointedIntakeRequest`, which preserves the *same*
`IntakeRequestId`, `triagedAt`, and `priority` exactly — nothing is lost
structurally, and no narrative-writing habit is needed to preserve it.
This is a consequence of the design, not a mitigation layered on top.

**What this does NOT decide:** whether a displaced patient's priority
should be *bumped* as a compensating policy (e.g. moved up a tier, or
given an earlier deadline, for having been displaced) is a separate,
genuinely open question, untouched by this change — see Open Questions
below.

## Reclaim gets a signature in Domain.hs (2026-09-27)

**Superseded (2026-09-28):** reclaim was removed. See "Reclaim removed; displacing a patient is Closed + a new IntakeRequest" below.

**Found:** a clean-room generation from `Domain.hs` and `triage-db-codegen` alone derived every lifecycle transition's source case from its input type — except reclaim, which existed only as field access (`Accepted appointed.triaged`) described in a comment. `Accepted`'s constructor takes `TriagedIntakeRequest`, Accepted's own payload, so the Appointed source was invisible in the types. The 2026-07-13 entry had called this the same precedent as `Rejected`/`Closed`, but those are constructors that take the source stage (`Rejected SubmittedIntakeRequest …`, `Closed AppointedIntakeRequest …`), so their source case is derivable; reclaim's wasn't.

**Decided:** `reclaimIntakeRequest :: AppointedIntakeRequest -> TriagedIntakeRequest` in `Domain.hs`. It is still just the embedded value — no re-triage, same `IntakeRequestId`/priority/`triagedAt` — but now every transition is a function or constructor signature, so `updates-follow-domain-transitions` derives the whole transition set from types with no hand-kept row. `Service.reclaimAppointedIntakeRequest` calls it, pairing the way `acceptIntakeRequest`/`acceptSubmittedIntakeRequest` do. A property test checks that reclaiming undoes a match exactly.

## Row version for freshness; state guard kept for legality (2026-09-27)

**Superseded (2026-09-28):** the version was removed after reclaim was. See "Row version removed; the state guard also gives freshness" below.

**Found:** reclaim made Accepted ⇄ Appointed a cycle. Between a close or reclaim's fetch and its write, the request could be reclaimed and re-matched to a different slot; the row is back in `'appointed'`, `WHERE state = 'appointed'` passes, and the write acts on an appointment its caller never saw. The earlier assumption that "state itself is the version discriminator" no longer held.

**Decided:** separate the two properties. *Legality* (A → B is allowed) comes from `Domain.hs` and stays enforced by the state guard (`updates-follow-domain-transitions`). *Freshness* (the row is the one the caller decided from) gets a row version: `intake_requests.version`, bumped by a `BEFORE UPDATE` trigger on every update; every read-decide-write checks `AND version = ?` (`row-version-for-freshness`). Persistence returns `Versioned a` from the fetches decisions are made from; every transition write takes the `RowVersion`. `Domain.hs` is unchanged.

**Rejected:** guarding on the observed appointment fields (fixes only this case, not several A → B functions or A → A edits); locking with `SELECT … FOR UPDATE` (prevents rather than detects — a new convention, when the project already reports lost races as outcomes); `SERIALIZABLE` + retry (heavier than 2–3 doctors need). The state guard is kept alongside the version: the version catches concurrent writes, the state guard catches our own code attempting a transition `Domain.hs` doesn't allow.

**Not decided:** carrying the version to clients so an action taken on a stale screen is caught. Out of scope for now. The version column went into `migrations/0001_init.sql` directly, not a new migration, since no database has had the schema applied beyond local development.

## A lost version race is reported as "changed since read" — one outcome, no retry (2026-09-27)

**Superseded (2026-09-28):** replaced by "Request-state answers follow the lifecycle: moved on, or wrong state" below. (Earlier the same day: the outcome was kept while the row version was removed, detected by the state guard alone.)

**Found:** with the row version in place, a zero-row write can no longer mean "wrong state" (Service confirmed the state at fetch time, and an unchanged version means an unchanged row) — it always means the request changed since it was read. But each operation still reported it with a guess at *how*: close and reclaim said `RequestAlreadyClosed`, mark-stale `RequestNotAccepted`, match `RequestAlreadyClaimed` ("already scheduled, drop it"). Each is wrong when the request was reclaimed and re-matched, or matched and reclaimed back to the waitlist.

**Decided:** one uniform result. Operations without an outcome type of their own (accept, reject, reclaim, mark stale, close) return `Either ServiceError (Fresh a)`, `Fresh a = Applied a | ChangedSinceRead`; `MatchOutcome` gains `RequestChangedSinceRead`. On the wire both are `{"outcome": "requestChangedSinceRead"}`. It is an outcome, not a `ServiceError` — losing a race is never the caller's mistake (`error-vs-outcome-types`). Nothing retries: the caller decided from what it saw, and re-running (say) a close against a re-matched request would close an appointment it never looked at.

**Rejected:** a `RequestChangedSinceRead` `ServiceError` (smaller, but breaks `error-vs-outcome-types`); automatic retry (acts on data the caller never saw).

**Also:** the accept, reject and mark-stale forms ignored non-success outcomes entirely (only match showed them), so `requestNotSubmittedAnymore` was already invisible. They now show them, with readable text for `requestChangedSinceRead`.

## Triage decides the doctor requirement, for any priority (2026-09-28)

**Superseded in part (same day):** `requestedDoctor` was then removed — see "The doctor requirement is only a triage decision" below.

**Found:** `Domain.hs`'s comment said Emergency/Urgent requests can't require a specific doctor ("no time slack to spend waiting"), but `doctorRequirement` sat on `SubmittedIntakeRequest`, set before triage, and `matches` enforced it at every priority. Demonstrated against the real module: an Emergency that asked for Dr A was refused Dr B's slot ten minutes out, and the waitlist gave that slot to a Routine request. The comment and the types had disagreed since `4db1a10` introduced both; triage had no way to drop the requirement.

**Decided:** two facts, two fields. `SubmittedIntakeRequest.requestedDoctor` is what was asked for; `TriagedIntakeRequest.doctorRequirement` is what triage decided, and the only one matching uses. `acceptIntakeRequest` takes it, for any priority — an Emergency or Urgent request waits for a specific doctor only if triage explicitly keeps one (continuity of care), and the triage form warns when it does. Storage: `requested_doctor_id` and `required_doctor_id`, the latter `NULL` before triage (`CHECK`).

**Rejected:** a `considerDoctorRequirement :: Bool` on the triaged request (allows meaningless `True` + `AnyDoctor`, and can't say "a different doctor than requested"); `Routine RoutineDue DoctorRequirement` so only Routine can carry one (structural, but rules out continuity of care for urgent patients, and needs a tie-break policy in `Ord IntakeRequestPriority`).

**Also:** `generate-types` was broken (the backend serves Swagger 2.0; openapi-typescript v6 and v7 read only OpenAPI 3). It now converts the spec with `swagger2openapi` first and keeps openapi-typescript v7, so `types.ts` keeps its format. Serving OpenAPI 3 from the backend (`servant-openapi3`) remains the long-term option.

## checkIntakeWaitlist renamed matchByPriority (2026-09-28)

**Decided:** `Domain.checkIntakeWaitlist :: AvailableSlot -> [TriagedIntakeRequest] -> Maybe AppointedIntakeRequest` is renamed `matchByPriority`. No behavior change.

**Why:** both halves of the old name claimed something the function doesn't do. "check" suggests a predicate or a validation; the function decides — it sorts the requests by priority and matches the first one that fits the slot, the many-request counterpart of `matchIntakeRequestToSlot`. "Waitlist" claims the list is the waitlist, which a function taking any `[TriagedIntakeRequest]` can't know — the very argument `Service.hs`'s naming rule (`verifies-the-precondition`) uses to give "waitlist" to `Service.matchWaitlistToSlot`, which fetches the real waitlist. The new name states what decides between eligible requests: priority.

**Rejected:** `matchHighestPriorityToSlot` (pairs with `matchIntakeRequestToSlot`, but long) and names built on "most corresponding" or "best" (every eligible request fits equally; priority is what decides). `triage-api-codegen`'s rule `checkwaitlist-not-an-endpoint` becomes `match-by-priority-not-an-endpoint`.

## ServiceError stays uniform, for now (2026-10-01)

**Decided:** one `ServiceError` for every use case, so every answer lists all six error tags.

**Known cost:** the types claim errors a use case can't produce (a read "may" answer `slotDoesNotMatchIntakeRequest`). Callers must handle impossible cases, and a new case would widen every function silently.

**Planned, in its own service-skill round:** an error type per use case, derived from the use case's shape: each id parameter gives `<Entity>NotFound`; a transition source that a later state can't follow gives `InWrongState`; a Domain function returning `Maybe` gives its refusal.

**Rejected:** listing the reachable tags by reading function bodies (derived from code rather than types; nothing would catch it going wrong).

## Doctor calendar: the no-overlap rule is declared in Domain.hs and enforced by the database (2026-09-27)

**Superseded (2026-10-06):** by "Callers read the sealed collection, not its elements" in `decisions.md`: slot creation now reads the calendar over the new slot's interval for every doctor, through the one calendar read, and the calendar has a read-only accessor. Kept here for history.

**Problem:** the rule once lived only in the `EXCLUDE` constraint, invisible to anyone reading the spec.

**Why Domain.hs can declare it but not enforce it:** it spans every stored entry of a doctor, and a `DoctorCalendar` value is only a snapshot of what was read. Enforcing the rule with a pure check alone would be the check-then-insert race above.

**Decided:**

- `DoctorCalendarEntry = Slot AvailableSlot | Appointment AppointedIntakeRequest` lives in `Domain.hs`, and the rule is stated over it.
- `DoctorCalendar` is sealed and practice-wide (`Map DoctorId (Map UTCTime DoctorCalendarEntry)`), matching the single `doctor_calendar` table.
- There are two ways in. `mkDoctorCalendar :: [DoctorCalendarEntry] -> Maybe DoctorCalendar` rebuilds a calendar from stored entries. `addAvailableSlot` is the only domain operation that adds time. Appointments arrive by matching, which takes over the slot's exact interval, so `matchIntakeRequestToSlot` takes no calendar.
- `Service.createAvailableSlot` fetches the doctor's entries overlapping the new slot (`fetchDoctorCalendarOverlapping`, which reads the source tables in one `REPEATABLE READ` snapshot, per `one-snapshot-per-read`), checks `addAvailableSlot`, then inserts. A failed check and an `EXCLUDE` violation both answer `AvailableSlotOverlapsDoctorCalendar`.
- Stored entries that already overlap fail decoding (`OverlappingDoctorCalendar`), which surfaces as a 500.

**Rejected:**

- `DoctorCalendar` as the enforcement (load, check, save): the race above. A versioned aggregate would close the race, but it gives appointments two owners and is enforced by convention.
- A calendar per doctor: `addAvailableSlot` would need a second failure reason.
- A fetch window of "start minus the longest duration": it hard-codes a 60-minute maximum outside `Domain.hs`.

**General rule:** `Domain.hs` declares every invariant. One within a single value maps to a `CHECK`; one spanning rows maps to `EXCLUDE` or `UNIQUE`, and only the latter depends on the database to hold for stored data.

---
