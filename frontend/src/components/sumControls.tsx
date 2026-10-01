import { Stack } from '@mantine/core'
import type { Schemas } from '../api/client'
import { CaseSelect, DateTimeControl, DoctorSelect, OptionalTextControl } from './controls'
import { allCases, type Draft } from './draft'
import { humanize } from './humanize'

// Each sum type gets a select of its constructors that reveals exactly the
// chosen case's controls, and a `complete…` that gives the wire value once
// every value of the chosen case is given (null until then).

type Cases<T extends { type: string }> = { [K in T['type']]: Draft<Extract<T, { type: K }>> }

interface ControlProps<T> {
  label: string
  value: T | null
  onChange: (value: T) => void
}

// ── Enumerations ────────────────────────────────────────────────────────────

type Duration = Schemas['Duration']
const durationCases = allCases<Duration['type']>()(['quarterOfAnHour', 'halfAnHour', 'oneHour'])

export function DurationControl({ label, value, onChange }: ControlProps<Duration>) {
  return (
    <CaseSelect label={label} cases={durationCases} value={value?.type ?? null} onChange={(type) => onChange({ type })} />
  )
}

type AppointmentParty = Schemas['AppointmentParty']
const appointmentPartyCases = allCases<AppointmentParty['type']>()(['doctorParty', 'patientParty'])

export function AppointmentPartyControl({ label, value, onChange }: ControlProps<AppointmentParty>) {
  return (
    <CaseSelect
      label={label}
      cases={appointmentPartyCases}
      value={value?.type ?? null}
      onChange={(type) => onChange({ type })}
    />
  )
}

// ── RoutineDue ──────────────────────────────────────────────────────────────

type RoutineDue = Schemas['RoutineDue']
const routineDueCases = allCases<RoutineDue['type']>()([
  'routineAnytime',
  'routineNotBefore',
  'routineNotAfter',
  'routineWithin',
])
const emptyRoutineDue: Cases<RoutineDue> = {
  routineAnytime: { type: 'routineAnytime' },
  routineNotBefore: { type: 'routineNotBefore', routineNotBefore: null },
  routineNotAfter: { type: 'routineNotAfter', routineNotAfter: null },
  routineWithin: { type: 'routineWithin', routineNotBefore: null, routineNotAfter: null },
}

export function RoutineDueControl({ label, value, onChange }: ControlProps<Draft<RoutineDue>>) {
  return (
    <Stack gap="xs">
      <CaseSelect
        label={label}
        cases={routineDueCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(value?.type === type ? value : emptyRoutineDue[type])}
      />
      {value && <RoutineDueCaseControls value={value} onChange={onChange} />}
    </Stack>
  )
}

function RoutineDueCaseControls({ value, onChange }: { value: Draft<RoutineDue>; onChange: (v: Draft<RoutineDue>) => void }) {
  switch (value.type) {
    case 'routineAnytime':
      return null
    case 'routineNotBefore':
      return (
        <DateTimeControl
          label={humanize('routineNotBefore')}
          value={value.routineNotBefore}
          onChange={(t) => onChange({ ...value, routineNotBefore: t })}
        />
      )
    case 'routineNotAfter':
      return (
        <DateTimeControl
          label={humanize('routineNotAfter')}
          value={value.routineNotAfter}
          onChange={(t) => onChange({ ...value, routineNotAfter: t })}
        />
      )
    case 'routineWithin':
      // routineNotBefore <= routineNotAfter is RoutineWindow's sealed rule:
      // the server checks it and refuses with 400; it isn't re-checked here.
      return (
        <>
          <DateTimeControl
            label={humanize('routineNotBefore')}
            value={value.routineNotBefore}
            onChange={(t) => onChange({ ...value, routineNotBefore: t })}
          />
          <DateTimeControl
            label={humanize('routineNotAfter')}
            value={value.routineNotAfter}
            onChange={(t) => onChange({ ...value, routineNotAfter: t })}
          />
        </>
      )
  }
}

export function completeRoutineDue(d: Draft<RoutineDue> | null): RoutineDue | null {
  if (d === null) return null
  switch (d.type) {
    case 'routineAnytime':
      return { type: 'routineAnytime' }
    case 'routineNotBefore':
      return d.routineNotBefore === null ? null : { type: 'routineNotBefore', routineNotBefore: d.routineNotBefore }
    case 'routineNotAfter':
      return d.routineNotAfter === null ? null : { type: 'routineNotAfter', routineNotAfter: d.routineNotAfter }
    case 'routineWithin':
      return d.routineNotBefore === null || d.routineNotAfter === null
        ? null
        : { type: 'routineWithin', routineNotBefore: d.routineNotBefore, routineNotAfter: d.routineNotAfter }
  }
}

// ── IntakeRequestPriority ───────────────────────────────────────────────────

type Priority = Schemas['IntakeRequestPriority']
const priorityCases = allCases<Priority['type']>()(['emergency', 'urgent', 'routine'])
const emptyPriority: Cases<Priority> = {
  emergency: { type: 'emergency', mustBeSeenBy: null },
  urgent: { type: 'urgent', mustBeSeenBy: null },
  routine: { type: 'routine', routine: null },
}

