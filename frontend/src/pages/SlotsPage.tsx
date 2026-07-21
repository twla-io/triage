import { Alert, Button, Group, Select, Stack, Title } from '@mantine/core'
import { DateTimePicker } from '@mantine/dates'
import { useState } from 'react'

import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices, DURATION_OPTIONS, type DurationType } from '../api/queries/services'
import { useCreateSlot } from '../api/queries/slots'
import { ApiError } from '../api/client'

export function SlotsPage() {
  const { data: doctors } = useDoctors()
  const { data: services } = useHealthcareServices()
  const createSlot = useCreateSlot()

  const [doctorId, setDoctorId] = useState<string | null>(null)
  const [healthcareServiceId, setHealthcareServiceId] = useState<string | null>(null)
  const [start, setStart] = useState<Date | null>(null)
  const [duration, setDuration] = useState<DurationType>('halfAnHour')

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault()
    if (!doctorId || !healthcareServiceId || !start) return
    createSlot.mutate({
      doctorId,
      healthcareServiceId,
      start: start.toISOString(),
      duration,
    })
  }

  return (
    <Stack gap="lg" maw={480}>
      <Title order={2}>Create Slot</Title>
      <form onSubmit={handleSubmit}>
        <Stack>
          <Select
            label="Doctor"
            placeholder="Choose a doctor"
            data={(doctors ?? []).map((d) => ({ value: d.id, label: d.name }))}
            value={doctorId}
            onChange={setDoctorId}
            required
          />
          <Select
            label="Healthcare service"
            placeholder="Choose a service"
            data={(services ?? []).map((s) => ({ value: s.id, label: s.name }))}
            value={healthcareServiceId}
            onChange={setHealthcareServiceId}
            required
          />
          <DateTimePicker label="Start" placeholder="Pick date and time" value={start} onChange={setStart} required />
          <Select
            label="Duration"
            data={DURATION_OPTIONS.map((d) => ({ value: d.value, label: d.label }))}
            value={duration}
            onChange={(value) => value && setDuration(value as DurationType)}
            allowDeselect={false}
          />
          <Group>
            <Button type="submit" loading={createSlot.isPending}>
              Create slot
            </Button>
          </Group>
        </Stack>
      </form>

      {createSlot.data?.outcome === 'slotCreated' && <Alert color="green">Slot created.</Alert>}
      {createSlot.data?.outcome === 'slotConflict' && (
        <Alert color="yellow">Conflict — this doctor already has a slot overlapping that time.</Alert>
      )}
      {createSlot.error && (
        <Alert color="red">{createSlot.error instanceof ApiError ? createSlot.error.message : String(createSlot.error)}</Alert>
      )}
    </Stack>
  )
}
