# Decisions

Current decisions: what was decided, what was rejected, and why, so the next
session doesn't re-litigate settled questions. Every entry describes the
system as it is now. When a decision changes, its entry is rewritten and the
old text moves verbatim to `decisions-history.md`. Open questions are at the
bottom.

## Domain.hs is the specification every layer is derived from (foundational)

**Decided:** `src/Domain.hs` is the specification of the domain model, not one implementation of it. Its names, sealed types and smart constructors make domain rules machine-legible. The other layers are derived from it by four codegen skills: `triage-db-codegen` (the migration and `Persistence.hs`), `triage-service-codegen` (`Service.hs`), `triage-api-codegen` (`Transport.hs` and `Api.hs`) and `triage-ui-codegen` (`frontend/`). The skills hold only generic mapping rules and conventions; facts about specific types live in `Domain.hs`.

**Consequence:** sealing is part of the spec. A hidden constructor tells the generating agent that an invariant exists which the downstream layers must enforce; an open one says there is none. Sealing a type without an identified invariant, or leaving open a type that has one, misinforms every generated layer.

## A lifecycle sum type is one table with a state column (2026-07-11)

**Decided:** a sum type whose cases are stages of one identity is stored as one table: a `state` column, every case's values as nullable columns, and one CHECK per case pinning its shape. `IntakeRequest`'s seven states (`submitted`, `rejected`, `accepted`, `appointed`, `withdrawn`, `stale`, `closed`) live in `intake_requests`.

**Why:** transitions are frequent and the set of cases is small and closed. A table per case would move the row between tables on every transition, for no query benefit at this scale.

**Rejected:** one side-table per state; a separate `appointments` table beside the requests (see "Appointment folded into IntakeRequest").

## Event sourcing: explored, rejected (2026-06)

**Considered for:** the slot and intake-request lifecycles.

**Rejected because:** sealed types already give most of what event sourcing would add (only valid states can be represented, and transitions are explicit). An event store, replay and projections cost more than a practice of 2–3 doctors justifies. Revisit only if the scale assumptions change.

## No Generic-derived JSON instances (2026-06)

**Found:** a Generic-derived `FromJSON` on a sealed Domain type bypasses the seal, because the derivation runs inside the module where the constructors are visible.

**Decided:** `Domain.hs` types carry no JSON instances. Each type that crosses the wire has a `<Type>DTO` twin in `Transport.hs`, with hand-written `ToJSON`, `FromJSON` and `ToSchema`, never Generic-derived. Its `toDomain` function goes through the smart constructor, so validation happens at that boundary.

## Appointment folded into IntakeRequest: one sum type, one identity (2026-07-11)

**Decided:** an `IntakeRequest` is the path from a patient's ask to one appointment. Its whole lifecycle is one sum type of seven cases under one `IntakeRequestId`; there is no `Appointment` type or `AppointmentId`. Rows are never deleted: each transition updates `state` in place. The Accepted requests waiting for a slot are a plain `state = 'accepted'` read.

**Why:** a request and its appointment are 1:1, permanently.

**Rejected:** the name `HealthcareRequest` (it suggests a whole ongoing care need, not one intake); a separate `Appointment` aggregate with its own table and id; deleting a request row when it is matched.

## Doctor-originated requests use the same flow

**Decided:** a doctor scheduling a follow-up submits and accepts an ordinary request, possibly back to back. Nothing requires the patient to have written it, or any time to pass between submission and triage.

**Open:** whether requests written by a doctor and by a patient need to be told apart. Nothing needs this today.

## Matching deletes the slot and updates the request in one transaction (2026-07-11)

**Decided:** `persistAppointedIntakeRequest` deletes the `available_slots` row and moves the `intake_requests` row from `accepted` to `appointed`, copying the doctor, start and duration, in one `withTransaction`. If the slot delete affects no row, the slot was already taken; Service answers `AvailableSlotConsumed`. If the request update affects no row, an internal exception rolls back the slot delete; Service answers `IntakeRequestMovedOn` with the request as it is now.

**Why:** matching writes two tables. If the slot delete succeeds and the request's claim then loses its race, the slot must come back. Reporting the loss isn't enough; it needs a rollback.

**Rejected:** inserting into a separate `appointments` table and deleting the slot (that table no longer exists).

## A slot is deleted when matched (2026-07-11)

**Decided:** `AvailableSlot` is the only slot type, and there is no booked state. On a match, the slot's facts are copied into the appointment and its row is deleted. A slot that isn't found is reported as `AvailableSlotConsumed`: once slots are deleted on match, "taken a moment ago" and "never existed" look the same, and a lost race is an outcome, not an error. Making a time bookable again after a close means explicitly creating a new slot.

**Why:** a booked state stores the same facts in two places with nothing forcing them to agree. This caused a real bug: a slot was returned as freed while the closed appointment still claimed it was booked.

**Rejected:** keeping a two-state slot and referencing it by `SlotId` from the appointment.

