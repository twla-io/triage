import type { FormEvent, ReactNode } from 'react'
import { Button, Group, Loader, Modal, Stack, Title } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import type { UseMutationResult, UseQueryResult } from '@tanstack/react-query'
import type { AnyAnswer } from '../api/answers'
import { AnswerBanner, ErrorBanner } from './outcome'

/** An action: a button that opens its form, titled with the same word. */
export function ActionButton({
  label,
  variant = 'light',
  children,
}: {
  label: string
  variant?: 'light' | 'filled'
  children: (close: () => void) => ReactNode
}) {
  const [opened, { open, close }] = useDisclosure(false)
  return (
    <>
      <Button size="xs" variant={variant} onClick={open}>
        {label}
      </Button>
      <Modal opened={opened} onClose={close} title={label} size="lg">
        {opened && children(close)}
      </Modal>
    </>
  )
}

/**
 * A form's body: its controls, then the answer. The success tag closes the
 * form; any other answer stays shown inline; a failure is a red banner.
 * Submitting is possible only once every required value is given.
 */
export function ActionForm<V, A extends AnyAnswer>({
  label,
  entity,
  mutation,
  variables,
  isSuccess,
  onDone,
  children,
}: {
  label: string
  entity: string
  mutation: UseMutationResult<A, Error, V>
  variables: V | null
  isSuccess: (answer: A) => boolean
  onDone: () => void
  children?: ReactNode
}) {
  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (variables === null) return
    mutation.mutate(variables, {
      onSuccess: (answer) => {
        if (isSuccess(answer)) onDone()
      },
    })
  }
  const answer = mutation.data
  return (
    <form onSubmit={submit}>
      <Stack>
        {children}
        {answer !== undefined && !isSuccess(answer) && <AnswerBanner answer={answer} entity={entity} />}
        {mutation.error && <ErrorBanner error={mutation.error} />}
        <Group justify="flex-end">
          <Button type="submit" disabled={variables === null} loading={mutation.isPending}>
            {label}
          </Button>
        </Group>
      </Stack>
    </form>
  )
}

/** A read's state: loading, a failure banner, or its answer. */
export function QueryView<A extends AnyAnswer>({
  query,
  children,
}: {
  query: UseQueryResult<A, Error>
  children: (answer: A) => ReactNode
}) {
  if (query.status === 'pending') return <Loader size="sm" />
  if (query.status === 'error') return <ErrorBanner error={query.error} />
  return <>{children(query.data)}</>
}

export function PageHeader({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <Group justify="space-between" mb="md">
      <Title order={2}>{title}</Title>
      {action}
    </Group>
  )
}

export function SectionHeader({ title, extra }: { title: string; extra?: ReactNode }) {
  return (
    <Group justify="space-between" mb="xs">
      <Title order={3}>{title}</Title>
      {extra}
    </Group>
  )
}
