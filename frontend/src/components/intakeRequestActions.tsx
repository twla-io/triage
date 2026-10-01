import { useState } from 'react'
import { Alert, Group, Text } from '@mantine/core'
import type { Schemas } from '../api/client'
import { useDoctorCalendarEntries } from '../api/queries/doctorCalendar'
import {
  useAcceptSubmittedIntakeRequest,
  useCloseAppointedIntakeRequest,
  useMarkAcceptedIntakeRequestStale,
  useMatchAcceptedIntakeRequestToSlot,
  useRejectSubmittedIntakeRequest,
  useWithdrawIntakeRequest,
} from '../api/queries/intakeRequests'
import { ActionButton, ActionForm, QueryView } from './actions'
import { HealthcareServiceSelect, IdSelect, OptionalTextControl, TextControl } from './controls'
import type { DraftRecord } from './draft'
import { humanize } from './humanize'
import { AnswerBanner } from './outcome'
import {
  CloseReasonControl,
  completeCloseReason,
  completeDoctorRequirement,
  completePriority,
  DoctorRequirementControl,
  PriorityControl,
} from './sumControls'
import { shownTime } from './time'
import { useNames } from './values'
import { useWeek, WeekRange } from './WeekRange'

type IntakeRequest = Schemas['IntakeRequest']
type IntakeRequestId = Schemas['IntakeRequestId']

const ENTITY = 'intakeRequest'

type IntakeRequestAction = 'accept' | 'reject' | 'withdraw' | 'matchToSlot' | 'markStale' | 'close'

/**
 * The transitions Domain.hs defines out of each case, and nothing else.
 * The one mapping for intake requests, shared by every screen that shows one.
 */
export function intakeRequestActions(request: IntakeRequest): IntakeRequestAction[] {
  switch (request.type) {
    case 'submitted':
      return ['accept', 'reject', 'withdraw']
    case 'rejected':
      return []
    case 'accepted':
      return ['matchToSlot', 'markStale', 'withdraw']
    case 'appointed':
      return ['close']
    case 'withdrawn':
      return []
    case 'stale':
      return []
    case 'closed':
      return []
  }
}

export function IntakeRequestActions({ request }: { request: IntakeRequest }) {
  const actions = intakeRequestActions(request)
  if (actions.length === 0) return null
  return (
    <Group gap="xs" wrap="nowrap">
      {actions.map((action) => (
        <ActionButton key={action} label={humanize(action)}>
          {(close) => <IntakeRequestActionForm action={action} id={request.id} onDone={close} />}
        </ActionButton>
      ))}
    </Group>
  )
}

function IntakeRequestActionForm({
  action,
  id,
  onDone,
}: {
  action: IntakeRequestAction
  id: IntakeRequestId
  onDone: () => void
}) {
  switch (action) {
    case 'accept':
      return <AcceptForm id={id} onDone={onDone} />
    case 'reject':
      return <RejectForm id={id} onDone={onDone} />
    case 'withdraw':
      return <WithdrawForm id={id} onDone={onDone} />
    case 'matchToSlot':
      return <MatchToSlotForm id={id} onDone={onDone} />
    case 'markStale':
      return <MarkStaleForm id={id} onDone={onDone} />
    case 'close':
      return <CloseForm id={id} onDone={onDone} />
  }
}

interface FormProps {
  id: IntakeRequestId
  onDone: () => void
}

// docs/decisions.md, "The doctor requirement is decided at triage": triage
// defaults to any doctor, and warns when an Emergency or Urgent request is
// set to wait for a specific doctor.
const SPECIFIC_DOCTOR_WARNING =
  'This request will wait for that doctor, even if other doctors are free before its deadline.'

function AcceptForm({ id, onDone }: FormProps) {
  const mutation = useAcceptSubmittedIntakeRequest()
  const [draft, setDraft] = useState<DraftRecord<Schemas['AcceptSubmittedIntakeRequestRequest']>>({
    healthcareServiceId: null,
    priority: null,
    doctorRequirement: { type: 'anyDoctor' },
  })
  const healthcareServiceId = draft.healthcareServiceId
  const priority = completePriority(draft.priority)
  const doctorRequirement = completeDoctorRequirement(draft.doctorRequirement)
  const variables =
    healthcareServiceId !== null && priority !== null && doctorRequirement !== null
      ? { intakeRequestId: id, body: { healthcareServiceId, priority, doctorRequirement } }
      : null
  const deadlineTier = draft.priority?.type === 'emergency' || draft.priority?.type === 'urgent'
  const warn = deadlineTier && draft.doctorRequirement?.type === 'specificDoctor'
  return (
    <ActionForm
      label={humanize('accept')}
      entity={ENTITY}
      mutation={mutation}
      variables={variables}
      isSuccess={(a) => a.outcome === 'transitioned'}
      onDone={onDone}
    >
      <HealthcareServiceSelect
        label={humanize('healthcareServiceId')}
        value={draft.healthcareServiceId}
        onChange={(v) => setDraft({ ...draft, healthcareServiceId: v })}
      />
      <PriorityControl
        label={humanize('priority')}
        value={draft.priority}
        onChange={(v) => setDraft({ ...draft, priority: v })}
      />
      <DoctorRequirementControl
        label={humanize('doctorRequirement')}
        value={draft.doctorRequirement}
        onChange={(v) => setDraft({ ...draft, doctorRequirement: v })}
      />
      {warn && (
        <Alert color="yellow">
          <Text size="sm">{SPECIFIC_DOCTOR_WARNING}</Text>
        </Alert>
      )}
    </ActionForm>
  )
}

