import type { ReactNode } from 'react'
import { Badge, Group, Title } from '@mantine/core'
import { humanize } from './labels'

export function PageHeader({ entity, children }: { entity: string; children?: ReactNode }) {
  return (
    <Group justify="space-between" mb="md">
      <Title order={2}>{humanize(entity)}</Title>
      <Group gap="xs">{children}</Group>
    </Group>
  )
}

// A section per case or read: its name humanized and how many it holds.
export function SectionHeader({ name, count, children }: { name: string; count?: number; children?: ReactNode }) {
  return (
    <Group justify="space-between">
      <Group gap="xs">
        <Title order={4}>{humanize(name)}</Title>
        {count !== undefined && (
          <Badge color="gray" variant="light" circle>
            {count}
          </Badge>
        )}
      </Group>
      {children}
    </Group>
  )
}
