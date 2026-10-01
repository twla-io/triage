import type { Schemas } from '../api/client'
import { useMatchAvailableSlotByPriority } from '../api/queries/availableSlots'
import { ActionButton, ActionForm } from './actions'
import { humanize } from './humanize'
import { IntakeRequestActions } from './intakeRequestActions'

/**
 * A calendar entry's actions, by case. A Slot's is matching it by priority;
 * an Appointment is an appointed intake request, so it gets the intake
 * request's own mapping.
 */
export function DoctorCalendarEntryActions({ entry }: { entry: Schemas['DoctorCalendarEntry'] }) {
  switch (entry.type) {
    case 'slot':
      return (
        <ActionButton label={humanize('matchByPriority')}>
          {(close) => <MatchByPriorityForm slotId={entry.id} onDone={close} />}
        </ActionButton>
      )
    case 'appointment':
      return <IntakeRequestActions request={{ ...entry, type: 'appointed' }} />
  }
}

function MatchByPriorityForm({ slotId, onDone }: { slotId: Schemas['SlotId']; onDone: () => void }) {
  const mutation = useMatchAvailableSlotByPriority()
  return (
    <ActionForm
      label={humanize('matchByPriority')}
      entity="availableSlot"
      mutation={mutation}
      variables={slotId}
      isSuccess={(a) => a.outcome === 'matchIntakeRequestToSlotOutcome' && a.detail.outcome === 'intakeRequestMatchedToSlot'}
      onDone={onDone}
    />
  )
}
