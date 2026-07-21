import {
  Alert,
  Badge,
  Button,
  Divider,
  Group,
  Paper,
  Select,
  Stack,
  Text,
  Textarea,
  Title,
} from '@mantine/core'
import { DateTimePicker } from '@mantine/dates'
import dayjs from 'dayjs'
import { useMemo, useState } from 'react'

import { ApiError } from '../api/client'
import { usePatients } from '../api/queries/patients'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/services'
import { useAvailableSlots, type AvailableSlotDTO } from '../api/queries/slots'
import {
  useAcceptIntakeRequest,
  useClosedIntakeRequests,
  useIntakeWaitlist,
  useMarkIntakeRequestStale,
  useMatchIntakeRequest,
  useRejectIntakeRequest,
  useSubmitIntakeRequest,
  useSubmittedIntakeRequests,
  type IntakeRequestDTO,
  type IntakeRequestPriorityPayload,
  type RoutineDuePayload,
} from '../api/queries/intakeRequests'

function errorMessage(error: unknown): string {
  return error instanceof ApiError ? `${error.status}: ${error.message}` : String(error)
}

// Emergency = red, Urgent = amber, Routine = green -- the priority color
// convention this project's presentation materials already use
// (triage-ui-codegen skill).
function priorityColor(priority: IntakeRequestDTO['priority']): string {
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

function PriorityBadge({ priority }: { priority: IntakeRequestDTO['priority'] }) {
  if (!priority) return null
  return <Badge color={priorityColor(priority)}>{priority.type}</Badge>
}

// ── Submit form ──────────────────────────────────────────────────────────

function SubmitForm() {
  const { data: patients } = usePatients()
  const { data: doctors } = useDoctors()
  const submit = useSubmitIntakeRequest()

  const [patientId, setPatientId] = useState<string | null>(null)
  const [narrative, setNarrative] = useState('')
  const [needsSpecificDoctor, setNeedsSpecificDoctor] = useState(false)
  const [specificDoctorId, setSpecificDoctorId] = useState<string | null>(null)

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault()
    if (!patientId || !narrative.trim()) return
    if (needsSpecificDoctor && !specificDoctorId) return

    submit.mutate(
      {
        patientId,
        narrative: narrative.trim(),
        doctorRequirement: needsSpecificDoctor
          ? { type: 'specificDoctor', doctorId: specificDoctorId! }
          : { type: 'anyDoctor' },
      },
      {
        onSuccess: () => {
          setNarrative('')
          setPatientId(null)
          setNeedsSpecificDoctor(false)
          setSpecificDoctorId(null)
        },
      },
    )
  }

  return (
    <form onSubmit={handleSubmit}>
      <Stack maw={480}>
        <Select
          label="Patient"
          placeholder="Choose a patient"
          data={(patients ?? []).map((p) => ({ value: p.id, label: p.name }))}
          value={patientId}
          onChange={setPatientId}
          required
        />
        <Textarea
          label="Narrative"
          placeholder="What is the patient asking for?"
          value={narrative}
          onChange={(event) => setNarrative(event.currentTarget.value)}
          required
        />
        <Select
          label="Doctor requirement"
          data={[
            { value: 'any', label: 'Any doctor' },
            { value: 'specific', label: 'Specific doctor' },
          ]}
          value={needsSpecificDoctor ? 'specific' : 'any'}
          onChange={(value) => setNeedsSpecificDoctor(value === 'specific')}
          allowDeselect={false}
        />
        {needsSpecificDoctor && (
          <Select
            label="Doctor"
            placeholder="Choose a doctor"
            data={(doctors ?? []).map((d) => ({ value: d.id, label: d.name }))}
            value={specificDoctorId}
            onChange={setSpecificDoctorId}
            required
          />
        )}
        <Group>
          <Button type="submit" loading={submit.isPending}>
            Submit request
          </Button>
        </Group>
        {submit.error && <Alert color="red">{errorMessage(submit.error)}</Alert>}
      </Stack>
    </form>
  )
}

