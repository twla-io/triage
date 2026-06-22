# State-to-Affordance Mapping

Derived directly from `Domain.hs`'s Commands. If a domain function isn't listed as valid for a state below, no UI control should offer it for that state.

## `Slot`

| State | Valid actions | Domain function | Notes |
|---|---|---|---|
| `Pending` | none (system-internal) | — | A `PendingSlot` is mid-protocol, waiting for `checkWaitlist`. No user-facing action applies; if shown at all (e.g. a doctor's internal dashboard), show as "processing" / "awaiting waitlist check," not as something to act on. |
| `Offered` | Accept, Decline | `bookSlot` (via the offered entry accepting), `declineOffer` | These actions belong to the *waitlist entry's* perspective (the patient who received the offer), not a general slot view. A doctor-facing slot view should show "Offered to [patient], awaiting response," not Accept/Decline controls. |
| `Available` | Book | `bookSlot` | The only valid action. Never show Cancel/Decline for an `Available` slot — there's nothing to cancel yet. |
| `Booked` | (none at the Slot level) | — | Actions on a booked slot are actually actions on its `Appointment` — see below. A slot-level view should link to the appointment, not duplicate its actions. |

## `Appointment`

| State | Valid actions | Domain function | Notes |
|---|---|---|---|
| `Open` | Cancel, Reschedule, Complete, Mark No-Show | `CloseReason`'s constructors via the application-layer command that closes the appointment | All four are valid simultaneously while `Open` — which ones a *specific* user role can trigger (patient vs. doctor vs. staff) is a permissions concern outside `Domain.hs`, not a state concern. |
| `Closed` | none — read-only | — | Display the `CloseReason` (which constructor, and which `AppointmentParty` initiated it if applicable) as plain text. No action controls; a closed appointment doesn't reopen. |

## `WaitlistEntry`

| Constructor | Fields shown | Doctor-preference control? | DueAt control? |
|---|---|---|---|
| `EmergencyEntry` | id, patient, service, status, createdAt | **No** — field doesn't exist, don't render even disabled | **No** — Emergency entries don't carry a DueAt |
| `UrgentEntry` | + optional doctor preference | Yes, optional (nullable selector) | No — Urgent entries don't carry a DueAt |
| `RoutineEntry` | + optional doctor preference + DueAt | Yes, optional (nullable selector) | Yes — render as the mode-choice described in `SKILL.md`, not two raw date fields |

Actions on a `WaitlistEntry` itself (e.g. "remove from waitlist," "edit preferences") aren't yet modeled as domain transitions in `Domain.hs` — if the UI needs these, that's a sign the domain model may need a corresponding function added first (e.g. a `withdrawFromWaitlist` transition), rather than the UI silently allowing an edit the domain model has no representation for.
