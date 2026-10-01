import { useState } from 'react'
import type { Schemas } from '../api/client'
import {
  useAcceptSubmittedIntakeRequest,
  useCloseAppointedIntakeRequest,
  useMarkAcceptedIntakeRequestStale,
  useMatchAcceptedIntakeRequestToSlot,
  useRejectSubmittedIntakeRequest,
  useSubmitIntakeRequest,
  useWithdrawIntakeRequest,
} from '../api/queries/intakeRequests'
import { AnswerForm } from './actions'
import {
  AvailableSlotSelect,
  CloseReasonControl,
  completeCloseReason,
  completeDoctorRequirement,
  completePriority,
  DoctorRequirementControl,
  HealthcareServiceSelect,
  OptionalTextControl,
  PatientSelect,
  PriorityControl,
  TextControl,
} from './controls'
import type { Draft } from './draft'
import { Notice } from './feedback'
import {
  describeAcceptSubmittedIntakeRequest,
  describeCloseAppointedIntakeRequest,
  describeMarkAcceptedIntakeRequestStale,
  describeMatchAcceptedIntakeRequestToSlot,
  describeRejectSubmittedIntakeRequest,
  describeSubmitIntakeRequest,
  describeWithdrawIntakeRequest,
} from './outcomes'

type Id = Schemas['IntakeRequestId']
type FormProps = { label: string; onDone: () => void }
type ActionFormProps = FormProps & { id: Id }

// Decision "The doctor requirement is decided at triage" (docs/decisions.md).
const narrativePrompt = 'A preferred doctor, if any, can be named here.'
const specificDoctorWarning = 'This request will wait for that doctor, even if other doctors are free before its deadline.'

export function SubmitIntakeRequestForm({ label, onDone }: FormProps) {
  const [patientId, setPatientId] = useState<string | null>(null)
  const [narrative, setNarrative] = useState('')
  const mutation = useSubmitIntakeRequest()
  const variables = patientId === null ? null : { patientId, narrative }
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={variables}
      describe={describeSubmitIntakeRequest}
      onDone={onDone}
    >
      <PatientSelect name="patientId" value={patientId} onChange={setPatientId} />
      <TextControl name="narrative" value={narrative} onChange={setNarrative} description={narrativePrompt} />
    </AnswerForm>
  )
}

export function AcceptSubmittedIntakeRequestForm({ id, label, onDone }: ActionFormProps) {
  const [healthcareServiceId, setHealthcareServiceId] = useState<string | null>(null)
  const [priority, setPriority] = useState<Draft<Schemas['IntakeRequestPriority']> | null>(null)
  // The decision: triage sets the doctor requirement, defaulting to any doctor.
  const [doctorRequirement, setDoctorRequirement] = useState<Draft<Schemas['DoctorRequirement']> | null>({
    type: 'anyDoctor',
  })
  const mutation = useAcceptSubmittedIntakeRequest()

  const completedPriority = priority === null ? null : completePriority(priority)
  const completedRequirement = doctorRequirement === null ? null : completeDoctorRequirement(doctorRequirement)
  const variables =
    healthcareServiceId === null || completedPriority === null || completedRequirement === null
      ? null
      : {
          id,
          body: { healthcareServiceId, priority: completedPriority, doctorRequirement: completedRequirement },
        }
  const warn =
    doctorRequirement?.type === 'specificDoctor' && (priority?.type === 'emergency' || priority?.type === 'urgent')

  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={variables}
      describe={describeAcceptSubmittedIntakeRequest}
      onDone={onDone}
    >
      <HealthcareServiceSelect name="healthcareServiceId" value={healthcareServiceId} onChange={setHealthcareServiceId} />
      <PriorityControl name="priority" value={priority} onChange={setPriority} />
      <DoctorRequirementControl name="doctorRequirement" value={doctorRequirement} onChange={setDoctorRequirement} />
      {warn && <Notice>{specificDoctorWarning}</Notice>}
    </AnswerForm>
  )
}

export function RejectSubmittedIntakeRequestForm({ id, label, onDone }: ActionFormProps) {
  const [rejectionReason, setRejectionReason] = useState('')
  const mutation = useRejectSubmittedIntakeRequest()
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={{ id, body: { rejectionReason } }}
      describe={describeRejectSubmittedIntakeRequest}
      onDone={onDone}
    >
      <TextControl name="rejectionReason" value={rejectionReason} onChange={setRejectionReason} />
    </AnswerForm>
  )
}

export function WithdrawIntakeRequestForm({ id, label, onDone }: ActionFormProps) {
  const [withdrawalNote, setWithdrawalNote] = useState<string | null>(null)
  const mutation = useWithdrawIntakeRequest()
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={{ id, body: { withdrawalNote } }}
      describe={describeWithdrawIntakeRequest}
      onDone={onDone}
    >
      <OptionalTextControl name="withdrawalNote" value={withdrawalNote} onChange={setWithdrawalNote} />
    </AnswerForm>
  )
}

export function MatchAcceptedIntakeRequestToSlotForm({ id, label, onDone }: ActionFormProps) {
  const [slotId, setSlotId] = useState<string | null>(null)
  const mutation = useMatchAcceptedIntakeRequestToSlot()
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={slotId === null ? null : { id, body: { slotId } }}
      describe={describeMatchAcceptedIntakeRequestToSlot}
      onDone={onDone}
    >
      <AvailableSlotSelect name="slotId" value={slotId} onChange={setSlotId} />
    </AnswerForm>
  )
}

export function MarkAcceptedIntakeRequestStaleForm({ id, label, onDone }: ActionFormProps) {
  const mutation = useMarkAcceptedIntakeRequestStale()
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={id}
      describe={describeMarkAcceptedIntakeRequestStale}
      onDone={onDone}
    />
  )
}

export function CloseAppointedIntakeRequestForm({ id, label, onDone }: ActionFormProps) {
  const [closeReason, setCloseReason] = useState<Draft<Schemas['CloseReasonRequest']> | null>(null)
  const mutation = useCloseAppointedIntakeRequest()
  const completed = closeReason === null ? null : completeCloseReason(closeReason)
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={completed === null ? null : { id, body: { closeReason: completed } }}
      describe={describeCloseAppointedIntakeRequest}
      onDone={onDone}
    >
      <CloseReasonControl name="closeReason" value={closeReason} onChange={setCloseReason} />
    </AnswerForm>
  )
}
