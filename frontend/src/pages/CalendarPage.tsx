import { Alert, Badge, Group, Loader, Paper, Select, Stack, Text, Title } from '@mantine/core'
import dayjs from 'dayjs'
import { useMemo, useState } from 'react'

import { useCalendar, type CalendarEntryDTO } from '../api/queries/calendar'
import { useDoctors } from '../api/queries/doctors'
import { ApiError } from '../api/client'

const RANGE_DAYS = 14

function entryLabel(entry: CalendarEntryDTO): string {
  return entry.type === 'appointment' ? 'Appointment' : 'Available'
}

function entryColor(entry: CalendarEntryDTO): string {
  return entry.type === 'appointment' ? 'blue' : 'green'
}

export function CalendarPage() {
  const [doctorId, setDoctorId] = useState<string | null>(null)
  const { data: doctors } = useDoctors()

  const range = useMemo(() => {
    const start = dayjs().startOf('day')
    const end = start.add(RANGE_DAYS, 'day')
    return { start: start.toISOString(), end: end.toISOString(), doctorId: doctorId ?? undefined }
  }, [doctorId])

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
        <Select
          placeholder="All doctors"
          data={(doctors ?? []).map((d) => ({ value: d.id, label: d.name }))}
          value={doctorId}
          onChange={setDoctorId}
          clearable
          w={220}
        />
      </Group>
      <Text size="sm" c="dimmed">
        {dayjs(range.start).format('MMM D')} – {dayjs(range.end).format('MMM D')}
      </Text>

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
                    <Text size="sm" c="dimmed">
                      {entry.narrative}
                    </Text>
                  )}
                </Group>
              </Paper>
            ))}
        </Stack>
      ))}
    </Stack>
  )
}
