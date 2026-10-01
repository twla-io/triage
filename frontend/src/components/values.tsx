import type { ReactNode } from 'react'
import { Badge, Group, Stack, Text } from '@mantine/core'
import type { Schemas } from '../api/client'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import { usePatients } from '../api/queries/patients'
import { humanize } from './humanize'

export function formatTime(value: string): string {
  return new Date(value).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
}

export function Time({ value }: { value: string }) {
  return <>{formatTime(value)}</>
}

export function CaseBadge({ type }: { type: string }) {
  return (
    <Badge variant="light" color="gray" tt="none">
      {humanize(type)}
    </Badge>
  )
}

// IntakeRequestPriority is ranked: it is the first key of Domain's sortByPriority.
type Priority = Schemas['IntakeRequestPriority']

function rankColor(type: Priority['type']): string {
  switch (type) {
    case 'emergency':
      return 'red'
    case 'urgent':
      return 'orange'
    case 'routine':
      return 'green'
  }
}

export function PriorityBadge({ type }: { type: Priority['type'] }) {
  return (
    <Badge variant="light" color={rankColor(type)} tt="none">
      {humanize(type)}
    </Badge>
  )
}

export function DoctorName({ id }: { id: Schemas['DoctorId'] }) {
  const doctors = useDoctors()
  return <>{doctors.data?.detail.find((d) => d.id === id)?.name ?? id}</>
}

export function PatientName({ id }: { id: Schemas['PatientId'] }) {
  const patients = usePatients()
  return <>{patients.data?.detail.find((p) => p.id === id)?.name ?? id}</>
}

export function HealthcareServiceName({ id }: { id: Schemas['HealthcareServiceId'] }) {
  const services = useHealthcareServices()
  return <>{services.data?.detail.find((s) => s.id === id)?.name ?? id}</>
}

// A field shows under its humanized name; rows are listed in Domain.hs field order.
export type Row = { key: string; label: string; node: ReactNode }

export function field<T, K extends keyof T & string>(value: T, key: K, render: (value: T[K]) => ReactNode): Row {
  return { key, label: humanize(key), node: render(value[key]) }
}

export function Fields({ rows }: { rows: Row[] }) {
  return (
    <Stack gap={4}>
      {rows.map((row) => (
        <Group key={row.key} gap="xs" align="flex-start" wrap="nowrap">
          <Text size="sm" c="dimmed" style={{ minWidth: 140 }}>
            {row.label}
          </Text>
          <Text size="sm" component="div">
            {row.node}
          </Text>
        </Group>
      ))}
    </Stack>
  )
}

const text = (value: string) => value
const optionalText = (value: string | null) => value
const time = (value: string) => <Time value={value} />
const ownId = (value: string) => value
const doctor = (id: Schemas['DoctorId']) => <DoctorName id={id} />
const patient = (id: Schemas['PatientId']) => <PatientName id={id} />
const healthcareService = (id: Schemas['HealthcareServiceId']) => <HealthcareServiceName id={id} />
const enumeration = (value: { type: string }) => <CaseBadge type={value.type} />

function routineDueRows(value: Schemas['RoutineDue']): Row[] {
  switch (value.type) {
    case 'routineAnytime':
      return []
    case 'routineNotBefore':
      return [field(value, 'routineNotBefore', time)]
    case 'routineNotAfter':
      return [field(value, 'routineNotAfter', time)]
    case 'routineWithin':
      return [field(value, 'routineNotBefore', time), field(value, 'routineNotAfter', time)]
  }
}

function routineDue(value: Schemas['RoutineDue']): ReactNode {
  return (
    <Stack gap={4}>
      <Group>
        <CaseBadge type={value.type} />
      </Group>
      <Fields rows={routineDueRows(value)} />
    </Stack>
  )
}

function priorityRows(value: Priority): Row[] {
  switch (value.type) {
    case 'emergency':
      return [field(value, 'mustBeSeenBy', time)]
    case 'urgent':
      return [field(value, 'mustBeSeenBy', time)]
    case 'routine':
      return [field(value, 'routine', routineDue)]
  }
}

function priority(value: Priority): ReactNode {
  return (
    <Stack gap={4}>
      <Group>
        <PriorityBadge type={value.type} />
      </Group>
      <Fields rows={priorityRows(value)} />
    </Stack>
  )
}

