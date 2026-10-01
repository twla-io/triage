import { Alert, Text } from '@mantine/core'
import { ApiError } from '../api/client'
import type { AnyAnswer } from '../api/answers'
import { humanize, humanizeLower, withArticle } from './humanize'

function prefixOf(tag: string, suffix: string): string | null {
  return tag.endsWith(suffix) && tag.length > suffix.length ? tag.slice(0, -suffix.length) : null
}

function movedOn(entity: string, now: string): string {
  return `Someone else already acted on this ${humanizeLower(entity)}; it is now ${humanizeLower(now)}.`
}

/**
 * One sentence per kind of answer, filled from its tag and `detail`.
 * `entity` is the entity the action acts on, for a bare `movedOn`.
 */
export function outcomeSentence(answer: AnyAnswer, entity: string): string {
  switch (answer.outcome) {
    case 'intakeRequestInWrongState':
      return `This action doesn't apply to ${withArticle(prefixOf(answer.outcome, 'InWrongState') ?? entity)} that is ${humanizeLower(answer.detail.type)}.`
    case 'movedOn':
      return movedOn(entity, answer.detail.type)
    case 'intakeRequestMovedOn':
      return movedOn(prefixOf(answer.outcome, 'MovedOn') ?? entity, answer.detail.type)
    case 'matchAttempted':
      return outcomeSentence(answer.detail, entity)
    default: {
      const missing = prefixOf(answer.outcome, 'NotFound')
      if (missing !== null) return `That ${humanizeLower(missing)} no longer exists.`
      const consumed = prefixOf(answer.outcome, 'Consumed')
      if (consumed !== null) return `That ${humanizeLower(consumed)} was just taken by someone else.`
      return humanize(answer.outcome)
    }
  }
}

/** A failure (non-200 status or network): red, with its status and body. */
export function ErrorBanner({ error }: { error: Error }) {
  if (error instanceof ApiError) {
    return (
      <Alert color="red" title={error.status}>
        <Text size="sm" style={{ whiteSpace: 'pre-wrap' }}>{error.body}</Text>
      </Alert>
    )
  }
  return (
    <Alert color="red">
      <Text size="sm">{error.message}</Text>
    </Alert>
  )
}

/** A non-success answer: yellow, one sentence. */
export function AnswerBanner({ answer, entity }: { answer: AnyAnswer; entity: string }) {
  return (
    <Alert color="yellow">
      <Text size="sm">{outcomeSentence(answer, entity)}</Text>
    </Alert>
  )
}
