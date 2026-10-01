import { useState } from 'react'
import { Button, Stack, TextInput } from '@mantine/core'
import { useCreateAvailableSlot } from '../api/queries/availableSlots'
import { useDoctorCalendar } from '../api/queries/doctorCalendar'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import type { DoctorId, HealthcareServiceId } from '../api/wire'
import { DoctorSelect, HealthcareServiceSelect, TimeField } from '../components/controls'
import { DoctorCalendarEntryCard } from '../components/DoctorCalendarEntryView'
import { FormModal } from '../components/FormModal'
import { humanize, toUtcTime } from '../components/labels'
import { okDetail, ReadAnswer } from '../components/outcome'
import { PageHeader, SectionHeader } from '../components/PageHeader'
import { useWeekRange, WeekRangePicker } from '../components/WeekRange'

// AvailableSlot has no collection read of its own: its elements are shown
// through the doctor calendar, so its create action lives here.
function CreateAvailableSlotForm({ onClose }: { onClose: () => void }) {
  const create = useCreateAvailableSlot()
  const services = okDetail(useHealthcareServices().data)
  const [doctorId, setDoctorId] = useState<DoctorId | null>(null)
  const [healthcareServiceId, setHealthcareServiceId] = useState<HealthcareServiceId | null>(null)
  const [start, setStart] = useState<Date | null>(null)

  // docs/decisions.md: the slot's duration comes from its service; the UI
  // shows it read-only.
  const service = services?.find((s) => s.id === healthcareServiceId)

  return (
    <FormModal
      useCase="createAvailableSlot"
      onClose={onClose}
      submit={
        doctorId === null || healthcareServiceId === null || start === null
          ? null
          : () => create.mutateAsync({ doctorId, healthcareServiceId, start: toUtcTime(start) })
      }
    >
      <DoctorSelect name="doctorId" value={doctorId} onChange={setDoctorId} />
      <HealthcareServiceSelect name="healthcareServiceId" value={healthcareServiceId} onChange={setHealthcareServiceId} />
      <TextInput label={humanize('duration')} readOnly value={service ? humanize(service.duration.type) : ''} />
      <TimeField name="start" value={start} onChange={setStart} />
    </FormModal>
  )
}

export function DoctorCalendarPage() {
  const week = useWeekRange()
  const calendar = useDoctorCalendar(week.range)
  const [creating, setCreating] = useState(false)
  return (
    <Stack>
      <PageHeader entity="doctorCalendar">
        <Button onClick={() => setCreating(true)}>{humanize('createAvailableSlot')}</Button>
      </PageHeader>
      {creating && <CreateAvailableSlotForm onClose={() => setCreating(false)} />}
      <SectionHeader name="doctorCalendarEntry" count={okDetail(calendar.data)?.length}>
        <WeekRangePicker week={week} />
      </SectionHeader>
      <ReadAnswer query={calendar}>
        {(entries) => (
          <Stack gap="xs">
            {entries.map((e) => (
              <DoctorCalendarEntryCard key={`${e.type}-${e.id}`} entry={e} />
            ))}
          </Stack>
        )}
      </ReadAnswer>
    </Stack>
  )
}
