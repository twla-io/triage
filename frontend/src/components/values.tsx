import type { ReactNode } from 'react'
import { Badge, Group, Stack, Table, Text } from '@mantine/core'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import { usePatients } from '../api/queries/patients'
import {
  intakeRequestPriorityTags,
  narrowDuration,
  type AppointmentParty,
  type CloseReason,
  type DoctorId,
  type DoctorRequirement,
  type Duration,
  type HealthcareServiceId,
  type IntakeRequestPriority,
  type PatientId,
  type RoutineDue,
} from '../api/wire'
import { formatTime, humanize } from './labels'
import { okDetail } from './outcome'

// ── Field lists ────────────────────────────────────────────────────────────

export type Field = [name: string, value: ReactNode]

// A value's fields, each labelled by its Domain.hs name humanized.
export function Fields({ fields }: { fields: Field[] }) {
  return (
    <Table withRowBorders={false} verticalSpacing={2} horizontalSpacing="xs">
      <Table.Tbody>
        {fields.map(([name, value]) => (
          <Table.Tr key={name}>
            <Table.Td w={200} style={{ verticalAlign: 'top' }}>
              <Text size="sm" c="dimmed">
                {humanize(name)}
              </Text>
            </Table.Td>
            <Table.Td>{value}</Table.Td>
          </Table.Tr>
        ))}
      </Table.Tbody>
    </Table>
  )
}

export const TextValue = ({ text }: { text: string | undefined }) => (
  <Text size="sm" style={{ whiteSpace: 'pre-wrap' }}>
    {text ?? '—'}
  </Text>
)

export const TimeValue = ({ time }: { time: string }) => <Text size="sm">{formatTime(time)}</Text>

// ── Cases ──────────────────────────────────────────────────────────────────

// A case of an unranked sum type: its constructor humanized, neutral.
export const CaseBadge = ({ tag }: { tag: string }) => (
  <Badge color="gray" variant="light" tt="none">
    {humanize(tag)}
  </Badge>
)

// rank-is-the-only-color: IntakeRequestPriority's Ord instance (used by
// sortByPriority) ranks its constructors in constructor order, Emergency first.
// First-ranked red, last green, any middle ones in between.
function rankColor(rank: number, count: number): string {
  if (rank === 0) return 'red'
  if (rank === count - 1) return 'green'
  return 'orange'
}

export function PriorityBadge({ tag }: { tag: IntakeRequestPriority['type'] }) {
  const rank = intakeRequestPriorityTags.indexOf(tag)
  return (
    <Badge color={rankColor(rank, intakeRequestPriorityTags.length)} variant="light" tt="none">
      {humanize(tag)}
    </Badge>
  )
}

export function RoutineDueValue({ value }: { value: RoutineDue }) {
  switch (value.type) {
    case 'routineAnytime':
      return <CaseBadge tag={value.type} />
    case 'routineNotBefore':
      return (
        <Stack gap={2}>
          <CaseBadge tag={value.type} />
          <Fields fields={[['routineNotBefore', <TimeValue time={value.routineNotBefore} />]]} />
        </Stack>
      )
    case 'routineNotAfter':
      return (
        <Stack gap={2}>
          <CaseBadge tag={value.type} />
          <Fields fields={[['routineNotAfter', <TimeValue time={value.routineNotAfter} />]]} />
        </Stack>
      )
    case 'routineWithin':
      return (
        <Stack gap={2}>
          <CaseBadge tag={value.type} />
          <Fields
            fields={[
              ['routineNotBefore', <TimeValue time={value.routineNotBefore} />],
              ['routineNotAfter', <TimeValue time={value.routineNotAfter} />],
            ]}
          />
        </Stack>
      )
  }
}

export function PriorityValue({ value }: { value: IntakeRequestPriority }) {
  switch (value.type) {
    case 'emergency':
    case 'urgent':
      return (
        <Stack gap={2}>
          <Group>
            <PriorityBadge tag={value.type} />
          </Group>
          <Fields fields={[['mustBeSeenBy', <TimeValue time={value.mustBeSeenBy} />]]} />
        </Stack>
      )
    case 'routine':
      return (
        <Stack gap={2}>
          <Group>
            <PriorityBadge tag={value.type} />
          </Group>
          <Fields fields={[['routine', <RoutineDueValue value={value.routine} />]]} />
        </Stack>
      )
  }
}

export function DoctorRequirementValue({ value }: { value: DoctorRequirement }) {
  switch (value.type) {
    case 'anyDoctor':
      return <CaseBadge tag={value.type} />
    case 'specificDoctor':
      return (
        <Stack gap={2}>
          <Group>
            <CaseBadge tag={value.type} />
          </Group>
          <Fields fields={[['specificDoctor', <DoctorName id={value.specificDoctor} />]]} />
        </Stack>
      )
  }
}

export const DurationValue = ({ value }: { value: Duration }) => <CaseBadge tag={value.type} />

export const AppointmentPartyValue = ({ value }: { value: AppointmentParty }) => <CaseBadge tag={value.type} />

export function CloseReasonValue({ value }: { value: CloseReason }) {
  switch (value.type) {
    case 'completed':
      return <CaseBadge tag={value.type} />
    case 'cancelled':
      return (
        <Stack gap={2}>
          <Group>
            <CaseBadge tag={value.type} />
          </Group>
          <Fields
            fields={[
              ['cancelledBy', <AppointmentPartyValue value={value.cancelledBy} />],
              ['cancelledAt', <TimeValue time={value.cancelledAt} />],
              ['cancellationNote', <TextValue text={value.cancellationNote} />],
            ]}
          />
        </Stack>
      )
    case 'noShow':
      return (
        <Stack gap={2}>
          <Group>
            <CaseBadge tag={value.type} />
          </Group>
          <Fields fields={[['absentParty', <AppointmentPartyValue value={value.absentParty} />]]} />
        </Stack>
      )
  }
}

// ── Names of other entities (from their collection reads) ──────────────────

function NameOf({ id, entries }: { id: string; entries: { id: string; name: string }[] | undefined }) {
  const found = entries?.find((e) => e.id === id)
  return found ? (
    <Text size="sm">{found.name}</Text>
  ) : (
    <Text size="sm" c="dimmed" ff="monospace">
      {id}
    </Text>
  )
}

export function DoctorName({ id }: { id: DoctorId }) {
  const doctors = useDoctors()
  return <NameOf id={id} entries={okDetail(doctors.data)} />
}

export function PatientName({ id }: { id: PatientId }) {
  const patients = usePatients()
  return <NameOf id={id} entries={okDetail(patients.data)} />
}

export function HealthcareServiceName({ id }: { id: HealthcareServiceId }) {
  const services = useHealthcareServices()
  return <NameOf id={id} entries={okDetail(services.data)} />
}

export const IdValue = ({ id }: { id: string }) => (
  <Text size="sm" ff="monospace">
    {id}
  </Text>
)

// A generated record's Duration, narrowed for display.
export const GeneratedDurationValue = ({ value }: { value: Parameters<typeof narrowDuration>[0] }) => (
  <DurationValue value={narrowDuration(value)} />
)
