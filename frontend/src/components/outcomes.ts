import type { Schemas } from '../api/client'
import { humanize, inSentence, withArticle } from './humanize'

export type Outcome = { kind: 'success' } | { kind: 'notice'; text: string }

const success: Outcome = { kind: 'success' }

function notice(text: string): Outcome {
  return { kind: 'notice', text }
}

function notFound(entity: string): Outcome {
  return notice(`That ${inSentence(entity)} no longer exists.`)
}

function inWrongState(entity: string, detailType: string): Outcome {
  return notice(`This action doesn't apply to ${withArticle(entity)} that is ${inSentence(detailType)}.`)
}

function movedOn(entity: string, detailType: string): Outcome {
  return notice(`Someone else already acted on this ${inSentence(entity)}; it is now ${inSentence(detailType)}.`)
}

function consumed(entity: string): Outcome {
  return notice(`That ${inSentence(entity)} was just taken by someone else.`)
}

function other(tag: string): Outcome {
  return notice(humanize(tag))
}

export function describeCreateDoctor(answer: Schemas['CreateDoctorAnswer']): Outcome {
  switch (answer.outcome) {
    case 'ok':
      return success
  }
}

export function describeCreatePatient(answer: Schemas['CreatePatientAnswer']): Outcome {
  switch (answer.outcome) {
    case 'ok':
      return success
  }
}

export function describeCreateHealthcareService(answer: Schemas['CreateHealthcareServiceAnswer']): Outcome {
  switch (answer.outcome) {
    case 'ok':
      return success
  }
}

export function describeSubmitIntakeRequest(answer: Schemas['SubmitIntakeRequestAnswer']): Outcome {
  switch (answer.outcome) {
    case 'ok':
      return success
    case 'patientNotFound':
      return notFound('Patient')
  }
}

export function describeAcceptSubmittedIntakeRequest(answer: Schemas['AcceptSubmittedIntakeRequestAnswer']): Outcome {
  switch (answer.outcome) {
    case 'transitioned':
      return success
    case 'movedOn':
      return movedOn('IntakeRequest', answer.detail.type)
    case 'intakeRequestNotFound':
      return notFound('IntakeRequest')
    case 'healthcareServiceNotFound':
      return notFound('HealthcareService')
    case 'doctorNotFound':
      return notFound('Doctor')
  }
}

export function describeRejectSubmittedIntakeRequest(answer: Schemas['RejectSubmittedIntakeRequestAnswer']): Outcome {
  switch (answer.outcome) {
    case 'transitioned':
      return success
    case 'movedOn':
      return movedOn('IntakeRequest', answer.detail.type)
    case 'intakeRequestNotFound':
      return notFound('IntakeRequest')
  }
}

export function describeWithdrawIntakeRequest(answer: Schemas['WithdrawIntakeRequestAnswer']): Outcome {
  switch (answer.outcome) {
    case 'transitioned':
      return success
    case 'movedOn':
      return movedOn('IntakeRequest', answer.detail.type)
    case 'intakeRequestNotFound':
      return notFound('IntakeRequest')
  }
}

export function describeMatchAcceptedIntakeRequestToSlot(
  answer: Schemas['MatchAcceptedIntakeRequestToSlotAnswer'],
): Outcome {
  switch (answer.outcome) {
    case 'intakeRequestMatchedToSlot':
      return success
    case 'availableSlotConsumed':
      return consumed('AvailableSlot')
    case 'intakeRequestMovedOn':
      return movedOn('IntakeRequest', answer.detail.type)
    case 'intakeRequestNotFound':
      return notFound('IntakeRequest')
    case 'intakeRequestInWrongState':
      return inWrongState('IntakeRequest', answer.detail.type)
    case 'intakeRequestDoesNotMatchSlot':
      return other(answer.outcome)
  }
}

export function describeMarkAcceptedIntakeRequestStale(
  answer: Schemas['MarkAcceptedIntakeRequestStaleAnswer'],
): Outcome {
  switch (answer.outcome) {
    case 'transitioned':
      return success
    case 'movedOn':
      return movedOn('IntakeRequest', answer.detail.type)
    case 'intakeRequestNotFound':
      return notFound('IntakeRequest')
    case 'intakeRequestInWrongState':
      return inWrongState('IntakeRequest', answer.detail.type)
  }
}

export function describeCloseAppointedIntakeRequest(answer: Schemas['CloseAppointedIntakeRequestAnswer']): Outcome {
  switch (answer.outcome) {
    case 'transitioned':
      return success
    case 'movedOn':
      return movedOn('IntakeRequest', answer.detail.type)
    case 'intakeRequestNotFound':
      return notFound('IntakeRequest')
    case 'intakeRequestInWrongState':
      return inWrongState('IntakeRequest', answer.detail.type)
  }
}

export function describeCreateAvailableSlot(answer: Schemas['CreateAvailableSlotAnswer']): Outcome {
  switch (answer.outcome) {
    case 'availableSlotAdded':
      return success
    case 'availableSlotOverlapsDoctorCalendar':
      return other(answer.outcome)
    case 'doctorNotFound':
      return notFound('Doctor')
    case 'healthcareServiceNotFound':
      return notFound('HealthcareService')
  }
}

function describeMatchIntakeRequestToSlotOutcome(outcome: Schemas['MatchIntakeRequestToSlotOutcome']): Outcome {
  switch (outcome.outcome) {
    case 'intakeRequestMatchedToSlot':
      return success
    case 'availableSlotConsumed':
      return consumed('AvailableSlot')
    case 'intakeRequestMovedOn':
      return movedOn('IntakeRequest', outcome.detail.type)
  }
}

export function describeMatchAvailableSlotByPriority(answer: Schemas['MatchAvailableSlotByPriorityAnswer']): Outcome {
  switch (answer.outcome) {
    case 'noIntakeRequestMatched':
      return other(answer.outcome)
    case 'matchIntakeRequestToSlotOutcome':
      return describeMatchIntakeRequestToSlotOutcome(answer.detail)
  }
}
