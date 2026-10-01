import type { FormEvent, ReactNode } from 'react'
import { Button, Group, Modal, Stack } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import type { UseMutationResult } from '@tanstack/react-query'
import { ErrorBanner, Notice } from './feedback'
import type { Outcome } from './outcomes'

// An action is a button that opens its form, titled with the same word.
export function ActionButton({ label, children }: { label: string; children: (close: () => void) => ReactNode }) {
  const [opened, { open, close }] = useDisclosure(false)
  return (
    <>
      <Button size="xs" variant="default" onClick={open}>
        {label}
      </Button>
      <Modal opened={opened} onClose={close} title={label} size="lg">
        {opened && children(close)}
      </Modal>
    </>
  )
}

// Submits `variables` (null while the form is incomplete). The success tag closes
// the form; every other tag is shown inline, and a failure is an error banner.
export function AnswerForm<V, A>({
  label,
  mutation,
  variables,
  describe,
  onDone,
  children,
}: {
  label: string
  mutation: UseMutationResult<A, Error, V>
  variables: V | null
  describe: (answer: A) => Outcome
  onDone: () => void
  children?: ReactNode
}) {
  const outcome = mutation.data === undefined ? null : describe(mutation.data)

  function submit(event: FormEvent) {
    event.preventDefault()
    if (variables === null) return
    mutation.mutate(variables, {
      onSuccess: (answer) => {
        if (describe(answer).kind === 'success') onDone()
      },
    })
  }

  return (
    <form onSubmit={submit}>
      <Stack>
        {children}
        {outcome?.kind === 'notice' && <Notice>{outcome.text}</Notice>}
        {mutation.error && <ErrorBanner error={mutation.error} />}
        <Group justify="flex-end">
          <Button type="submit" variant="default" disabled={variables === null} loading={mutation.isPending}>
            {label}
          </Button>
        </Group>
      </Stack>
    </form>
  )
}
