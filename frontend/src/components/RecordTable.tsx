import type { ReactNode } from 'react'
import { Paper, Table, Text } from '@mantine/core'
import { humanize } from './labels'

// A list of records, one row each, columns labelled by field names humanized.
// Rows stay in the order the read returned them.
export function RecordTable<R extends { id: string }>({
  rows,
  columns,
}: {
  rows: R[]
  columns: [name: string, render: (row: R) => ReactNode][]
}) {
  return (
    <Paper withBorder>
      <Table>
        <Table.Thead>
          <Table.Tr>
            {columns.map(([name]) => (
              <Table.Th key={name}>
                <Text size="sm" c="dimmed">
                  {humanize(name)}
                </Text>
              </Table.Th>
            ))}
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {rows.map((row) => (
            <Table.Tr key={row.id}>
              {columns.map(([name, render]) => (
                <Table.Td key={name}>{render(row)}</Table.Td>
              ))}
            </Table.Tr>
          ))}
        </Table.Tbody>
      </Table>
    </Paper>
  )
}
