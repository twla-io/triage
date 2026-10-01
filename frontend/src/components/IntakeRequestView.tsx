import { useState } from 'react'
import { Alert, Button, Group, Paper, Select, Stack, Text } from '@mantine/core'
import { useDoctorCalendar } from '../api/queries/doctorCalendar'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import {
  useAcceptSubmittedIntakeRequest,
  useCloseAppointedIntakeRequest,
  useMarkAcceptedIntakeRequestStale,
  useMatchAcceptedIntakeRequestToSlot,
  useRejectSubmittedIntakeRequest,
  useWithdrawIntakeRequest,
} from '../api/queries/intakeRequests'
import {
  isWithdrawnFromAccepted,
  type AppointedFields,
  type HealthcareServiceId,
  type IntakeRequest,
  type IntakeRequestId,
  type SlotId,
  type SubmittedFields,
  type TriagedFields,
} from '../api/wire'
import {
  CloseReasonControl,
  completeCloseReason,
  completeDoctorRequirement,
  completePriority,
  DoctorRequirementControl,
  HealthcareServiceSelect,
  PriorityControl,
  TextField,
  type CloseReasonDraft,
  type DoctorRequirementDraft,
  type PriorityDraft,
} from './controls'
import { FormModal, useImmediateAction } from './FormModal'
import { formatTime, humanize } from './labels'
import { okDetail } from './outcome'
import {
  CaseBadge,
  CloseReasonValue,
  DoctorName,
  DoctorRequirementValue,
  DurationValue,
  Fields,
  HealthcareServiceName,
  IdValue,
  PatientName,
  PriorityValue,
  TextValue,
  TimeValue,
  type Field,
} from './values'
import { useWeekRange, WeekRangePicker } from './WeekRange'

// ═══════════════════════════════════════════════════════════════════════════
// actions-follow-the-lifecycle: the transitions Domain.hs defines out of each
// IntakeRequest case, in the order of the case they lead to. Shared by every
// screen that shows an intake request.
// ═══════════════════════════════════════════════════════════════════════════

export type IntakeRequestAction =
  | 'rejectSubmittedIntakeRequest'
  | 'acceptSubmittedIntakeRequest'
  | 'matchAcceptedIntakeRequestToSlot'
  | 'withdrawIntakeRequest'
  | 'markAcceptedIntakeRequestStale'
  | 'closeAppointedIntakeRequest'

