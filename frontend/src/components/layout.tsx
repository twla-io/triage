import type { ReactNode } from 'react'
import { Group, Paper, Stack, Title } from '@mantine/core'

export function Page({ title, actions, children }: { title: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <Stack>
      <Group justify="space-between">
        <Title order={2}>{title}</Title>
        <Group gap="xs">{actions}</Group>
      </Group>
      {children}
    </Stack>
  )
}

export function Section({ title, controls, children }: { title: string; controls?: ReactNode; children: ReactNode }) {
  return (
    <Stack gap="xs">
      <Group justify="space-between">
        <Title order={4}>{title}</Title>
        {controls}
      </Group>
      {children}
    </Stack>
  )
}

export function RecordList({ children }: { children: ReactNode }) {
  return <Stack gap="xs">{children}</Stack>
}

export function RecordCard({ header, actions, children }: { header?: ReactNode; actions?: ReactNode; children: ReactNode }) {
  return (
    <Paper withBorder p="sm">
      <Stack gap="xs">
        {(header || actions) && (
          <Group justify="space-between">
            <Group gap="xs">{header}</Group>
            <Group gap="xs">{actions}</Group>
          </Group>
        )}
        {children}
      </Stack>
    </Paper>
  )
}
