import { useState } from 'react'
import { ActionIcon, Group, Text } from '@mantine/core'
import { IconChevronLeft, IconChevronRight } from '@tabler/icons-react'
import dayjs, { type Dayjs } from 'dayjs'
import type { Range } from '../api/range'
import { wireTime } from './time'

function mondayOf(day: Dayjs): Dayjs {
  const start = day.startOf('day')
  return start.subtract((start.day() + 6) % 7, 'day')
}

/**
 * A week, Monday to Sunday, opening on the current one; the read gets the
 * half-open range from Monday 00:00 to next Monday 00:00, local time.
 */
export function useWeek() {
  const [monday, setMonday] = useState(() => mondayOf(dayjs()))
  const range: Range = { from: wireTime(monday), to: wireTime(monday.add(1, 'week')) }
  return {
    monday,
    range,
    previous: () => setMonday((m) => m.subtract(1, 'week')),
    next: () => setMonday((m) => m.add(1, 'week')),
  }
}

export type Week = ReturnType<typeof useWeek>

export function WeekRange({ week }: { week: Week }) {
  return (
    <Group gap="xs" wrap="nowrap">
      <ActionIcon variant="subtle" onClick={week.previous}>
        <IconChevronLeft size={18} />
      </ActionIcon>
      <Text size="sm">
        {week.monday.format('YYYY-MM-DD')} – {week.monday.add(6, 'day').format('YYYY-MM-DD')}
      </Text>
      <ActionIcon variant="subtle" onClick={week.next}>
        <IconChevronRight size={18} />
      </ActionIcon>
    </Group>
  )
}