// ── Priority input (accept form's tier + due-date mode picker) ─────────────
// RoutineDue's four cases are a mode choice, not independent date fields --
// picking a mode reveals exactly the date input(s) it needs (per
// triage-ui-codegen skill).

type RoutineMode = RoutineDuePayload['type']

function PriorityInput({ onChange }: { onChange: (payload: IntakeRequestPriorityPayload | null) => void }) {
  const [tier, setTier] = useState<'emergency' | 'urgent' | 'routine'>('routine')
  const [due, setDue] = useState<Date | null>(null)
  const [routineMode, setRoutineMode] = useState<RoutineMode>('routineAnytime')
  const [routineFrom, setRoutineFrom] = useState<Date | null>(null)
  const [routineTo, setRoutineTo] = useState<Date | null>(null)

  const emit = (
    nextTier: typeof tier,
    nextDue: Date | null,
    nextMode: RoutineMode,
    nextFrom: Date | null,
    nextTo: Date | null,
  ) => {
    if (nextTier === 'emergency' || nextTier === 'urgent') {
      onChange(nextDue ? { type: nextTier, due: nextDue.toISOString() } : null)
      return
    }
    switch (nextMode) {
      case 'routineAnytime':
        onChange({ type: 'routine', due: { type: 'routineAnytime' } })
        return
      case 'routineNotBefore':
        onChange(nextFrom ? { type: 'routine', due: { type: 'routineNotBefore', from: nextFrom.toISOString() } } : null)
        return
      case 'routineNotAfter':
        onChange(nextTo ? { type: 'routine', due: { type: 'routineNotAfter', to: nextTo.toISOString() } } : null)
        return
      case 'routineWithin':
        onChange(
          nextFrom && nextTo
            ? { type: 'routine', due: { type: 'routineWithin', from: nextFrom.toISOString(), to: nextTo.toISOString() } }
            : null,
        )
    }
  }

  return (
    <Stack gap="xs">
      <Select
        label="Priority"
        data={[
          { value: 'emergency', label: 'Emergency' },
          { value: 'urgent', label: 'Urgent' },
          { value: 'routine', label: 'Routine' },
        ]}
        value={tier}
        onChange={(value) => {
          const nextTier = (value as typeof tier) ?? 'routine'
          setTier(nextTier)
          emit(nextTier, due, routineMode, routineFrom, routineTo)
        }}
        allowDeselect={false}
      />
      {(tier === 'emergency' || tier === 'urgent') && (
        <DateTimePicker
          label="Must be seen by"
          value={due}
          onChange={(value) => {
            setDue(value)
            emit(tier, value, routineMode, routineFrom, routineTo)
          }}
          required
        />
      )}
      {tier === 'routine' && (
        <>
          <Select
            label="Window"
            data={[
              { value: 'routineAnytime', label: 'Anytime' },
              { value: 'routineNotBefore', label: 'Not before' },
              { value: 'routineNotAfter', label: 'Not after' },
              { value: 'routineWithin', label: 'Within a range' },
            ]}
            value={routineMode}
            onChange={(value) => {
              const nextMode = (value as RoutineMode) ?? 'routineAnytime'
              setRoutineMode(nextMode)
              emit(tier, due, nextMode, routineFrom, routineTo)
            }}
            allowDeselect={false}
          />
          {(routineMode === 'routineNotBefore' || routineMode === 'routineWithin') && (
            <DateTimePicker
              label="From"
              value={routineFrom}
              onChange={(value) => {
                setRoutineFrom(value)
                emit(tier, due, routineMode, value, routineTo)
              }}
              required
            />
          )}
          {(routineMode === 'routineNotAfter' || routineMode === 'routineWithin') && (
            <DateTimePicker
              label="To"
              value={routineTo}
              onChange={(value) => {
                setRoutineTo(value)
                emit(tier, due, routineMode, routineFrom, value)
              }}
              required
            />
          )}
        </>
      )}
    </Stack>
  )
}

