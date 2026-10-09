import type { FormEvent, ReactNode } from 'react'
import { Button, Group, Modal, Stack } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import type { UseMutationResult } from '@tanstack/react-query'
import { ErrorBanner } from './feedback'
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

// Submits `variables` (null while the form is incomplete). Any answer closes the form;
// a non-success tag is a notification at the app's root, since the refresh after the
// answer can remove this form's card. A failure is an error banner in the form.
// `mutateAsync`, not `mutate`'s callbacks: those don't run once the form has unmounted.
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
  function submit(event: FormEvent) {
    event.preventDefault()
    if (variables === null) return
    mutation.mutateAsync(variables).then(
      (answer) => {
        const outcome = describe(answer)
        if (outcome.kind === 'notice')
          notifications.show({ title: label, message: outcome.text, color: 'yellow', autoClose: false })
        onDone()
      },
      () => {}, // shown as `mutation.error`
    )
  }

  return (
    <form onSubmit={submit}>
      <Stack>
        {children}
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