function RejectForm({ id, onDone }: FormProps) {
  const mutation = useRejectSubmittedIntakeRequest()
  const [rejectionReason, setRejectionReason] = useState('')
  return (
    <ActionForm
      label={humanize('reject')}
      entity={ENTITY}
      mutation={mutation}
      variables={{ intakeRequestId: id, body: { rejectionReason } }}
      isSuccess={(a) => a.outcome === 'transitioned'}
      onDone={onDone}
    >
      <TextControl label={humanize('rejectionReason')} value={rejectionReason} onChange={setRejectionReason} />
    </ActionForm>
  )
}

function WithdrawForm({ id, onDone }: FormProps) {
  const mutation = useWithdrawIntakeRequest()
  const [withdrawalNote, setWithdrawalNote] = useState<string | null>(null)
  return (
    <ActionForm
      label={humanize('withdraw')}
      entity={ENTITY}
      mutation={mutation}
      variables={{ intakeRequestId: id, body: { withdrawalNote } }}
      isSuccess={(a) => a.outcome === 'transitioned'}
      onDone={onDone}
    >
      <OptionalTextControl label={humanize('withdrawalNote')} value={withdrawalNote} onChange={setWithdrawalNote} />
    </ActionForm>
  )
}

/**
 * `slotId` is an element of the sealed DoctorCalendar: a select over the
 * calendar's read, with its week picker, keeping only the Slot case.
 */
function MatchToSlotForm({ id, onDone }: FormProps) {
  const mutation = useMatchAcceptedIntakeRequestToSlot()
  const week = useWeek()
  const entries = useDoctorCalendarEntries(week.range)
  const names = useNames()
  const [slotId, setSlotId] = useState<Schemas['SlotId'] | null>(null)
  const changeWeek = (move: () => void) => () => {
    setSlotId(null)
    move()
  }
  return (
    <ActionForm
      label={humanize('matchToSlot')}
      entity={ENTITY}
      mutation={mutation}
      variables={slotId === null ? null : { intakeRequestId: id, body: { slotId } }}
      isSuccess={(a) => a.outcome === 'matched'}
      onDone={onDone}
    >
      <WeekRange week={{ ...week, previous: changeWeek(week.previous), next: changeWeek(week.next) }} />
      <QueryView query={entries}>
        {(answer) =>
          answer.outcome === 'ok' ? (
            <IdSelect
              label={humanize('slotId')}
              value={slotId}
              onChange={setSlotId}
              options={answer.detail
                .flatMap((entry) => (entry.type === 'slot' ? [entry] : []))
                .map((slot) => ({
                  value: slot.id,
                  label: [
                    names.doctor(slot.doctorId),
                    names.healthcareService(slot.healthcareServiceId),
                    shownTime(slot.start),
                    humanize(slot.duration.type),
                  ].join(' · '),
                }))}
            />
          ) : (
            <AnswerBanner answer={answer} entity="doctorCalendarEntry" />
          )
        }
      </QueryView>
    </ActionForm>
  )
}

function MarkStaleForm({ id, onDone }: FormProps) {
  const mutation = useMarkAcceptedIntakeRequestStale()
  return (
    <ActionForm
      label={humanize('markStale')}
      entity={ENTITY}
      mutation={mutation}
      variables={id}
      isSuccess={(a) => a.outcome === 'transitioned'}
      onDone={onDone}
    />
  )
}

function CloseForm({ id, onDone }: FormProps) {
  const mutation = useCloseAppointedIntakeRequest()
  const [draft, setDraft] = useState<DraftRecord<Schemas['CloseAppointedIntakeRequestRequest']>>({ closeReason: null })
  const closeReason = completeCloseReason(draft.closeReason)
  return (
    <ActionForm
      label={humanize('close')}
      entity={ENTITY}
      mutation={mutation}
      variables={closeReason === null ? null : { intakeRequestId: id, body: { closeReason } }}
      isSuccess={(a) => a.outcome === 'transitioned'}
      onDone={onDone}
    >
      <CloseReasonControl
        label={humanize('closeReason')}
        value={draft.closeReason}
        onChange={(v) => setDraft({ closeReason: v })}
      />
    </ActionForm>
  )
}