// ── Submitted list (accept / reject) ────────────────────────────────────

function AcceptForm({ request }: { request: IntakeRequestDTO }) {
  const { data: services } = useHealthcareServices()
  const accept = useAcceptIntakeRequest()
  const [healthcareServiceId, setHealthcareServiceId] = useState<string | null>(null)
  const [priority, setPriority] = useState<IntakeRequestPriorityPayload | null>(null)

  return (
    <Paper withBorder p="sm" mt="xs">
      <Stack gap="xs" maw={400}>
        <Select
          label="Healthcare service"
          placeholder="Choose a service"
          data={(services ?? []).map((s) => ({ value: s.id, label: s.name }))}
          value={healthcareServiceId}
          onChange={setHealthcareServiceId}
          required
        />
        <PriorityInput onChange={setPriority} />
        <Group>
          <Button
            size="xs"
            disabled={!healthcareServiceId || !priority}
            loading={accept.isPending}
            onClick={() => healthcareServiceId && priority && accept.mutate({ id: request.id, healthcareServiceId, priority })}
          >
            Confirm accept
          </Button>
        </Group>
        {accept.error && <Alert color="red">{errorMessage(accept.error)}</Alert>}
      </Stack>
    </Paper>
  )
}

function RejectForm({ request }: { request: IntakeRequestDTO }) {
  const reject = useRejectIntakeRequest()
  const [reason, setReason] = useState('')

  return (
    <Paper withBorder p="sm" mt="xs">
      <Group maw={400}>
        <Textarea
          label="Rejection reason"
          value={reason}
          onChange={(event) => setReason(event.currentTarget.value)}
          style={{ flex: 1 }}
          required
        />
        <Button
          size="xs"
          disabled={!reason.trim()}
          loading={reject.isPending}
          onClick={() => reject.mutate({ id: request.id, rejectionReason: reason.trim() })}
        >
          Confirm reject
        </Button>
      </Group>
      {reject.error && <Alert color="red">{errorMessage(reject.error)}</Alert>}
    </Paper>
  )
}

function SubmittedSection() {
  const { data: requests, isLoading, error } = useSubmittedIntakeRequests()
  const [openAction, setOpenAction] = useState<{ id: string; action: 'accept' | 'reject' } | null>(null)

  return (
    <Stack gap="xs">
      <Title order={3}>Submitted — needs triage</Title>
      {isLoading && <Text c="dimmed">Loading…</Text>}
      {error && <Alert color="red">{errorMessage(error)}</Alert>}
      {requests?.length === 0 && <Text c="dimmed">Nothing waiting on triage.</Text>}
      {requests?.map((request) => (
        <Paper key={request.id} withBorder p="sm">
          <Group justify="space-between">
            <Stack gap={2}>
              <Text fw={600}>{request.narrative}</Text>
              <Text size="sm" c="dimmed">
                {request.doctorRequirement.type === 'specificDoctor' ? 'Specific doctor requested' : 'Any doctor'} · submitted{' '}
                {dayjs(request.createdAt).format('MMM D, h:mm A')}
              </Text>
            </Stack>
            <Group>
              <Button
                size="xs"
                variant="light"
                onClick={() => setOpenAction({ id: request.id, action: 'accept' })}
              >
                Accept
              </Button>
              <Button
                size="xs"
                variant="light"
                color="red"
                onClick={() => setOpenAction({ id: request.id, action: 'reject' })}
              >
                Reject
              </Button>
            </Group>
          </Group>
          {openAction?.id === request.id && openAction.action === 'accept' && <AcceptForm request={request} />}
          {openAction?.id === request.id && openAction.action === 'reject' && <RejectForm request={request} />}
        </Paper>
      ))}
    </Stack>
  )
}

// ── Waitlist (match / mark-stale) ───────────────────────────────────────

