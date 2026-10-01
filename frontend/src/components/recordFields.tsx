import { Text } from '@mantine/core'
import type { Schemas } from '../api/client'
import {
  CaseBadge,
  CloseReasonValue,
  DoctorName,
  DoctorRequirementValue,
  DurationValue,
  field,
  HealthcareServiceName,
  PatientName,
  PriorityValue,
  TextValue,
  TimeValue,
  type Field,
} from './values'

// Each stage shows the stage it embeds, then its own fields, in Domain.hs order.

function IdValue({ value }: { value: string }) {
  return <Text size="sm" ff="monospace">{value}</Text>
}

export function doctorFields(r: Schemas['Doctor']): Field[] {
  return [field(r, 'id', <IdValue value={r.id} />), field(r, 'name', <TextValue value={r.name} />)]
}

export function patientFields(r: Schemas['Patient']): Field[] {
  return [field(r, 'id', <IdValue value={r.id} />), field(r, 'name', <TextValue value={r.name} />)]
}

export function healthcareServiceFields(r: Schemas['HealthcareService']): Field[] {
  return [
    field(r, 'id', <IdValue value={r.id} />),
    field(r, 'name', <TextValue value={r.name} />),
    field(r, 'duration', <DurationValue value={r.duration} />),
  ]
}

function submittedFields(r: Schemas['SubmittedIntakeRequest']): Field[] {
  return [
    field(r, 'id', <IdValue value={r.id} />),
    field(r, 'patientId', <PatientName id={r.patientId} />),
    field(r, 'narrative', <TextValue value={r.narrative} />),
    field(r, 'createdAt', <TimeValue value={r.createdAt} />),
  ]
}

function triagedFields(r: Schemas['TriagedIntakeRequest']): Field[] {
  return [
    ...submittedFields(r),
    field(r, 'healthcareServiceId', <HealthcareServiceName id={r.healthcareServiceId} />),
    field(r, 'priority', <PriorityValue value={r.priority} />),
    field(r, 'doctorRequirement', <DoctorRequirementValue value={r.doctorRequirement} />),
    field(r, 'triagedAt', <TimeValue value={r.triagedAt} />),
  ]
}

function appointedFields(r: Schemas['AppointedIntakeRequest']): Field[] {
  return [
    ...triagedFields(r),
    field(r, 'doctorId', <DoctorName id={r.doctorId} />),
    field(r, 'start', <TimeValue value={r.start} />),
    field(r, 'duration', <DurationValue value={r.duration} />),
  ]
}

function withdrawnFields(r: Schemas['WithdrawnIntakeRequest']): Field[] {
  const from = field(r, 'withdrawnFrom', <CaseBadge tag={r.withdrawnFrom.type} />)
  const own = [
    field(r, 'withdrawnAt', <TimeValue value={r.withdrawnAt} />),
    field(r, 'withdrawalNote', <TextValue value={r.withdrawalNote} />),
  ]
  // The wire flattens the embedded stage beside `withdrawnFrom`, whose tag
  // alone doesn't narrow the record; its fields do.
  const embedded = 'triagedAt' in r ? triagedFields(r) : submittedFields(r)
  return [from, ...embedded, ...own]
}

export function intakeRequestFields(r: Schemas['IntakeRequest']): Field[] {
  switch (r.type) {
    case 'submitted':
      return submittedFields(r)
    case 'rejected':
      return [
        ...submittedFields(r),
        field(r, 'rejectedAt', <TimeValue value={r.rejectedAt} />),
        field(r, 'rejectionReason', <TextValue value={r.rejectionReason} />),
      ]
    case 'accepted':
      return triagedFields(r)
    case 'appointed':
      return appointedFields(r)
    case 'withdrawn':
      return withdrawnFields(r)
    case 'stale':
      return [...triagedFields(r), field(r, 'staleAt', <TimeValue value={r.staleAt} />)]
    case 'closed':
      return [...appointedFields(r), field(r, 'closeReason', <CloseReasonValue value={r.closeReason} />)]
  }
}

export function availableSlotFields(r: Schemas['AvailableSlot']): Field[] {
  return [
    field(r, 'id', <IdValue value={r.id} />),
    field(r, 'doctorId', <DoctorName id={r.doctorId} />),
    field(r, 'healthcareServiceId', <HealthcareServiceName id={r.healthcareServiceId} />),
    field(r, 'start', <TimeValue value={r.start} />),
    field(r, 'duration', <DurationValue value={r.duration} />),
  ]
}

export function doctorCalendarEntryFields(e: Schemas['DoctorCalendarEntry']): Field[] {
  switch (e.type) {
    case 'slot':
      return availableSlotFields(e)
    case 'appointment':
      return appointedFields(e)
  }
}
