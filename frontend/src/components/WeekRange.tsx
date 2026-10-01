import { useMemo, useState } from 'react'
import { ActionIcon, Group, Text } from '@mantine/core'
import { IconChevronLeft, IconChevronRight } from '@tabler/icons-react'
import dayjs, { type Dayjs } from 'dayjs'
import type { TimeRange } from '../api/queries/mutation'
import { toUtcTime } from './labels'

// one-range-rule: every range opens on the current week, Monday to Sunday,
// and moves by a week.
function mondayOf(d: Dayjs): Dayjs {
  return d.subtract((d.day() + 6) % 7, 'day').startOf('day')
}

export interface WeekRange {
  monday: Dayjs
  range: TimeRange
  previous: () => void
  next: () => void
}

export function useWeekRange(): WeekRange {
  const [monday, setMonday] = useState(() => mondayOf(dayjs()))
  const range = useMemo(
    () => ({ from: toUtcTime(monday.toDate()), to: toUtcTime(monday.add(7, 'day').toDate()) }),
    [monday],
  )
  return {
    monday,
    range,
    previous: () => setMonday((m) => m.subtract(7, 'day')),
    next: () => setMonday((m) => m.add(7, 'day')),
  }
}

export function WeekRangePicker({ week }: { week: WeekRange }) {
  return (
    <Group gap="xs">
      <ActionIcon variant="default" aria-label="previous" onClick={week.previous}>
        <IconChevronLeft size={16} />
      </ActionIcon>
      <Text size="sm">
        {week.monday.format('YYYY-MM-DD')} – {week.monday.add(6, 'day').format('YYYY-MM-DD')}
      </Text>
      <ActionIcon variant="default" aria-label="next" onClick={week.next}>
        <IconChevronRight size={16} />
      </ActionIcon>
    </Group>
  )
}
