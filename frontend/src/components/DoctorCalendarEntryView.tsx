import { Button, Group, Paper, Stack } from '@mantine/core'
import { useMatchAvailableSlotByPriority } from '../api/queries/availableSlots'
import type { AvailableSlotFields, DoctorCalendarEntry } from '../api/wire'
import { useImmediateAction } from './FormModal'
import { appointedFields, IntakeRequestActions } from './IntakeRequestView'
import { humanize } from './labels'
import {
  CaseBadge,
  DoctorName,
  DurationValue,
  Fields,
  HealthcareServiceName,
  IdValue,
  TimeValue,
  type Field,
} from './values'

function slotFields(s: AvailableSlotFields): Field[] {
  return [
    ['id', <IdValue id={s.id} />],
    ['doctorId', <DoctorName id={s.doctorId} />],
    ['healthcareServiceId', <HealthcareServiceName id={s.healthcareServiceId} />],
    ['start', <TimeValue time={s.start} />],
    ['duration', <DurationValue value={s.duration} />],
  ]
}

// A slot's one action: the mutation that starts from it.
function SlotActions({ slot }: { slot: AvailableSlotFields }) {
  const match = useMatchAvailableSlotByPriority()
  const immediate = useImmediateAction()
  return (
    <Stack gap="xs">
      <Group gap="xs">
        <Button
          size="xs"
          variant="default"
          loading={immediate.pending}
          onClick={() => void immediate.run(() => match.mutateAsync(slot.id))}
        >
          {humanize('matchAvailableSlotByPriority')}
        </Button>
      </Group>
      {immediate.feedback}
    </Stack>
  )
}

export function DoctorCalendarEntryCard({ entry }: { entry: DoctorCalendarEntry }) {
  switch (entry.type) {
    case 'slot':
      return (
        <Paper withBorder p="sm">
          <Stack gap="xs">
            <Group>
              <CaseBadge tag={entry.type} />
            </Group>
            <Fields fields={slotFields(entry)} />
            <SlotActions slot={entry} />
          </Stack>
        </Paper>
      )
    case 'appointment':
      // An appointment is an appointed intake request: its actions are that case's.
      return (
        <Paper withBorder p="sm">
          <Stack gap="xs">
            <Group>
              <CaseBadge tag={entry.type} />
            </Group>
            <Fields fields={appointedFields(entry)} />
            <IntakeRequestActions request={{ ...entry, type: 'appointed' }} />
          </Stack>
        </Paper>
      )
  }
}
