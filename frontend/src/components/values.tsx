import type { ReactNode } from 'react'
import { Badge, Group, Paper, Stack, Text } from '@mantine/core'
import type { Schemas } from '../api/client'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import { usePatients } from '../api/queries/patients'
import { humanize } from './humanize'
import { shownTime } from './time'

// ── Fields ──────────────────────────────────────────────────────────────────

export interface Field {
  label: string
  value: ReactNode
}

/** A field of `record`, labelled by its name humanized. */
export function field<T>(_record: T, name: Extract<keyof T, string>, value: ReactNode): Field {
  return { label: humanize(name), value }
}

export function FieldList({ fields }: { fields: Field[] }) {
  return (
    <Group gap="lg" align="flex-start">
      {fields.map((f) => (
        <Stack key={f.label} gap={2}>
          <Text size="xs" c="dimmed">
            {f.label}
          </Text>
          <div>{f.value}</div>
        </Stack>
      ))}
    </Group>
  )
}

/** One element of a list: an optional case heading, its fields, its actions. */
export function RecordCard({ heading, fields, actions }: { heading?: ReactNode; fields: Field[]; actions?: ReactNode }) {
  return (
    <Paper withBorder p="sm">
      <Group justify="space-between" align="flex-start" wrap="nowrap">
        <Stack gap="xs">
          {heading}
          <FieldList fields={fields} />
        </Stack>
        {actions}
      </Group>
    </Paper>
  )
}

// ── Plain values ────────────────────────────────────────────────────────────

export function TextValue({ value }: { value: string | null }) {
  return <Text size="sm" style={{ whiteSpace: 'pre-wrap' }}>{value ?? ''}</Text>
}

export function TimeValue({ value }: { value: string }) {
  return <Text size="sm">{shownTime(value)}</Text>
}

// ── IDs by name ────────────────────────────────────────────────────────────

/** Name lookups from the collection reads; an id not (yet) listed shows its own value. */
export function useNames() {
  const doctors = useDoctors().data
  const patients = usePatients().data
  const services = useHealthcareServices().data
  const doctorList = doctors?.outcome === 'ok' ? doctors.detail : []
  const patientList = patients?.outcome === 'ok' ? patients.detail : []
  const serviceList = services?.outcome === 'ok' ? services.detail : []
  return {
    doctor: (id: Schemas['DoctorId']) => doctorList.find((d) => d.id === id)?.name ?? id,
    patient: (id: Schemas['PatientId']) => patientList.find((p) => p.id === id)?.name ?? id,
    healthcareService: (id: Schemas['HealthcareServiceId']) => serviceList.find((s) => s.id === id)?.name ?? id,
    healthcareServiceRecord: (id: Schemas['HealthcareServiceId']) => serviceList.find((s) => s.id === id),
  }
}

export function DoctorName({ id }: { id: Schemas['DoctorId'] }) {
  return <Text size="sm">{useNames().doctor(id)}</Text>
}

export function PatientName({ id }: { id: Schemas['PatientId'] }) {
  return <Text size="sm">{useNames().patient(id)}</Text>
}

export function HealthcareServiceName({ id }: { id: Schemas['HealthcareServiceId'] }) {
  return <Text size="sm">{useNames().healthcareService(id)}</Text>
}

// ── Sum types ───────────────────────────────────────────────────────────────

/** A case of an unranked sum type: its constructor humanized, neutral. */
export function CaseBadge({ tag }: { tag: string }) {
  return (
    <Badge color="gray" variant="light" tt="none">
      {humanize(tag)}
    </Badge>
  )
}

type Priority = Schemas['IntakeRequestPriority']

/**
 * IntakeRequestPriority is ranked: it is the first key of sortByPriority.
 * First-ranked strongest (red), last calmest (green).
 */
function priorityRankColor(tag: Priority['type']): string {
  switch (tag) {
    case 'emergency':
      return 'red'
    case 'urgent':
      return 'orange'
    case 'routine':
      return 'green'
  }
}

function SubField({ name, children }: { name: string; children: ReactNode }) {
  return (
    <Group gap={6} wrap="nowrap">
      <Text size="xs" c="dimmed">
        {humanize(name)}
      </Text>
      {children}
    </Group>
  )
}

export function PriorityValue({ value }: { value: Priority }) {
  const badge = (
    <Badge color={priorityRankColor(value.type)} variant="light" tt="none">
      {humanize(value.type)}
    </Badge>
  )
  switch (value.type) {
    case 'emergency':
    case 'urgent':
      return (
        <Stack gap={4}>
          {badge}
          <SubField name="mustBeSeenBy">
            <TimeValue value={value.mustBeSeenBy} />
          </SubField>
        </Stack>
      )
    case 'routine':
      return (
        <Stack gap={4}>
          {badge}
          <RoutineDueValue value={value.routine} />
        </Stack>
      )
  }
}

export function RoutineDueValue({ value }: { value: Schemas['RoutineDue'] }) {
  const badge = <CaseBadge tag={value.type} />
  switch (value.type) {
    case 'routineAnytime':
      return badge
    case 'routineNotBefore':
      return (
        <Stack gap={4}>
          {badge}
          <SubField name="routineNotBefore">
            <TimeValue value={value.routineNotBefore} />
          </SubField>
        </Stack>
      )
    case 'routineNotAfter':
      return (
        <Stack gap={4}>
          {badge}
          <SubField name="routineNotAfter">
            <TimeValue value={value.routineNotAfter} />
          </SubField>
        </Stack>
      )
    case 'routineWithin':
      return (
        <Stack gap={4}>
          {badge}
          <SubField name="routineNotBefore">
            <TimeValue value={value.routineNotBefore} />
          </SubField>
          <SubField name="routineNotAfter">
            <TimeValue value={value.routineNotAfter} />
          </SubField>
        </Stack>
      )
  }
}

export function DoctorRequirementValue({ value }: { value: Schemas['DoctorRequirement'] }) {
  switch (value.type) {
    case 'anyDoctor':
      return <CaseBadge tag={value.type} />
    case 'specificDoctor':
      return (
        <Stack gap={4}>
          <CaseBadge tag={value.type} />
          <SubField name="specificDoctor">
            <DoctorName id={value.specificDoctor} />
          </SubField>
        </Stack>
      )
  }
}

export function DurationValue({ value }: { value: Schemas['Duration'] }) {
  return <CaseBadge tag={value.type} />
}

export function AppointmentPartyValue({ value }: { value: Schemas['AppointmentParty'] }) {
  return <CaseBadge tag={value.type} />
}

export function CloseReasonValue({ value }: { value: Schemas['CloseReason'] }) {
  switch (value.type) {
    case 'completed':
      return <CaseBadge tag={value.type} />
    case 'cancelled':
      return (
        <Stack gap={4}>
          <CaseBadge tag={value.type} />
          <SubField name="cancelledBy">
            <AppointmentPartyValue value={value.cancelledBy} />
          </SubField>
          <SubField name="cancelledAt">
            <TimeValue value={value.cancelledAt} />
          </SubField>
          <SubField name="cancellationNote">
            <TextValue value={value.cancellationNote} />
          </SubField>
        </Stack>
      )
    case 'noShow':
      return (
        <Stack gap={4}>
          <CaseBadge tag={value.type} />
          <SubField name="absentParty">
            <AppointmentPartyValue value={value.absentParty} />
          </SubField>
        </Stack>
      )
  }
}
