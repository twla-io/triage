import { Badge } from '@mantine/core'
import dayjs from 'dayjs'
import type { Schemas } from '../api/client'

export type PriorityDTO = Schemas['IntakeRequestPriorityDTO']

const DATE_FORMAT = 'MMM D, YYYY h:mm A'

// `due`'s wire shape depends on the tier (Transport.hs's
// IntakeRequestPriorityDTO/RoutineDueDTO): a flat ISO timestamp for
// emergency/urgent, a nested {type, from?, to?} tagged object for
// routine. The generated schema types it as an opaque blob (anySchema
// has no oneOf-based TS shape), so this narrows it by hand at the one
// place it's read instead of trusting the generated type.
export function formatDue(priority: PriorityDTO | undefined): string {
  if (!priority) return ''
  switch (priority.type) {
    case 'emergency':
    case 'urgent':
      return `Due by ${dayjs(priority.due as unknown as string).format(DATE_FORMAT)}`
    case 'routine': {
      const routineDue = priority.due as unknown as { type: string; from?: string; to?: string }
      switch (routineDue.type) {
        case 'routineAnytime':
          return 'Anytime'
        case 'routineNotBefore':
          return `Not before ${dayjs(routineDue.from).format(DATE_FORMAT)}`
        case 'routineNotAfter':
          return `Not after ${dayjs(routineDue.to).format(DATE_FORMAT)}`
        case 'routineWithin':
          return `Within ${dayjs(routineDue.from).format(DATE_FORMAT)} – ${dayjs(routineDue.to).format(DATE_FORMAT)}`
        default:
          return ''
      }
    }
    default:
      return ''
  }
}

// Emergency = red, Urgent = amber, Routine = green -- the priority color
// convention this project's presentation materials already use
// (triage-ui-codegen skill).
export function priorityColor(priority: PriorityDTO | undefined): string {
  switch (priority?.type) {
    case 'emergency':
      return 'red'
    case 'urgent':
      return 'orange'
    case 'routine':
      return 'green'
    default:
      return 'gray'
  }
}

export function PriorityBadge({ priority }: { priority: PriorityDTO | undefined }) {
  if (!priority) return null
  return <Badge color={priorityColor(priority)}>{priority.type}</Badge>
}
