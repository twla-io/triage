import type { ReactNode } from 'react'
import { Stack } from '@mantine/core'

/** A list in the order its read returned it; the UI never sorts. */
export function RecordList<T>({ items, keyOf, render }: { items: T[]; keyOf: (item: T) => string; render: (item: T) => ReactNode }) {
  return (
    <Stack gap="xs">
      {items.map((item) => (
        <div key={keyOf(item)}>{render(item)}</div>
      ))}
    </Stack>
  )
}
