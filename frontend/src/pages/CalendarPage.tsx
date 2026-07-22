import {
  ActionIcon,
  Alert,
  Anchor,
  Badge,
  Button,
  Divider,
  Group,
  Loader,
  Modal,
  Paper,
  Select,
  Stack,
  Text,
  Title,
} from '@mantine/core'
import { IconChevronLeft, IconChevronRight } from '@tabler/icons-react'
import { DateTimePicker } from '@mantine/dates'
import { useDisclosure } from '@mantine/hooks'
import dayjs from 'dayjs'
import { useMemo, useState } from 'react'

import { useCalendar, type CalendarEntryDTO } from '../api/queries/calendar'
import { useDoctors } from '../api/queries/doctors'
import { usePatients } from '../api/queries/patients'
import { useHealthcareServices, DURATION_OPTIONS, type DurationType } from '../api/queries/services'
import { useCreateSlot } from '../api/queries/slots'
import { ApiError } from '../api/client'
import { formatDue, PriorityBadge } from '../components/PriorityBadge'

const RANGE_DAYS = 14

function NewSlotModal({ opened, onClose }: { opened: boolean; onClose: () => void }) {
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
    <Modal opened={opened} onClose={onClose} title="New slot">
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
          <Group justify="flex-end">
            <Button type="submit" loading={createSlot.isPending}>
              Create slot
            </Button>
          </Group>
        </Stack>
      </form>

      {createSlot.data?.outcome === 'slotCreated' && <Alert color="green" mt="md">Slot created.</Alert>}
      {createSlot.data?.outcome === 'slotConflict' && (
        <Alert color="yellow" mt="md">Conflict — this doctor already has a slot overlapping that time.</Alert>
      )}
      {createSlot.error && (
        <Alert color="red" mt="md">
          {createSlot.error instanceof ApiError ? createSlot.error.message : String(createSlot.error)}
        </Alert>
      )}
    </Modal>
  )
}

function entryLabel(entry: CalendarEntryDTO): string {
  return entry.type === 'appointment' ? 'Appointment' : 'Available'
}

function entryColor(entry: CalendarEntryDTO): string {
  return entry.type === 'appointment' ? 'blue' : 'green'
}

function AppointmentDetailsModal({ entry, onClose }: { entry: CalendarEntryDTO | null; onClose: () => void }) {
  const { data: doctors } = useDoctors()
  const { data: services } = useHealthcareServices()
  const { data: patients } = usePatients()

  const doctorName = doctors?.find((d) => d.id === entry?.doctorId)?.name ?? entry?.doctorId
  const serviceName = services?.find((s) => s.id === entry?.healthcareServiceId)?.name ?? entry?.healthcareServiceId
  const patientName = patients?.find((p) => p.id === entry?.patientId)?.name ?? entry?.patientId

  return (
    <Modal opened={entry !== null} onClose={onClose} title="Appointment details">
      {entry && (
        <Stack gap="sm">
          <Group>
            <PriorityBadge priority={entry.priority} />
            <Text fw={600}>{patientName}</Text>
          </Group>
          <Text size="sm" c="dimmed">
            {formatDue(entry.priority)}
          </Text>
          <Text size="sm">{entry.narrative}</Text>
          <Divider />
          <Text size="sm">
            <Text span fw={500}>
              When:
            </Text>{' '}
            {dayjs(entry.start).format('MMM D, YYYY h:mm A')} ({entry.duration.type})
          </Text>
          <Text size="sm">
            <Text span fw={500}>
              Doctor:
            </Text>{' '}
            {doctorName}
            {entry.doctorRequirement?.type === 'specificDoctor' ? ' (specifically requested)' : ' (any doctor requested)'}
          </Text>
          <Text size="sm">
            <Text span fw={500}>
              Service:
            </Text>{' '}
            {serviceName}
          </Text>
          <Divider />
          <Text size="xs" c="dimmed">
            Submitted {entry.createdAt ? dayjs(entry.createdAt).format('MMM D, YYYY') : '—'} · Triaged{' '}
            {entry.triagedAt ? dayjs(entry.triagedAt).format('MMM D, YYYY') : '—'}
          </Text>
        </Stack>
      )}
    </Modal>
  )
}

