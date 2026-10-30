import type { ReactNode } from 'react'
import { Group, ScrollArea, Stack, Table, Text, Title } from '@mantine/core'
import type { Row } from './values'

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

// A list of records as a table: one row per record, one column per field, headed by the
// fields' humanized names. A record's actions go in the last column.
export function RecordTable<T>({
  records,
  rowKey,
  rows,
  actions,
}: {
  records: T[]
  rowKey: (record: T) => string
  rows: (record: T) => Row[]
  actions?: (record: T) => ReactNode[]
}) {
  if (records.length === 0) return <Text size="sm" c="dimmed">Nothing here.</Text>
  return (
    <ScrollArea type="auto">
      <Table withTableBorder highlightOnHover verticalSpacing="xs">
        <Table.Thead>
          <Table.Tr>
            {rows(records[0]).map((row) => (
              <Table.Th key={row.key}>{row.label}</Table.Th>
            ))}
            {actions && <Table.Th />}
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {records.map((record) => (
            <Table.Tr key={rowKey(record)}>
              {rows(record).map((row) => (
                <Table.Td key={row.key}>{row.node}</Table.Td>
              ))}
              {actions && (
                <Table.Td>
                  <Group gap="xs" wrap="nowrap">
                    {actions(record)}
                  </Group>
                </Table.Td>
              )}
            </Table.Tr>
          ))}
        </Table.Tbody>
      </Table>
    </ScrollArea>
  )
}
