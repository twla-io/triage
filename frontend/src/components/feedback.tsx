import type { ReactNode } from 'react'
import { Alert, Loader, Text } from '@mantine/core'
import type { UseQueryResult } from '@tanstack/react-query'
import { ApiError } from '../api/client'

// A failure (non-200 status, network) is red: its status and body, or the error's message.
export function ErrorBanner({ error }: { error: Error }) {
  return (
    <Alert color="red" variant="light">
      {error instanceof ApiError ? (
        <>
          <Text size="sm" fw={600}>
            {error.status}
          </Text>
          <Text size="sm" style={{ whiteSpace: 'pre-wrap' }}>
            {error.body}
          </Text>
        </>
      ) : (
        <Text size="sm">{error.message}</Text>
      )}
    </Alert>
  )
}

// A non-success answer, or a warning a decision requires, is yellow.
export function Notice({ children }: { children: ReactNode }) {
  return (
    <Alert color="yellow" variant="light">
      <Text size="sm">{children}</Text>
    </Alert>
  )
}

export function QueryView<A>({ query, children }: { query: UseQueryResult<A>; children: (answer: A) => ReactNode }) {
  if (query.isPending) return <Loader size="sm" />
  if (query.isError) return <ErrorBanner error={query.error} />
  return <>{children(query.data)}</>
}
