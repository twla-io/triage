import { ActionIcon, Group, Text } from '@mantine/core'
import { IconChevronLeft, IconChevronRight } from '@tabler/icons-react'
import { shiftWeek, type Week } from '../api/range'

function day(date: Date): string {
  return date.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })
}

export function WeekRange({ week, onChange }: { week: Week; onChange: (week: Week) => void }) {
  const sunday = new Date(week.to)
  sunday.setDate(sunday.getDate() - 1)
  return (
    <Group gap="xs">
      <ActionIcon variant="default" onClick={() => onChange(shiftWeek(week, -1))}>
        <IconChevronLeft size={16} />
      </ActionIcon>
      <Text size="sm">
        {day(week.from)} – {day(sunday)}
      </Text>
      <ActionIcon variant="default" onClick={() => onChange(shiftWeek(week, 1))}>
        <IconChevronRight size={16} />
      </ActionIcon>
    </Group>
  )
}
