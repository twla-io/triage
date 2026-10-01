import { useState, type ReactNode } from 'react'
import { Button, Group, Modal, Stack } from '@mantine/core'
import type { AnyAnswer } from '../api/wire'
import { humanize } from './labels'
import { ErrorBanner, OutcomeText, outcomeSentence } from './outcome'

// A form for one use case. The success tag closes it; every other tag is
// shown inline by its sentence; a non-200 status by an error banner.
// `submit` is null while the form doesn't yet hold a complete value.
export function FormModal({
  useCase,
  onClose,
  submit,
  children,
}: {
  useCase: string
  onClose: () => void
  submit: (() => Promise<AnyAnswer>) | null
  children: ReactNode
}) {
  const [pending, setPending] = useState(false)
  const [sentence, setSentence] = useState<string | null>(null)
  const [error, setError] = useState<unknown>(null)

  const run = async () => {
    if (submit === null) return
    setPending(true)
    setSentence(null)
    setError(null)
    try {
      const answer = await submit()
      const text = outcomeSentence(answer)
      if (text === null) onClose()
      else setSentence(text)
    } catch (e) {
      setError(e)
    } finally {
      setPending(false)
    }
  }

  return (
    <Modal opened onClose={onClose} title={humanize(useCase)} size="lg">
      <form
        onSubmit={(e) => {
          e.preventDefault()
          void run()
        }}
      >
        <Stack>
          {children}
          <OutcomeText sentence={sentence} />
          <ErrorBanner error={error} />
          <Group justify="flex-end">
            <Button type="submit" disabled={submit === null} loading={pending}>
              {humanize(useCase)}
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}

// An action with no request body: runs at once; its answer is shown inline.
export function useImmediateAction() {
  const [pending, setPending] = useState(false)
  const [sentence, setSentence] = useState<string | null>(null)
  const [error, setError] = useState<unknown>(null)
  const run = async (action: () => Promise<AnyAnswer>) => {
    setPending(true)
    setSentence(null)
    setError(null)
    try {
      setSentence(outcomeSentence(await action()))
    } catch (e) {
      setError(e)
    } finally {
      setPending(false)
    }
  }
  const feedback = (
    <>
      <OutcomeText sentence={sentence} />
      <ErrorBanner error={error} />
    </>
  )
  return { pending, run, feedback }
}