function doctorRequirementRows(value: Schemas['DoctorRequirement']): Row[] {
  switch (value.type) {
    case 'anyDoctor':
      return []
    case 'specificDoctor':
      return [field(value, 'specificDoctor', doctor)]
  }
}

function doctorRequirement(value: Schemas['DoctorRequirement']): ReactNode {
  return (
    <Stack gap={4}>
      <Group>
        <CaseBadge type={value.type} />
      </Group>
      <Fields rows={doctorRequirementRows(value)} />
    </Stack>
  )
}

function closeReasonRows(value: Schemas['CloseReason']): Row[] {
  switch (value.type) {
    case 'completed':
      return []
    case 'cancelled':
      return [
        field(value, 'cancelledBy', enumeration),
        field(value, 'cancelledAt', time),
        field(value, 'cancellationNote', optionalText),
      ]
    case 'noShow':
      return [field(value, 'absentParty', enumeration)]
  }
}

function closeReason(value: Schemas['CloseReason']): ReactNode {
  return (
    <Stack gap={4}>
      <Group>
        <CaseBadge type={value.type} />
      </Group>
      <Fields rows={closeReasonRows(value)} />
    </Stack>
  )
}

export function doctorRows(value: Schemas['Doctor']): Row[] {
  return [field(value, 'id', ownId), field(value, 'name', text)]
}

export function patientRows(value: Schemas['Patient']): Row[] {
  return [field(value, 'id', ownId), field(value, 'name', text)]
}

export function healthcareServiceRows(value: Schemas['HealthcareService']): Row[] {
  return [field(value, 'id', ownId), field(value, 'name', text), field(value, 'duration', enumeration)]
}

export function availableSlotRows(value: Schemas['AvailableSlot']): Row[] {
  return [
    field(value, 'id', ownId),
    field(value, 'doctorId', doctor),
    field(value, 'healthcareServiceId', healthcareService),
    field(value, 'start', time),
    field(value, 'duration', enumeration),
  ]
}

function submittedRows(value: Schemas['SubmittedIntakeRequest']): Row[] {
  return [
    field(value, 'id', ownId),
    field(value, 'patientId', patient),
    field(value, 'narrative', text),
    field(value, 'createdAt', time),
  ]
}

function rejectedRows(value: Schemas['RejectedIntakeRequest']): Row[] {
  return [...submittedRows(value), field(value, 'rejectedAt', time), field(value, 'rejectionReason', text)]
}

function triagedRows(value: Schemas['TriagedIntakeRequest']): Row[] {
  return [
    ...submittedRows(value),
    field(value, 'healthcareServiceId', healthcareService),
    field(value, 'priority', priority),
    field(value, 'doctorRequirement', doctorRequirement),
    field(value, 'triagedAt', time),
  ]
}

export function appointedRows(value: Schemas['AppointedIntakeRequest']): Row[] {
  return [
    ...triagedRows(value),
    field(value, 'doctorId', doctor),
    field(value, 'start', time),
    field(value, 'duration', enumeration),
  ]
}

function withdrawnRows(value: Schemas['WithdrawnIntakeRequest']): Row[] {
  const withdrawal = [
    field(value, 'withdrawnFrom', enumeration),
    field(value, 'withdrawnAt', time),
    field(value, 'withdrawalNote', optionalText),
  ]
  // TypeScript can't narrow a union by a nested tag (withdrawnFrom.type); the
  // fromAccepted case is the one member that carries the triaged fields.
  return 'triagedAt' in value ? [...triagedRows(value), ...withdrawal] : [...submittedRows(value), ...withdrawal]
}

function staleRows(value: Schemas['StaleIntakeRequest']): Row[] {
  return [...triagedRows(value), field(value, 'staleAt', time)]
}

function closedRows(value: Schemas['ClosedIntakeRequest']): Row[] {
  return [...appointedRows(value), field(value, 'closeReason', closeReason)]
}

export function intakeRequestRows(request: Schemas['IntakeRequest']): Row[] {
  switch (request.type) {
    case 'submitted':
      return submittedRows(request)
    case 'rejected':
      return rejectedRows(request)
    case 'accepted':
      return triagedRows(request)
    case 'appointed':
      return appointedRows(request)
    case 'withdrawn':
      return withdrawnRows(request)
    case 'stale':
      return staleRows(request)
    case 'closed':
      return closedRows(request)
  }
}