export function PriorityControl({ label, value, onChange }: ControlProps<Draft<Priority>>) {
  return (
    <Stack gap="xs">
      <CaseSelect
        label={label}
        cases={priorityCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(value?.type === type ? value : emptyPriority[type])}
      />
      {value && <PriorityCaseControls value={value} onChange={onChange} />}
    </Stack>
  )
}

function PriorityCaseControls({ value, onChange }: { value: Draft<Priority>; onChange: (v: Draft<Priority>) => void }) {
  switch (value.type) {
    case 'emergency':
    case 'urgent':
      return (
        <DateTimeControl
          label={humanize('mustBeSeenBy')}
          value={value.mustBeSeenBy}
          onChange={(t) => onChange({ ...value, mustBeSeenBy: t })}
        />
      )
    case 'routine':
      return (
        <RoutineDueControl
          label={humanize('routine')}
          value={value.routine}
          onChange={(routine) => onChange({ ...value, routine })}
        />
      )
  }
}

export function completePriority(d: Draft<Priority> | null): Priority | null {
  if (d === null) return null
  switch (d.type) {
    case 'emergency':
      return d.mustBeSeenBy === null ? null : { type: 'emergency', mustBeSeenBy: d.mustBeSeenBy }
    case 'urgent':
      return d.mustBeSeenBy === null ? null : { type: 'urgent', mustBeSeenBy: d.mustBeSeenBy }
    case 'routine': {
      const routine = completeRoutineDue(d.routine)
      return routine === null ? null : { type: 'routine', routine }
    }
  }
}

// ── DoctorRequirement ───────────────────────────────────────────────────────

type DoctorRequirement = Schemas['DoctorRequirement']
const doctorRequirementCases = allCases<DoctorRequirement['type']>()(['anyDoctor', 'specificDoctor'])
const emptyDoctorRequirement: Cases<DoctorRequirement> = {
  anyDoctor: { type: 'anyDoctor' },
  specificDoctor: { type: 'specificDoctor', specificDoctor: null },
}

export function DoctorRequirementControl({ label, value, onChange }: ControlProps<Draft<DoctorRequirement>>) {
  return (
    <Stack gap="xs">
      <CaseSelect
        label={label}
        cases={doctorRequirementCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(value?.type === type ? value : emptyDoctorRequirement[type])}
      />
      {value?.type === 'specificDoctor' && (
        <DoctorSelect
          label={humanize('specificDoctor')}
          value={value.specificDoctor}
          onChange={(specificDoctor) => onChange({ ...value, specificDoctor })}
        />
      )}
    </Stack>
  )
}

export function completeDoctorRequirement(d: Draft<DoctorRequirement> | null): DoctorRequirement | null {
  if (d === null) return null
  switch (d.type) {
    case 'anyDoctor':
      return { type: 'anyDoctor' }
    case 'specificDoctor':
      return d.specificDoctor === null ? null : { type: 'specificDoctor', specificDoctor: d.specificDoctor }
  }
}

// ── CloseReason (as the close request takes it) ─────────────────────────────

type CloseReasonRequest = Schemas['CloseReasonRequest']
const closeReasonCases = allCases<CloseReasonRequest['type']>()(['completed', 'cancelled', 'noShow'])
const emptyCloseReason: Cases<CloseReasonRequest> = {
  completed: { type: 'completed' },
  cancelled: { type: 'cancelled', cancelledBy: null, cancellationNote: null },
  noShow: { type: 'noShow', absentParty: null },
}

export function CloseReasonControl({ label, value, onChange }: ControlProps<Draft<CloseReasonRequest>>) {
  return (
    <Stack gap="xs">
      <CaseSelect
        label={label}
        cases={closeReasonCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(value?.type === type ? value : emptyCloseReason[type])}
      />
      {value && <CloseReasonCaseControls value={value} onChange={onChange} />}
    </Stack>
  )
}

function CloseReasonCaseControls({
  value,
  onChange,
}: {
  value: Draft<CloseReasonRequest>
  onChange: (v: Draft<CloseReasonRequest>) => void
}) {
  switch (value.type) {
    case 'completed':
      return null
    case 'cancelled':
      return (
        <>
          <AppointmentPartyControl
            label={humanize('cancelledBy')}
            value={value.cancelledBy}
            onChange={(cancelledBy) => onChange({ ...value, cancelledBy })}
          />
          <OptionalTextControl
            label={humanize('cancellationNote')}
            value={value.cancellationNote}
            onChange={(cancellationNote) => onChange({ ...value, cancellationNote })}
          />
        </>
      )
    case 'noShow':
      return (
        <AppointmentPartyControl
          label={humanize('absentParty')}
          value={value.absentParty}
          onChange={(absentParty) => onChange({ ...value, absentParty })}
        />
      )
  }
}

export function completeCloseReason(d: Draft<CloseReasonRequest> | null): CloseReasonRequest | null {
  if (d === null) return null
  switch (d.type) {
    case 'completed':
      return { type: 'completed' }
    case 'cancelled':
      return d.cancelledBy === null
        ? null
        : { type: 'cancelled', cancelledBy: d.cancelledBy, cancellationNote: d.cancellationNote }
    case 'noShow':
      return d.absentParty === null ? null : { type: 'noShow', absentParty: d.absentParty }
  }
}
