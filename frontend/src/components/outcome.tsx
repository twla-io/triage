import type { ReactNode } from 'react'
import { Alert, Loader, Text } from '@mantine/core'
import type { UseQueryResult } from '@tanstack/react-query'
import { ApiError } from '../api/client'
import type { AnyAnswer, OkAnswer, OkOrErrorAnswer } from '../api/wire'
import { humanize, humanizeLower } from './labels'

const notFound = (entity: string) => `That ${humanizeLower(entity)} no longer exists.`
const inWrongState = (entity: string, state: string) =>
  `This action doesn't apply to a ${humanizeLower(entity)} that is ${humanizeLower(state)}.`
const movedOn = (entity: string, state: string) =>
  `Someone else already acted on this ${humanizeLower(entity)}; it is now ${humanizeLower(state)}.`
const consumed = (entity: string) => `That ${humanizeLower(entity)} was just taken by someone else.`

// One sentence per kind of answer (show-every-outcome); null for a success tag.
export function outcomeSentence(answer: AnyAnswer): string | null {
  switch (answer.outcome) {
    case 'ok':
    case 'transitioned':
    case 'matched':
    case 'slotCreated':
      return null
    case 'matchAttempted':
      return outcomeSentence(answer.detail)
    case 'doctorNotFound':
      return notFound('doctor')
    case 'patientNotFound':
      return notFound('patient')
    case 'healthcareServiceNotFound':
      return notFound('healthcareService')
    case 'intakeRequestNotFound':
      return notFound('intakeRequest')
    case 'intakeRequestInWrongState':
      return inWrongState('intakeRequest', answer.detail.type)
    case 'movedOn':
      // `movedOn` carries the request in its current state (detail: IntakeRequest).
      return movedOn('intakeRequest', answer.detail.type)
    case 'intakeRequestMovedOn':
      return movedOn('intakeRequest', answer.detail.type)
    case 'availableSlotConsumed':
      return consumed('availableSlot')
    case 'slotDoesNotMatchIntakeRequest':
    case 'slotOverlapsDoctorCalendar':
    case 'noMatchingIntakeRequest':
      return humanize(answer.outcome)
  }
}

export function OutcomeText({ sentence }: { sentence: string | null }) {
  if (sentence === null) return null
  return (
    <Alert color="gray" variant="light">
      <Text size="sm">{sentence}</Text>
    </Alert>
  )
}

// A non-200 status (or an answer that doesn't decode): status and body.
export function ErrorBanner({ error }: { error: unknown }) {
  if (error === null || error === undefined) return null
  const title = error instanceof ApiError ? `Error ${error.status}` : 'Error'
  const body = error instanceof ApiError ? error.body : error instanceof Error ? error.message : String(error)
  return (
    <Alert color="red" variant="light" title={title}>
      <Text size="sm" style={{ whiteSpace: 'pre-wrap' }}>
        {body}
      </Text>
    </Alert>
  )
}

// Renders a read's answer: its `ok` detail through `children`, any other tag
// by its sentence, a failed request by an error banner.
export function ReadAnswer<T>({
  query,
  children,
}: {
  query: UseQueryResult<OkAnswer<T> | OkOrErrorAnswer<T>>
  children: (detail: T) => ReactNode
}) {
  if (query.isPending) return <Loader size="sm" />
  if (query.isError) return <ErrorBanner error={query.error} />
  const answer = query.data
  if (answer.outcome === 'ok') return <>{children(answer.detail)}</>
  return <OutcomeText sentence={outcomeSentence(answer)} />
}

// The `ok` detail of a read, if there is one (for selects and name lookups).
export function okDetail<T>(answer: OkAnswer<T> | OkOrErrorAnswer<T> | undefined): T | undefined {
  return answer !== undefined && answer.outcome === 'ok' ? answer.detail : undefined
}