export function intakeRequestActions(r: IntakeRequest): IntakeRequestAction[] {
  switch (r.type) {
    case 'submitted':
      return ['rejectSubmittedIntakeRequest', 'acceptSubmittedIntakeRequest', 'withdrawIntakeRequest']
    case 'accepted':
      return ['matchAcceptedIntakeRequestToSlot', 'withdrawIntakeRequest', 'markAcceptedIntakeRequestStale']
    case 'appointed':
      return ['closeAppointedIntakeRequest']
    case 'rejected':
    case 'withdrawn':
    case 'stale':
    case 'closed':
      return []
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Display
// ═══════════════════════════════════════════════════════════════════════════

function submittedFields(r: SubmittedFields): Field[] {
  return [
    ['id', <IdValue id={r.id} />],
    ['patientId', <PatientName id={r.patientId} />],
    ['narrative', <TextValue text={r.narrative} />],
    ['createdAt', <TimeValue time={r.createdAt} />],
  ]
}

function triagedFields(r: TriagedFields): Field[] {
  return [
    ...submittedFields(r),
    ['healthcareServiceId', <HealthcareServiceName id={r.healthcareServiceId} />],
    ['priority', <PriorityValue value={r.priority} />],
    ['doctorRequirement', <DoctorRequirementValue value={r.doctorRequirement} />],
    ['triagedAt', <TimeValue time={r.triagedAt} />],
  ]
}

export function appointedFields(r: AppointedFields): Field[] {
  return [
    ...triagedFields(r),
    ['doctorId', <DoctorName id={r.doctorId} />],
    ['start', <TimeValue time={r.start} />],
    ['duration', <DurationValue value={r.duration} />],
  ]
}

function intakeRequestFields(r: IntakeRequest): Field[] {
  switch (r.type) {
    case 'submitted':
      return submittedFields(r)
    case 'rejected':
      return [
        ...submittedFields(r),
        ['rejectedAt', <TimeValue time={r.rejectedAt} />],
        ['rejectionReason', <TextValue text={r.rejectionReason} />],
      ]
    case 'accepted':
      return triagedFields(r)
    case 'appointed':
      return appointedFields(r)
    case 'withdrawn':
      return [
        ['withdrawnFrom', <CaseBadge tag={r.withdrawnFrom.type} />],
        ...(isWithdrawnFromAccepted(r) ? triagedFields(r) : submittedFields(r)),
        ['withdrawnAt', <TimeValue time={r.withdrawnAt} />],
        ['withdrawalNote', <TextValue text={r.withdrawalNote} />],
      ]
    case 'stale':
      return [...triagedFields(r), ['staleAt', <TimeValue time={r.staleAt} />]]
    case 'closed':
      return [...appointedFields(r), ['closeReason', <CloseReasonValue value={r.closeReason} />]]
  }
}

export function IntakeRequestCard({ request }: { request: IntakeRequest }) {
  return (
    <Paper withBorder p="sm">
      <Stack gap="xs">
        <Group>
          <CaseBadge tag={request.type} />
        </Group>
        <Fields fields={intakeRequestFields(request)} />
        <IntakeRequestActions request={request} />
      </Stack>
    </Paper>
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// Actions
// ═══════════════════════════════════════════════════════════════════════════

export function IntakeRequestActions({ request }: { request: IntakeRequest }) {
  const [open, setOpen] = useState<IntakeRequestAction | null>(null)
  const markStale = useMarkAcceptedIntakeRequestStale()
  const immediate = useImmediateAction()
  const actions = intakeRequestActions(request)
  if (actions.length === 0) return null

  const start = (action: IntakeRequestAction) => {
    switch (action) {
      case 'markAcceptedIntakeRequestStale':
        void immediate.run(() => markStale.mutateAsync(request.id))
        return
      case 'rejectSubmittedIntakeRequest':
      case 'acceptSubmittedIntakeRequest':
      case 'matchAcceptedIntakeRequestToSlot':
      case 'withdrawIntakeRequest':
      case 'closeAppointedIntakeRequest':
        setOpen(action)
        return
    }
  }

  const close = () => setOpen(null)

  return (
    <Stack gap="xs">
      <Group gap="xs">
        {actions.map((action) => (
          <Button
            key={action}
            size="xs"
            variant="default"
            loading={action === 'markAcceptedIntakeRequestStale' && immediate.pending}
            onClick={() => start(action)}
          >
            {humanize(action)}
          </Button>
        ))}
      </Group>
      {immediate.feedback}
      {open === 'rejectSubmittedIntakeRequest' && <RejectForm id={request.id} onClose={close} />}
      {open === 'acceptSubmittedIntakeRequest' && <AcceptForm id={request.id} onClose={close} />}
      {open === 'matchAcceptedIntakeRequestToSlot' && <MatchToSlotForm id={request.id} onClose={close} />}
      {open === 'withdrawIntakeRequest' && <WithdrawForm id={request.id} onClose={close} />}
      {open === 'closeAppointedIntakeRequest' && <CloseForm id={request.id} onClose={close} />}
    </Stack>
  )
}

type FormProps = { id: IntakeRequestId; onClose: () => void }

function RejectForm({ id, onClose }: FormProps) {
  const reject = useRejectSubmittedIntakeRequest()
  const [rejectionReason, setRejectionReason] = useState('')
  return (
    <FormModal
      useCase="rejectSubmittedIntakeRequest"
      onClose={onClose}
      submit={() => reject.mutateAsync({ id, body: { rejectionReason } })}
    >
      <TextField name="rejectionReason" value={rejectionReason} onChange={setRejectionReason} />
    </FormModal>
  )
}

function AcceptForm({ id, onClose }: FormProps) {
  const accept = useAcceptSubmittedIntakeRequest()
  const [healthcareServiceId, setHealthcareServiceId] = useState<HealthcareServiceId | null>(null)
  const [priority, setPriority] = useState<PriorityDraft | null>(null)
  // docs/decisions.md: triage sets the doctor requirement, defaulting to any doctor.
  const [doctorRequirement, setDoctorRequirement] = useState<DoctorRequirementDraft>({ type: 'anyDoctor' })

  const completePriorityValue = priority === null ? null : completePriority(priority)
  const completeRequirement = completeDoctorRequirement(doctorRequirement)
  const submit =
    healthcareServiceId === null || completePriorityValue === null || completeRequirement === null
      ? null
      : () =>
          accept.mutateAsync({
            id,
            body: { healthcareServiceId, priority: completePriorityValue, doctorRequirement: completeRequirement },
          })

  // docs/decisions.md: a specific doctor on an Emergency or Urgent request
  // makes it wait for that doctor; the triage form warns.
  const waitsForDoctor =
    doctorRequirement.type === 'specificDoctor' && (priority?.type === 'emergency' || priority?.type === 'urgent')

  return (
    <FormModal useCase="acceptSubmittedIntakeRequest" onClose={onClose} submit={submit}>
      <HealthcareServiceSelect name="healthcareServiceId" value={healthcareServiceId} onChange={setHealthcareServiceId} />
      <PriorityControl name="priority" value={priority} onChange={setPriority} />
      <DoctorRequirementControl name="doctorRequirement" value={doctorRequirement} onChange={setDoctorRequirement} />
      {waitsForDoctor && (
        <Alert color="gray" variant="light">
          <Text size="sm">
            This request will wait for that doctor, even if other doctors are free before its deadline.
          </Text>
        </Alert>
      )}
    </FormModal>
  )
}

function WithdrawForm({ id, onClose }: FormProps) {
  const withdraw = useWithdrawIntakeRequest()
  const [withdrawalNote, setWithdrawalNote] = useState('')
  return (
    <FormModal
      useCase="withdrawIntakeRequest"
      onClose={onClose}
      submit={() =>
        withdraw.mutateAsync({ id, body: withdrawalNote === '' ? {} : { withdrawalNote } })
      }
    >
      <TextField name="withdrawalNote" optional value={withdrawalNote} onChange={setWithdrawalNote} />
    </FormModal>
  )
}

function CloseForm({ id, onClose }: FormProps) {
  const close = useCloseAppointedIntakeRequest()
  const [closeReason, setCloseReason] = useState<CloseReasonDraft | null>(null)
  const complete = closeReason === null ? null : completeCloseReason(closeReason)
  return (
    <FormModal
      useCase="closeAppointedIntakeRequest"
      onClose={onClose}
      submit={complete === null ? null : () => close.mutateAsync({ id, body: { closeReason: complete } })}
    >
      <CloseReasonControl name="closeReason" value={closeReason} onChange={setCloseReason} />
    </FormModal>
  )
}

// slotId is an id: a select over the slots in the collection read that shows
// them (the doctor calendar), which takes a range.
function MatchToSlotForm({ id, onClose }: FormProps) {
  const match = useMatchAcceptedIntakeRequestToSlot()
  const week = useWeekRange()
  const calendar = useDoctorCalendar(week.range)
  const doctors = okDetail(useDoctors().data)
  const services = okDetail(useHealthcareServices().data)
  const [slotId, setSlotId] = useState<SlotId | null>(null)

  const nameOf = (entries: { id: string; name: string }[] | undefined, key: string) =>
    entries?.find((e) => e.id === key)?.name ?? key
  const slots = (okDetail(calendar.data) ?? []).flatMap((entry) => (entry.type === 'slot' ? [entry] : []))

  return (
    <FormModal
      useCase="matchAcceptedIntakeRequestToSlot"
      onClose={onClose}
      submit={slotId === null ? null : () => match.mutateAsync({ id, body: { slotId } })}
    >
      <WeekRangePicker week={week} />
      <Select
        label={humanize('slotId')}
        withAsterisk
        data={slots.map((s) => ({
          value: s.id,
          label: [
            nameOf(doctors, s.doctorId),
            nameOf(services, s.healthcareServiceId),
            formatTime(s.start),
            humanize(s.duration.type),
          ].join(' · '),
        }))}
        value={slotId}
        onChange={setSlotId}
        allowDeselect={false}
      />
    </FormModal>
  )
}