export function CalendarPage() {
  const [doctorId, setDoctorId] = useState<string | null>(null)
  const { data: doctors } = useDoctors()
  const [modalOpened, { open: openModal, close: closeModal }] = useDisclosure(false)
  const [pageOffset, setPageOffset] = useState(0)
  const [detailsEntry, setDetailsEntry] = useState<CalendarEntryDTO | null>(null)

  const range = useMemo(() => {
    const start = dayjs().startOf('day').add(pageOffset * RANGE_DAYS, 'day')
    const end = start.add(RANGE_DAYS, 'day')
    return { start: start.toISOString(), end: end.toISOString(), doctorId: doctorId ?? undefined }
  }, [doctorId, pageOffset])

  const { data: entries, isLoading, error } = useCalendar(range)

  const grouped = useMemo(() => {
    const byDay = new Map<string, CalendarEntryDTO[]>()
    for (const entry of entries ?? []) {
      const day = dayjs(entry.start).format('YYYY-MM-DD')
      const list = byDay.get(day) ?? []
      list.push(entry)
      byDay.set(day, list)
    }
    return [...byDay.entries()].sort(([a], [b]) => a.localeCompare(b))
  }, [entries])

  return (
    <Stack gap="lg">
      <Group justify="space-between">
        <Title order={2}>Calendar</Title>
        <Group>
          <Select
            placeholder="All doctors"
            data={(doctors ?? []).map((d) => ({ value: d.id, label: d.name }))}
            value={doctorId}
            onChange={setDoctorId}
            clearable
            w={220}
          />
          <Button onClick={openModal}>New slot</Button>
        </Group>
      </Group>
      <NewSlotModal opened={modalOpened} onClose={closeModal} />
      <AppointmentDetailsModal entry={detailsEntry} onClose={() => setDetailsEntry(null)} />
      <Group gap="xs">
        <ActionIcon
          variant="default"
          disabled={pageOffset === 0}
          onClick={() => setPageOffset((offset) => Math.max(0, offset - 1))}
          aria-label="Previous"
        >
          <IconChevronLeft size={16} />
        </ActionIcon>
        <Text size="sm" c="dimmed">
          {dayjs(range.start).format('MMM D')} – {dayjs(range.end).format('MMM D')}
        </Text>
        <ActionIcon variant="default" onClick={() => setPageOffset((offset) => offset + 1)} aria-label="Next">
          <IconChevronRight size={16} />
        </ActionIcon>
      </Group>

      {isLoading && <Loader size="sm" />}
      {error && <Alert color="red">{error instanceof ApiError ? error.message : String(error)}</Alert>}
      {!isLoading && grouped.length === 0 && <Text c="dimmed">Nothing in this range.</Text>}

      {grouped.map(([day, dayEntries]) => (
        <Stack key={day} gap="xs">
          <Text fw={600}>{dayjs(day).format('dddd, MMM D')}</Text>
          {dayEntries
            .sort((a, b) => a.start.localeCompare(b.start))
            .map((entry) => (
              <Paper key={entry.id} withBorder p="sm">
                <Group justify="space-between">
                  <Group>
                    <Badge color={entryColor(entry)}>{entryLabel(entry)}</Badge>
                    <Text size="sm">{dayjs(entry.start).format('h:mm A')}</Text>
                    <Text size="sm" c="dimmed">
                      {entry.duration.type}
                    </Text>
                  </Group>
                  {entry.type === 'appointment' && (
                    <Group gap="sm">
                      <Text size="sm" c="dimmed">
                        {entry.narrative}
                      </Text>
                      <Anchor size="sm" onClick={() => setDetailsEntry(entry)}>
                        See more
                      </Anchor>
                    </Group>
                  )}
                </Group>
              </Paper>
            ))}
        </Stack>
      ))}
    </Stack>
  )
}
