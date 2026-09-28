# State-to-Affordance Mapping

Derived from `Domain.hs`'s transitions and the routes in `Api.hs`. If a transition isn't listed as valid for a state below, no UI control should offer it for that state. Re-derive this table whenever `Domain.hs` or the routes change; don't edit it by hand to match a screen.

## `IntakeRequest`

| State | Valid actions | `Domain.hs` transition | Route | Notes |
|---|---|---|---|---|
| `Submitted` | Accept (triage) | `acceptIntakeRequest` | `POST /intake-requests/:id/accept` | Triage assigns the healthcare service, the priority and the doctor requirement (default any doctor; the patient's preference, if any, is in the narrative); the UI collects all three. |
| | Reject | `Rejected` (direct construction) | `POST /intake-requests/:id/reject` | Requires a reason. |
| | Withdraw | `WithdrawnFromSubmitted` | **no route yet** | Defined in `Domain.hs`, not yet built. Don't offer it until a route exists. |
| `Accepted` | Match to a slot | `matchIntakeRequestToSlot` | `POST /intake-requests/:id/match` with `{slotId}` | Send only the slot's id; the server matches against the stored slot. Offer only slots the request can match (service, doctor requirement, deadline) — the server rejects the rest as `requestIneligible`. |
| | Mark stale | `Stale` (direct construction) | `POST /intake-requests/:id/mark-stale` | Staff-initiated only; never automatic. |
| | Withdraw | `WithdrawnFromAccepted` | **no route yet** | As above. |
| `Appointed` | Close: completed / cancelled / no-show | `Closed` with a `CloseReason` | `POST /intake-requests/:id/close` | Cancelled and no-show also record which party (doctor/patient); cancelled takes an optional note. The server supplies timestamps. Displacing or rescheduling a patient is a cancel followed by a new request (submit, accept, match); there is no "back to the waitlist" action. The vacated time does **not** become a slot again unless someone creates one. |
| `Rejected` | none — read-only | — | — | Show the reason and time. |
| `Withdrawn` | none — read-only | — | — | Show when, and the note if any. |
| `Stale` | none — read-only | — | — | |
| `Closed` | none — read-only | — | — | Show the `CloseReason` and, where present, which party. A closed request never reopens; a patient who needs to be seen again gets a new request. |

Every action above can also come back as `requestChangedSinceRead` (the request changed since the screen loaded) or as a precondition answer such as `requestNotSubmittedAnymore`. Show those; see `SKILL.md`.

## `AvailableSlot`

| Action | Route | Notes |
|---|---|---|
| Create | `POST /slots` with `{doctorId, healthcareServiceId, start}` | Duration comes from the healthcare service; show it read-only, never as an input. `slotConflict` means the doctor already has something overlapping. |

A slot has no other actions: it's either available or gone (absorbed into the appointment that matched it). There's no cancel, free or edit.