function MatchForm({ request }: { request: IntakeRequestDTO }) {
  const range = useMemo(() => {
    const start = dayjs()
    return { start: start.toISOString(), end: start.add(30, 'day').toISOString() }
  }, [])
  const { data: slots } = useAvailableSlots(range)
  const match = useMatchIntakeRequest()
  const [slotId, setSlotId] = useState<string | null>(null)

  const selectedSlot: AvailableSlotDTO | undefined = slots?.find((s) => s.id === slotId)

  return (
    <Paper withBorder p="sm" mt="xs">
      <Group maw={480}>
        <Select
          label="Slot"
          placeholder="Choose an available slot"
          data={(slots ?? []).map((s) => ({
            value: s.id,
            label: `${dayjs(s.start).format('MMM D, h:mm A')} (${s.duration.type})`,
          }))}
          value={slotId}
          onChange={setSlotId}
          style={{ flex: 1 }}
        />
        <Button
          size="xs"
          mt={22}
          disabled={!selectedSlot}
          loading={match.isPending}
          onClick={() => selectedSlot && match.mutate({ id: request.id, slot: selectedSlot })}
        >
          Match
        </Button>
      </Group>
      {match.error && <Alert color="red">{errorMessage(match.error)}</Alert>}
      {match.data && match.data.outcome !== 'matched' && <Alert color="yellow">{match.data.outcome}</Alert>}
    </Paper>
  )
}

function WaitlistSection() {
  const { data: requests, isLoading, error } = useIntakeWaitlist()
  const markStale = useMarkIntakeRequestStale()
  const [openMatchId, setOpenMatchId] = useState<string | null>(null)

  return (
    <Stack gap="xs">
      <Title order={3}>Waitlist — sorted by priority</Title>
      {isLoading && <Text c="dimmed">Loading…</Text>}
      {error && <Alert color="red">{errorMessage(error)}</Alert>}
      {requests?.length === 0 && <Text c="dimmed">Waitlist is empty.</Text>}
      {requests?.map((request) => (
        <Paper key={request.id} withBorder p="sm">
          <Group justify="space-between">
            <Group>
              <PriorityBadge priority={request.priority} />
              <Text fw={600}>{request.narrative}</Text>
            </Group>
            <Group>
              <Button size="xs" variant="light" onClick={() => setOpenMatchId(request.id)}>
                Match to slot
              </Button>
              <Button
                size="xs"
                variant="light"
                color="gray"
                loading={markStale.isPending}
                onClick={() => markStale.mutate(request.id)}
              >
                Mark stale
              </Button>
            </Group>
          </Group>
          {openMatchId === request.id && <MatchForm request={request} />}
        </Paper>
      ))}
      {markStale.error && <Alert color="red">{errorMessage(markStale.error)}</Alert>}
    </Stack>
  )
}

// ── Closed (resolved, read-only) ────────────────────────────────────────

function ClosedSection() {
  const range = useMemo(() => {
    const end = dayjs()
    return { start: end.subtract(90, 'day').toISOString(), end: end.toISOString() }
  }, [])
  const { data: requests, isLoading, error } = useClosedIntakeRequests(range)

  return (
    <Stack gap="xs">
      <Title order={3}>Resolved — last 90 days</Title>
      {isLoading && <Text c="dimmed">Loading…</Text>}
      {error && <Alert color="red">{errorMessage(error)}</Alert>}
      {requests?.length === 0 && <Text c="dimmed">Nothing resolved in this range.</Text>}
      {requests?.map((request) => (
        <Paper key={request.id} withBorder p="sm">
          <Group justify="space-between">
            <Text fw={600}>{request.narrative}</Text>
            <Badge>{request.type}</Badge>
          </Group>
        </Paper>
      ))}
    </Stack>
  )
}

export function IntakeRequestsPage() {
  return (
    <Stack gap="lg">
      <Title order={2}>Intake Requests</Title>
      <SubmitForm />
      <Divider />
      <SubmittedSection />
      <Divider />
      <WaitlistSection />
      <Divider />
      <ClosedSection />
    </Stack>
  )
}
