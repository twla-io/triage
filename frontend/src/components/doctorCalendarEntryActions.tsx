import type { ReactNode } from 'react'
import type { Schemas } from '../api/client'
import { ActionButton } from './actions'
import { MatchAvailableSlotByPriorityForm } from './entityForms'
import { actionLabel } from './humanize'
import { intakeRequestActions } from './intakeRequestActions'

const matchByPriority = actionLabel('MatchAvailableSlotByPriority', 'AvailableSlot')

// The appointment case is an intake request in its Appointed case: its actions are
// the intake request's own mapping.
export function asAppointedIntakeRequest(
  entry: Schemas['DoctorCalendarEntryAppointment'],
): Schemas['IntakeRequestAppointed'] {
  return { ...entry, type: 'appointed' }
}

export function doctorCalendarEntryActions(entry: Schemas['DoctorCalendarEntry']): ReactNode[] {
  switch (entry.type) {
    case 'slot':
      return [
        <ActionButton key={matchByPriority} label={matchByPriority}>
          {(done) => <MatchAvailableSlotByPriorityForm slotId={entry.id} label={matchByPriority} onDone={done} />}
        </ActionButton>,
      ]
    case 'appointment':
      return intakeRequestActions(asAppointedIntakeRequest(entry))
  }
}