## Each stage embeds the previous stage whole (2026-07-11)

**Decided:** `SubmittedIntakeRequest` is the base record (`id`, `patientId`, `narrative`, `createdAt`). Each later stage embeds the stage it followed and adds only its own facts: `TriagedIntakeRequest` adds the service, priority, doctor requirement and `triagedAt`; `AppointedIntakeRequest` adds `doctorId`, `start` and `duration`, copied from the matched slot; the terminal stage records add their own facts (`rejectedAt`, `withdrawnAt`, `staleAt`, `closeReason`, …). Every stage record is open; there's no invariant to protect.

**Why:** a stage can't be built without the whole stage before it, and no fact is stored twice. Once matched, the slot no longer exists, so the appointment copies its facts rather than referencing it.

**Rejected:** an `IntakeRequestDetails` record under a zero-field wrapper (indirection, with no invariant); referencing the slot by `SlotId` (the reference would dangle after the slot is deleted on match); a sealed `BookedSlot` wrapper as proof that `matches` passed (any caller can build a `TriagedIntakeRequest` that passes, so it protects nothing).

## CloseReason: Completed, Cancelled or NoShow (2026-07-11)

**Decided:** `CloseReason = Completed | Cancelled Cancellation | NoShow Absence`. `Cancellation { cancelledBy, cancelledAt, cancellationNote }`: `cancelledAt` is when the cancellation happened, not validated against the appointment's start, and the note is optional. Choosing `Cancelled` or `NoShow` is the booking manager's judgment, recorded as given. The close reason stays nested under Closed, not separate `IntakeRequest` cases. (What `absentParty` means is an open question.)

**Rejected:** `Rescheduled` as a close reason (it would merge "this request is done" with "it moved"; see "Every lifecycle path is one-way"); a note on `Completed` (it isn't ambiguous); making the close reasons `IntakeRequest` cases (that mixes "which stage" with "why it ended").

## RoutineWithin ordering: a narrower window breaks ties on the upper bound (2026-09-26)

**Decided:** two `RoutineWithin` windows compare by `routineNotAfter` (earlier first), then by `routineNotBefore` descending (the narrower window first). `compare` is `EQ` exactly when the windows are equal, consistent with `Eq`.

**Source:** chosen in discussion while preparing the MuniHac talk. Not confirmed with the domain expert.

## Lost races are found by affected rows, not caught exceptions (2026-07-11)

**Decided:** a write that guards a domain invariant against a race is conditional (`UPDATE … WHERE state = ?`, `DELETE … WHERE id = ?`). It reports the result through its affected-row count (`ClaimOutcome`), never by catching a `SqlError` (`uniqueness-races-are-outcomes`, in `triage-db-codegen`). The one exception is inserting a new element into a collection guarded by a shadow table. An `EXCLUDE` violation has no affected-rows equivalent, so `insertAvailableSlot` catches `23P01`, and only that (see "Overlap prevention").

**Why it's recorded:** a later session could "simplify" the guards or the matching transaction without seeing what they prevent.

**Rejected:** catching constraint violations in general (see "Unknown ids are error facts" for the foreign-key case).

## Withdrawal exists only before an appointment (2026-07-11)

**Decided:** `WithdrawnFrom = FromSubmitted … | FromAccepted …`. There is no case for withdrawing from Appointed: ending an appointed request is always `Closed`, with `Cancelled` and `cancelledBy = PatientParty` when the patient ends it.

**Why:** a `FromAppointed` case would state exactly the same fact as that cancellation.

## Accept is a function; every other transition is direct construction (2026-07-11)

**Decided:** `acceptIntakeRequest` exists because it assembles a `TriagedIntakeRequest` from its arguments. Rejecting, withdrawing, marking stale and closing are done by constructing the case directly (`Rejected RejectedIntakeRequest { … }`, `Closed ClosedIntakeRequest { … }`), with no function. Closed is a case of `IntakeRequest`, not a separate type.

**Why:** a function that only wraps its arguments in a constructor falsely signals work being done.

**Rejected:** `rejectIntakeRequest` and `closeIntakeRequest` as aliases; a separate `ClosedAppointment` type; `TriageOutcome` (`TriageAccepted | TriageRejected`) as a shared result, because each call site already commits to one branch.

## Stale is a staff decision, reachable only from Accepted (2026-07-18)

**Decided:** an Accepted request becomes Stale when staff decide it will never be matched and close it out. It's always an explicit action, never automatic or driven by a timer, and it's done by constructing the case directly, with no Domain function.

**Why:** like `Cancelled` versus `NoShow`, it's a judgment the model records rather than makes.

**Rejected:** marking a request stale automatically when its deadline passes (a timer acting on the waitlist with no person deciding); Stale from Submitted (staleness is measured against a due date, which only exists after triage).

**Source:** taken from `Domain.hs`'s comment, where this has lived since 2026-07-18. Whether the doctor confirmed it isn't recorded.

## Every lifecycle path is one-way; displacing a patient is Closed plus a new request (2026-07-11, reaffirmed 2026-09-28)

**Decided:** Rejected, Withdrawn, Stale and Closed are terminal, and no transition leads back to an earlier state. To displace or reschedule an appointed patient, close the request with `Cancelled` (`cancelledBy = DoctorParty`), then submit and accept a new one. Any context goes into the new narrative. Any compensating priority is a judgment made at triage; the model has no rule for it.

**Why:** a request's history is one linear chain. Closing keeps the cancelled appointment as a record. One-way transitions are also what lets the state guard give freshness (see "The state guard gives legality and freshness").

**Rejected:** keeping a request's identity across displacement (`TriageRecord`, for fairness); reclaiming an Appointed request back to Accepted (tried 2026-07-13 to 2026-09-28: it erased the booked appointment and created a cycle that needed a row version; see history); linking a new request to the one it replaces (`patientId` already groups a patient's requests).

