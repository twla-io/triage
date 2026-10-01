import type { ReactNode } from 'react'
import type { Schemas } from '../api/client'
import { ActionButton } from './actions'
import { actionLabel } from './humanize'
import {
  AcceptSubmittedIntakeRequestForm,
  CloseAppointedIntakeRequestForm,
  MarkAcceptedIntakeRequestStaleForm,
  MatchAcceptedIntakeRequestToSlotForm,
  RejectSubmittedIntakeRequestForm,
  WithdrawIntakeRequestForm,
} from './intakeRequestForms'

const accept = actionLabel('AcceptSubmittedIntakeRequest', 'IntakeRequest', 'Submitted')
const reject = actionLabel('RejectSubmittedIntakeRequest', 'IntakeRequest', 'Submitted')
const withdraw = actionLabel('WithdrawIntakeRequest', 'IntakeRequest')
const matchToSlot = actionLabel('MatchAcceptedIntakeRequestToSlot', 'IntakeRequest', 'Accepted')
const markStale = actionLabel('MarkAcceptedIntakeRequestStale', 'IntakeRequest', 'Accepted')
const close = actionLabel('CloseAppointedIntakeRequest', 'IntakeRequest', 'Appointed')

// Exactly the transitions Domain.hs defines out of each case, in the order of the
// cases they lead to; terminal cases are read-only.
export function intakeRequestActions(request: Schemas['IntakeRequest']): ReactNode[] {
  const id = request.id
  switch (request.type) {
    case 'submitted':
      return [
        <ActionButton key={reject} label={reject}>
          {(done) => <RejectSubmittedIntakeRequestForm id={id} label={reject} onDone={done} />}
        </ActionButton>,
        <ActionButton key={accept} label={accept}>
          {(done) => <AcceptSubmittedIntakeRequestForm id={id} label={accept} onDone={done} />}
        </ActionButton>,
        <ActionButton key={withdraw} label={withdraw}>
          {(done) => <WithdrawIntakeRequestForm id={id} label={withdraw} onDone={done} />}
        </ActionButton>,
      ]
    case 'accepted':
      return [
        <ActionButton key={matchToSlot} label={matchToSlot}>
          {(done) => <MatchAcceptedIntakeRequestToSlotForm id={id} label={matchToSlot} onDone={done} />}
        </ActionButton>,
        <ActionButton key={withdraw} label={withdraw}>
          {(done) => <WithdrawIntakeRequestForm id={id} label={withdraw} onDone={done} />}
        </ActionButton>,
        <ActionButton key={markStale} label={markStale}>
          {(done) => <MarkAcceptedIntakeRequestStaleForm id={id} label={markStale} onDone={done} />}
        </ActionButton>,
      ]
    case 'appointed':
      return [
        <ActionButton key={close} label={close}>
          {(done) => <CloseAppointedIntakeRequestForm id={id} label={close} onDone={done} />}
        </ActionButton>,
      ]
    case 'rejected':
    case 'withdrawn':
    case 'stale':
    case 'closed':
      return []
  }
}
