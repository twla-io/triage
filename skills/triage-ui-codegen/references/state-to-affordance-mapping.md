# State-to-Affordance Mapping

Derived directly from `Domain.hs`'s Commands. If a domain function isn't listed as valid for a state below, no UI control should offer it for that state.

## `Slot`

| State | Valid actions | Domain function | Notes |
|---|---|---|---|
| `Pending` | none (system-internal) | — | A `PendingSlot` is mid-protocol, waiting for `checkWaitlist`. No user-facing action applies; if shown at all (e.g. a doctor's internal dashboard), show as "processing" / "awaiting waitlist check," not as something to act on. |
| `Offered` | Accept, Decline | `bookSlot` (via the offered request accepting), `declineOffer` | These actions belong to the *appointment request's* perspective (the patient who received the offer), not a general slot view. A doctor-facing slot view should show "Offered to [patient], awaiting response," not Accept/Decline controls. |
| `Available` | Book | `bookSlot` | The only valid action. Never show Cancel/Decline for an `Available` slot — there's nothing to cancel yet. |
| `Booked` | (none at the Slot level) | — | Actions on a booked slot are actually actions on its `Appointment` — see below. A slot-level view should link to the appointment, not duplicate its actions. |

## `Appointment`

| State | Valid actions | Domain function | Notes |
|---|---|---|---|
| `Open` | Cancel, Reschedule, Complete, Mark No-Show | `CloseReason`'s constructors via the application-layer command that closes the appointment | All four are valid simultaneously while `Open` — which ones a *specific* user role can trigger (patient vs. doctor vs. staff) is a permissions concern outside `Domain.hs`, not a state concern. |
| `Closed` | none — read-only | — | Display the `CloseReason` (which constructor, and which `AppointmentParty` initiated it if applicable) as plain text. No action controls; a closed appointment doesn't reopen. |

## `AppointmentRequest`

The waitlist registration itself — the thing a patient submits when they need an appointment. Three constructors, one per urgency tier:

| Constructor | Fields shown | Doctor-preference control? | DueAt control? |
|---|---|---|---|
| `EmergencyRequest` | id, patient, service, createdAt | **No** — field doesn't exist, don't render even disabled | **No** — field doesn't exist |
| `UrgentRequest` | id, patient, service, createdAt | **No** — field doesn't exist, don't render even disabled | **No** — field doesn't exist |
| `RoutineRequest` | + optional doctor preference + DueAt | Yes, optional (nullable selector) | Yes — render as the mode-choice described in `SKILL.md`, not two raw date fields |

`EmergencyRequest` and `UrgentRequest` are structurally identical — both carry only `AppointmentRequestDetails`, no doctor preference, no due date. Doctor preference and `DueAt` are exclusive to `RoutineRequest`: choosing a specific doctor means accepting a longer wait if that doctor is busy, which is only a safe tradeoff for a patient with no urgent time pressure. **Provisional** — if doctor preference for Urgent patients was an actual validated requirement, confirm with the doctor before building UI around its removal.

Actions on an `AppointmentRequest` itself (e.g. "remove from waitlist," "edit preferences") aren't yet modeled as domain transitions in `Domain.hs` — if the UI needs these, that's a sign the domain model may need a corresponding function added first (e.g. a `withdrawRequest` transition), rather than the UI silently allowing an edit the domain model has no representation for.

## `WaitlistRecord`

A separate type from `AppointmentRequest` — not a rename of it. `WaitlistRecord` wraps a request together with its current offer state, for views that need to show the whole waitlist at once (both requests still waiting and ones currently holding an offer):

```haskell
data WaitlistRecord = Waiting AppointmentRequest | HasOffer AppointmentRequestWithOffer
```

Note that `checkWaitlist` deliberately takes `[AppointmentRequest]` (the waiting-only list), not `[WaitlistRecord]` — so `matches` needs no "is this one currently waiting?" check. `WaitlistRecord` is for contexts that need both halves, such as a doctor's dashboard or a patient's "my requests" view.

| `WaitlistRecord` case | Valid actions | Domain function | Notes |
|---|---|---|---|
| `Waiting` | none directly — eligible to be matched by `checkWaitlist` | — | Nothing for a user to act on; this record is simply on the list. |
| `HasOffer` | Accept, Decline | `bookSlot` (on accept), `declineOffer` (on decline) | Show "Offered [slot], awaiting response" with Accept/Decline controls — this is the one place a patient or staff member acts directly on a waitlist record. |