**Cost:** rescheduling is close, submit, accept and match, and the new request gets a new id.

## Overlap prevention: a doctor_calendar shadow table maintained by triggers, with one EXCLUDE (2026-07-11)

**Problem:** no two entries of a doctor may overlap. An entry is an `available_slots` row or an `intake_requests` row in `appointed`, and intervals are half-open (touching endpoints don't overlap). The rule spans two tables, but an `EXCLUDE` constraint sees only one.

**Rejected:**

- *Check-then-insert:* under `READ COMMITTED`, two concurrent inserts can both see no overlap.
- *`pg_advisory_xact_lock` per doctor:* it works and is cheaper, but it is enforced by convention. Any write path that forgets the lock breaks the rule.
- *`SELECT … FOR UPDATE`:* it can't lock rows that don't exist yet, and two inserts racing into empty time is exactly the failure here.
- *`SERIALIZABLE`:* also a convention every writer must opt into, with retry overhead.

**Decided:** `doctor_calendar` holds one row per entry (`doctor_id`, `during`, `source`, and a unique `slot_id` or `intake_request_id`), with `EXCLUDE USING gist (doctor_id WITH =, during WITH &&)` (which needs `btree_gist`). Triggers keep it equal to the source rows: inserting a slot adds its entry, and deleting the slot removes it through `ON DELETE CASCADE`; any insert or update of an intake request removes its entry and adds it back if the new state is `appointed`. So an entry exists exactly while its source row is in the entry's case (`cross-table-invariants-need-a-shadow-table`). The table has no primary key, and the application never reads it; reads go to the source tables.

**Why:** the constraint fires whichever code path, process or trigger wrote the row.

**The one caught exception:** an `EXCLUDE` violation has no affected-rows equivalent, so `insertAvailableSlot` catches `23P01`. Matching doesn't need to: it deletes the slot and adds the appointment over the same interval in one transaction.

**Cost:** the triggers follow `DoctorCalendarEntry`'s cases. If those cases change, the triggers change with them.

## Doctor calendar: the no-overlap rule is declared in Domain.hs and enforced by the database (2026-09-27)

**Problem:** the rule once lived only in the `EXCLUDE` constraint, invisible to anyone reading the spec.

**Why Domain.hs can declare it but not enforce it:** it spans every stored entry of a doctor, and a `DoctorCalendar` value is only a snapshot of what was read. Enforcing the rule with a pure check alone would be the check-then-insert race above.

**Decided:**

- `DoctorCalendarEntry = Slot AvailableSlot | Appointment AppointedIntakeRequest` lives in `Domain.hs`, and the rule is stated over it.
- `DoctorCalendar` is sealed and practice-wide (`Map DoctorId (Map UTCTime DoctorCalendarEntry)`), matching the single `doctor_calendar` table.
- There are two ways in. `mkDoctorCalendar :: [DoctorCalendarEntry] -> Maybe DoctorCalendar` rebuilds a calendar from stored entries. `addAvailableSlot` is the only domain operation that adds time. Appointments arrive by matching, which takes over the slot's exact interval, so `matchIntakeRequestToSlot` takes no calendar. One way out: the read-only accessor `doctorCalendarEntries`.
- `Service.createAvailableSlot` fetches the calendar over the new slot's interval (`fetchDoctorCalendarOverlapping`, the one calendar read; see "Callers read the sealed collection, not its elements"), checks `addAvailableSlot`, then inserts. A failed check and an `EXCLUDE` violation both answer `AvailableSlotOverlapsDoctorCalendar`.
- Stored entries that already overlap fail decoding (`DoctorCalendarRefused`), which surfaces as a 500.

**Rejected:**

- `DoctorCalendar` as the enforcement (load, check, save): the race above. A versioned aggregate would close the race, but it gives appointments two owners and is enforced by convention.
- A calendar per doctor: `addAvailableSlot` would need a second failure reason.
- A fetch window of "start minus the longest duration": it hard-codes a 60-minute maximum outside `Domain.hs`.

**General rule:** `Domain.hs` declares every invariant. One within a single value maps to a `CHECK`; one spanning rows maps to `EXCLUDE` or `UNIQUE`, and only the latter depends on the database to hold for stored data.

## A read built from several queries sees one snapshot (2026-09-29)

**Found:** `fetchDoctorCalendar`, from earlier AI-generated code, read a doctor's slots and appointed requests in two queries under `READ COMMITTED`. A match committing between them deletes a slot and adds an appointment over the same interval: the first query saw the slot, the second the appointment, so the rebuilt calendar held two overlapping entries. `mkDoctorCalendar` refused it, and creating a slot failed with a 500 (`OverlappingDoctorCalendar`), although the stored data was valid. No test or report found this. A clean-room agent, deriving the reads from rules, asked when the smart constructor could refuse data that the database already guarantees valid; the only answer was a read that mixes two moments.

**Decided:** a read built from several queries runs them in one `REPEATABLE READ` transaction (`one-snapshot-per-read`, in `triage-db-codegen`). This applies to `fetchDoctorCalendarOverlapping`, the one calendar read.

**Rejected:** one SQL statement (`UNION ALL`): it always sees one snapshot, but slots and requests have different columns, so the query and its decoding get awkward; reading through the `doctor_calendar` shadow table: its job is enforcing the rule, and reading it is a performance change, made only when measured.

**Not yet done:** a deterministic test: run the read's first query, commit a match on a second connection, run the second query, and check that the calendar still decodes.

## Stored facts are referenced by id, never accepted from the caller (2026-09-27)

**Decided:** an operation on something already stored takes its id and fetches the stored value. The caller never supplies facts the database holds (`stored-facts-by-reference`, in `triage-service-codegen`). API request bodies follow from the Service signatures; match-to-slot, for example, takes `{slotId}`.

**Found:** the match route used to take a whole slot DTO, and the appointment copied the doctor, start and duration the client sent. Any client could book any time it chose. It began with Service functions taking whole values from their caller; the API then decoded them from the request body.

## A slot's duration comes from its healthcare service (2026-09-27)

**Decided:** `addAvailableSlot` takes the `HealthcareService` and copies its duration into the new slot. The request body has no duration field; the UI shows the duration read-only. The slot keeps its own copy, so a later change to the service won't alter existing slots. An unknown service is the error `HealthcareServiceNotFound`, since services are never deleted.

**Rejected:** a composite foreign key `(healthcare_service_id, duration) REFERENCES healthcare_services (id, duration)`. It would block ever changing a service's duration, and existing slots should keep the duration they were created with.

## Updates follow the transitions defined in Domain.hs (2026-09-27)

**Decided:** an `UPDATE` may change a row's case from A to B only if `Domain.hs` defines A → B, as a function or a constructor (`updates-follow-domain-transitions`). It is guarded with `WHERE id = ? AND state = 'A'`, one source case per write, never `state IN (…)`. A is the case whose payload type is exactly the transition's input type. A transition with several possible sources, like withdraw (from Submitted or Accepted), has one guarded write per source.

**Found:** accept and reject once wrote with `WHERE id = ?` only, so a concurrent accept and reject could overwrite each other. `Domain.hs` had the precondition all along; no rule turned it into a guard.

**Consequence:** every non-terminal case needs a distinct payload type. That holds today and must be preserved.

## The doctor requirement is decided at triage (2026-09-28)

**Decided:** `TriagedIntakeRequest.doctorRequirement` is the only doctor requirement, and matching uses it. Triage sets it for any priority, defaulting to any doctor. A patient's preference goes into the narrative, and the submit form's narrative prompt invites one. When triage sets a specific doctor on an Emergency or Urgent request, the triage form warns that the request will wait for that doctor even if others are free before its deadline (continuity of care is allowed, but should be deliberate).

**Warning text:** "This request will wait for that doctor, even if other doctors are free before its deadline."

**Narrative prompt:** "A preferred doctor, if any, can be named here."

**Why:** whoever submits often can't name a doctor precisely, and "Dr Smith again, if possible" says more as text than as an id.

**Rejected:** a separate requested-doctor field on the submitted request (it only pre-filled the form, and nothing enforced it; tried and removed); `considerDoctorRequirement :: Bool` (allows `True` with any doctor); a doctor requirement only on `Routine` (it rules out continuity of care for urgent patients).

**Also:** `generate-types` converts the Swagger 2.0 spec with `swagger2openapi` before running openapi-typescript v7. Serving OpenAPI 3 (`servant-openapi3`) is the long-term option.

## New slots are created by addAvailableSlot; AvailableSlot stays open (2026-09-28)

**Decided:** `addAvailableSlot :: DoctorCalendar -> SlotId -> DoctorId -> HealthcareService -> UTCTime -> Maybe (AvailableSlot, DoctorCalendar)` creates a slot. It checks the slot against the doctor's calendar and takes the duration from the service, so both creation rules are stated in `Domain.hs`. Service checks it before inserting. The `EXCLUDE` constraint stays the authority for stored data; the check before inserting duplicates it on purpose, because it is how the spec declares the rule.

**Rejected: sealing `AvailableSlot`.** A pure module can't prove a value came from storage: `mkDoctorCalendar` is exported, so any single slot can be made to fit an empty calendar. The seal would cost an extra query per slot read and add friction without a guarantee. Revisit only if fabricated slots cause a real bug, and then look at provenance, not sealing.

## Unknown ids are error facts, checked in Service (2026-09-28)

**Found:** a patient, doctor or service id that didn't exist reached the database, failed a foreign key, and surfaced as a 500.

**Decided:** Service checks every id it is given before writing, and reports `<Entity>NotFound` (`PatientNotFound`, `DoctorNotFound`, `HealthcareServiceNotFound`, `IntakeRequestNotFound`). Doctors, patients, services and intake requests are never deleted, so the check can't race the write. Slots are the exception: they are deleted on match, so a missing slot is the outcome `AvailableSlotConsumed`. Every mutation answers with the `{"outcome", "detail"}` envelope, with `ok` for a plain success.

**Rejected:** catching the foreign-key violation (`23503`) in Persistence. It goes against the affected-rows convention, and it would have to work out which id was wrong from the constraint's name.

## The state guard gives legality and freshness (2026-09-28)

**Decided:** every transition write is guarded by its source state alone; there is no row version. This works because no transition leads back to an earlier state and every `UPDATE` changes the state. So a row is in each state at most once, and its data is fixed when it enters that state: if a write finds the state its caller read, the row is the one its caller read.

**Condition to preserve:** both of those. A transition back to an earlier state, or an in-place edit that keeps the state, breaks the argument. A row version is then the known answer (`state-guard-is-freshness` says to stop and ask).

**Rejected** (when reclaim's cycle made freshness a separate problem): guarding on the observed appointment fields (it fixes one case only); `SELECT … FOR UPDATE` (it prevents races rather than detecting them, and would be a new convention); `SERIALIZABLE` with retry (heavier than 2–3 doctors need). A row version was used from 2026-09-27 to 2026-09-28; see history.

## Request-state answers follow the lifecycle: moved on, or wrong state (2026-09-28)

**Decided:** an operation compares the state it expects with the state the request is in.

- **The current state comes after the expected one:** someone else acted first. This is an outcome carrying the request as it is now, whether the fetch noticed or the write did: `TransitionOutcome a = Transitioned a | MovedOn IntakeRequest`, and `IntakeRequestMovedOn` in `MatchIntakeRequestToSlotOutcome`. On the wire it is `movedOn` or `intakeRequestMovedOn`, with the request as `detail`.
- **The current state can't come after the expected one:** the caller made a mistake. This is the error `IntakeRequestInWrongState`, carrying the request, on the wire `intakeRequestInWrongState`.

After a lost write, Service reads the request once more, and that read always finds a later state. Nothing retries, with one exception: a use case with several source states (withdraw) continues once from another of its sources if the re-read finds one (`guard-every-fetch-then-write-gap`). Withdrawn records which state it came from, which keeps the comparison decidable. The comparison lives in each Service operation's case split, exhaustive with no wildcard (`request-state-answers-follow-the-lifecycle`). It is not a Domain function, because an ordering type would exist only to serve error reporting.

**Rejected:** a split that depends on timing (an error if the fetch noticed, an outcome if the write did), which was the earlier behaviour; `ChangedSinceRead` everywhere (it throws away a state that is now knowable, and doesn't separate lost races from caller mistakes).

## RoutineWindow's notBefore ≤ notAfter is also a database CHECK (2026-09-28)

**Found:** a clean-room generation from `Domain.hs` and the skill alone added this CHECK, following the rule that an invariant a sealed type declares over a single value maps to a `CHECK`. The real migration didn't have it. That was a gap, not a choice.

**Decided:** `intake_requests_routine_window CHECK (routine_not_before IS NULL OR routine_not_after IS NULL OR routine_not_before <= routine_not_after)`. Decoding still goes through `mkRoutineWindow` (`InvalidRoutineWindow`) as a second line of defence, and Transport checks it too.

## intake_requests: each state's CHECK names every column (2026-09-28)

**Found:** the per-state CHECK tested only one key column per stage, so a row could carry values its state doesn't have. For example, a `submitted` row with a priority and an appointment time was accepted, and decoding silently dropped the extra values. The fold's rewrite (`7b6b360`) reduced the CHECK to key columns, and later regenerations copied that shape from the existing migration.

**Decided:** one named constraint per constructor, `state <> 'x' OR (…)`, naming every column as required or NULL. A nested sum type's columns are pinned by that type's own CHECK, and a case that records its source (Withdrawn) gets one constraint per source. The schema is derived from `Domain.hs`, never copied from the existing migration. `triage-schema-test` (raw SQL, with a classification table written from `Domain.hs`) fails if any state's CHECK misses a column.

## Every stored value is named in Domain.hs (2026-09-28)

**Found:** `triage-db-codegen` named tables and columns itself (`rejected_at`, `cancelled_at`, `tier`, `slots`, …), because `Domain.hs` gave many stored values no name: positional payloads (`Rejected SubmittedIntakeRequest UTCTime Text`, `Stale TriagedIntakeRequest UTCTime`, `Cancelled AppointmentParty UTCTime (Maybe Text)`, `EmergencyDue UTCTime`, `RoutineWithin UTCTime UTCTime`) and fields stored under other names. So the skill restated the model as a second specification, and it drifted from `Domain.hs` several times (`appointments`, `BookedSlot`, reassignment, a dropped CHECK).

**Decided:** `Domain.hs` names every stored value; the skill holds only generic mapping rules and project conventions, and no fact about a specific type.
- Each lifecycle case's payload is one stage record embedding the stage it followed: `RejectedIntakeRequest { submitted, rejectedAt, rejectionReason }`, `StaleIntakeRequest { triaged, staleAt }`, `ClosedIntakeRequest { appointed, closeReason }`. Not record syntax on `IntakeRequest`'s constructors, whose selectors would be partial.
- `WithdrawnIntakeRequest { withdrawnFrom, withdrawnAt, withdrawalNote }`, with `WithdrawnFrom = FromSubmitted SubmittedIntakeRequest | FromAccepted TriagedIntakeRequest`: the withdrawal's facts stated once. Rejected: one record per case, which declared them twice.
- `CloseReason = Completed | Cancelled Cancellation | NoShow Absence`, with `Cancellation { cancelledBy, cancelledAt, cancellationNote }` and `Absence { absentParty }`. Who cancelled and who was absent are separate facts; the meaning of the latter is an open question below.
- `AppointmentParty = DoctorParty | PatientParty` (was `ByDoctor | ByPatient`): fits both fields, and the stored value is the constructor name, with no "drop the `By`" exception.
- `MustBeSeenBy` replaces `EmergencyDue` and `UrgentDue`: the same fact in both tiers. A routine window is a different fact, so it keeps its own names. Rejected: two deadline columns (the tier would be stored twice).
- `RoutineWithin RoutineWindow`, sealed via `mkRoutineWindow` (replacing `mkRoutineWithin`/`routineWithinBounds`). Its values are read through the named accessors `routineNotBefore`/`routineNotAfter`, not record fields (record update would bypass the check) and not a positional pair (2026-09-30: a pair let two layers match values to names by order only). Their names equal the values of `RoutineNotBefore`/`RoutineNotAfter`, so they share storage.
- `CalendarEntry` → `DoctorCalendarEntry`: names whose calendar, and pairs with `DoctorCalendar`.

**Naming rules:** stated generically in `triage-db-codegen`'s `names-come-from-domain`.

**Cost:** every layer changes (Persistence, Service, Transport, Api, frontend types), regenerated through their skills by clean-room runs, merged in `529dc21`. The frontend is still pending.

## Among equal priorities, the earlier triaged request goes first (2026-10-01)

**Found:** `matchByPriority` sorted only by priority, and `sortOn` keeps input order among equal values. Equal priorities are common (every `RoutineAnytime` ranks equal), and the input was a read with no `ORDER BY`, so Postgres's return order decided which patient got a freed slot.

**Decided:** `sortByPriority :: [TriagedIntakeRequest] -> [TriagedIntakeRequest]` in `Domain.hs` orders by priority, then `triagedAt`, then the submitted request's `createdAt`. `matchByPriority` uses it, and so does any read that lists requests in waitlist order, so the order shown and the order matched are one implementation. Only when all three keys tie does input order decide; the id is not used, since UUID order means nothing.

**Why:** time on the waitlist starts at triage, where the priority itself is set. `createdAt` breaks ties that only become realistic if times are ever entered rather than recorded (see the open question on recorded vs event time).

**Rejected:** `createdAt` as the first tie-breaker (it counts time before triage, when no priority existed); leaving ties to the read's order.

**Source:** decided by the project owner, not confirmed with the domain expert.

## The API serves OpenAPI 3; every sum type is oneOf its cases (2026-10-01)

**Found:** `servant-swagger` was added on 2026-07-17 (`eb4d024`) as the default, and its limitation was noted only in that commit message. Swagger 2.0 has no `oneOf`, so Transport merged each sum type's cases into one object, and where two cases shared a key with different types, the first case's type won: `DoctorCalendarEntry.id` was published as `SlotId` for appointments too. The schema test couldn't notice, since both are UUID strings. Clients got loose types: hand-written payload types, casts, and a `Maybe` key shown as optional, which answers 400 when omitted.

**Decided:** OpenAPI 3 (`openapi3`, `servant-openapi3`) at `/openapi.json`, per `schemas-follow-cases`: each sum is `oneOf` its cases, discriminated by `type` (with no discriminator when a case is itself a `oneOf` over a nested tag); each answer is `oneOf` its outcomes, with a typed `detail`; a `Maybe` key is required and nullable. `generate-types` reads the spec directly.

**Rejected:** making the merge honest on Swagger 2.0 (the contract stops lying but stays lossy); Swagger 2.0's `allOf` plus `discriminator` (its values must be definition names, and the generator doesn't make the parent a union); keeping the `swagger2openapi` conversion (the 2026-09-28 stopgap, which kept the lossy schema).

**Why it's recorded:** the limitation was known from the first day but lived only in a commit message, so two later sessions worked around it instead of revisiting it.

**Cost:** `openapi3`'s validator ignores `nullable`, so the test accepts `null` for `Maybe` fields itself.

## Every 500 is logged with its cause, in one place (2026-10-01)

**Found:** the clean-room regeneration dropped the logging: a decode failure's `DecodeError` was discarded, and database errors fell through to Warp's own "Something went wrong". The skill specified the 500 response but never said it must be recorded.

**Decided:** one `toHandler` catches every synchronous exception, writes it to stderr and answers with the plain body. Service raises a decode failure as Persistence's `DecodeError`, which reaches the same log.

**Rejected:** logging decode failures only (two mechanisms and two bodies); a structured logging library (infrastructure a practice of 2–3 doctors doesn't need).

## The UI derives from Domain.hs and the contract, and copies no Domain logic (2026-10-01)

**Decided:** the UI's sources are `Domain.hs` for meaning (lifecycle, ranks, sealed types, labels), `types.ts` and `/openapi.json` for shapes, and this file for UI behaviour and text a decision states, copied verbatim. It never reads Api, Transport, Service or Persistence. Domain logic has one implementation: the UI doesn't sort (the server returns a defined order), doesn't re-check sealed rules (the server's 400 is shown), and doesn't filter by `matches`.

**Rejected:** reading Transport or Api (copying another layer's code, the cause of the CHECK bug); the contract alone (it has no lifecycle or rules, and under Swagger 2.0 it couldn't describe sum types); TypeScript copies of `Ord` or the smart constructors (a second, untested implementation, where a wrong copy can make a valid value impossible to enter).

## Errors are facts, typed per use case (2026-10-01)

**Found:** one `ServiceError` for every use case made each type claim errors its use case can't produce (a read "may" answer `intakeRequestDoesNotMatchSlot`), so callers handled impossible cases and a new error widened every function silently. Outcomes were already exact per use case; errors weren't.

**Decided:**
- Each fact is its own type (`DoctorNotFound`, `IntakeRequestInWrongState`, `IntakeRequestDoesNotMatchSlot`, …). A use case's facts are exactly those its shape implies: `<Entity>NotFound` for each never-deleted entity it receives by id, `<Entity>InWrongState` if some case is reachable from none of its source cases, and the refusal of a Domain function over inputs the caller chose (`error-vs-outcome-types`, in `triage-service-codegen`).
- No fact: the value is returned directly. One fact: that type is the `Left`. Several: a `<Function>Error` with constructors `<Function><Fact>`.
- The wire tag is the fact type's name, so a fact has one tag in every answer, and an answer lists exactly its use case's outcomes and facts.
- A decode failure is not an error but a 500: Service's `decoded` raises Persistence's `DecodeError`.
- A write outcome carried inside another outcome is wrapped by a constructor named after its type (`MatchByPriorityOutcome = NoIntakeRequestMatched | MatchIntakeRequestToSlotOutcome MatchIntakeRequestToSlotOutcome`): it can also carry a fact found before the write, so a name like `MatchAttempted` would claim an attempt that didn't happen.
- A fact about an entity carries what identifies it: `<Entity>NotFound` and `<Entity>Consumed` the id (`AvailableSlotConsumed` was nullary), `<Entity>InWrongState` and `MovedOn` the value.
- Outcome names are derived from the Domain function a use case calls: `<DomainFunction>Outcome`, success as its past participle (`AvailableSlotAdded`, `IntakeRequestMatchedToSlot`), a decline over stored candidates `No<Subject><Verb>` (`NoIntakeRequestMatched`), a refusal of the caller's inputs `<Subject>DoesNot<Verb><Object>` (`IntakeRequestDoesNotMatchSlot`). A refusal caused by stored data is an outcome, never an error. Persistence's write outcomes follow `<TargetStage>ClaimOutcome` and `<Element>InsertOutcome = <Element>Inserted | <Element>Overlaps<Collection>`. These replaced names that had been chosen once and copied (`MatchOutcome`, `SlotCreated`, `PriorityMatchOutcome`, …): a clean-room run of the db and service skills reproduced every behaviour but could only match those names by having read this file.

**Rejected:** the uniform `ServiceError` (the types were untrue); one sum per use case with prefixed constructors carrying raw ids, the tag made by stripping the prefix from a string; type-level error sets (machinery a 2–3 doctor practice doesn't justify); listing reachable errors by reading function bodies (nothing would catch it going wrong); raising decode failures in Persistence (it would change the db layer and its tests for nothing).

## Callers read the sealed collection, not its elements (2026-10-06)

**Found:** the calendar page read `[DoctorCalendarEntry]` (`fetchDoctorCalendarEntriesOverlapping`), never replayed through `mkDoctorCalendar`, so a read that mixed two moments or got the interval arithmetic wrong would have shown overlapping entries without an error. Only slot creation went through the type. The list predates the type: `fetchCalendarView` (`6fca20f`, 2026-07-13) was "a display composition with no lifecycle or invariant", which stopped being true when `DoctorCalendar` was sealed (`5ea1396`, 2026-09-27) and nobody revisited the view. The generic-skill rewrite (`529dc21`) then wrote the leftover down as a rule, "a sealed value is opaque, so callers get its elements instead", although `sealed-value-decomposition` in the same skill says a missing accessor is a gap in `Domain.hs`, never to be worked around. `DoctorCalendar` had no accessor, so it looked opaque.

**Decided:**
- `Domain.hs` exports `doctorCalendarEntries :: DoctorCalendar -> [DoctorCalendarEntry]`. Sealing limits how a value is built, not how it is read (as with `RoutineWindow`'s accessors).
- One read: `fetchDoctorCalendarOverlapping :: Connection -> UTCTime -> UTCTime -> IO (Either DecodeError DoctorCalendar)`, every doctor's entries overlapping `[from, to)`, one snapshot, replayed through `mkDoctorCalendar`. The calendar page passes its range; slot creation passes the new slot's interval. Service returns `DoctorCalendar`; Transport takes it apart through the accessor, which returns entries in order of start (the UI never sorts).
- Which entries matter for a new slot (the same doctor's) is decided only by `Domain.hs` (`addAvailableSlot`), not repeated in SQL.
- What the replay checks on a read is our read code, not the data (the `EXCLUDE` already guarantees that): a refusal means the read is wrong. It proves no overlap, not completeness; a read that drops entries still passes, which `triage-db-test` covers.
- On the wire, `DoctorCalendar` is an object keyed by its accessor, `{"doctorCalendarEntries": [...]}`, by the existing key rule (`triage-api-codegen`), as `RoutineWindow` is. The contract and `types.ts` then name `DoctorCalendar`, so the claim reaches the UI.

**Rejected:** two reads, a per-doctor slice for slot creation and a range read for callers (option A): both replay the same way and differ only in a `doctor_id = ?` filter, which restates in SQL a rule `Domain.hs` already holds, and two reads can drift apart, as the view and the slice did. Cost of the one read: slot creation also loads other doctors' entries in a window one slot long, a handful of rows at 2–3 doctors. A bare list on the wire: it needs an exception to the key rule, drops the type's name at the contract, and can't gain a field without breaking clients.

## Open questions (from 2026-06-26 session — not yet resolved)

- `SlotEvent` vocabulary: does it live in Domain (as a description of what
  *can* happen to a Slot) or in Persistence (as a description of what *was*
  written)? Leaning Persistence since event sourcing itself was rejected,
  but not settled.
- Read-model freshness: is the read side always-consistent with the write
  side (single Postgres, no replication lag) or does the design need to
  tolerate staleness? Depends on deployment target, not yet chosen.
- Explicit command types (`BookSlot`, `CancelBooking`, ...) vs. direct
  function calls on Domain values — not yet decided whether commands earn
  their keep at this scale.
- OPEN, NOT YET RESOLVED: whether Patient needs a `name` field at all,
  vs. an opaque per-patient reference (e.g. phone number or an existing
  informal chart number), vs. eventually referencing an external patient
  registry that doesn't exist yet. Pending a conversation with the
  domain expert about whether there's already a stable per-patient
  identifier in informal use today. Domain.hs is unchanged for now — do
  not modify it as part of this task.
- `NoShow`'s `AppointmentParty` (added 2026-09-28): does it mean the party
  who didn't turn up (`absentParty = PatientParty` — the patient was absent), a
  different fact from `Cancelled`'s party (who cancelled)? And does a
  no-show need an optional note, as a cancellation has? Neither was ever
  decided: the CloseReason entry above justifies only `Cancelled`'s and
  `Completed`'s fields. Came up while giving every stored value a name in
  Domain.hs; the model treats the two parties as separate facts pending
  this answer. No time is proposed — a no-show happens at the
  appointment's own `start`.
- Recorded time vs. event time (added 2026-09-30): every timestamp
  (`createdAt`, `triagedAt`, `rejectedAt`, `withdrawnAt`, `staleAt`,
  `cancelledAt`) is the server's time when the action is recorded. Does
  the practice need the time an event actually happened — e.g. a patient
  who phoned on Monday to cancel, entered on Tuesday? If yes, it is one
  deliberate change to all such times together, not a per-field exception.

Do not resolve these speculatively in code. Validate with the domain expert
first, per the workflow discipline in CLAUDE.md.
