import { useState } from 'react'
import { Select, Stack, TextInput } from '@mantine/core'
import { DateTimePicker } from '@mantine/dates'
import type { Schemas } from '../api/client'
import { useDoctorCalendar } from '../api/queries/doctorCalendar'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import { usePatients } from '../api/queries/patients'
import { currentWeek } from '../api/range'
import { cases, type Draft } from './draft'
import { ErrorBanner } from './feedback'
import { humanize } from './humanize'
import { formatTime } from './values'
import { WeekRange } from './WeekRange'

// Every control is labelled by its field's name, humanized.

export function TextControl({
  name,
  value,
  onChange,
  description,
}: {
  name: string
  value: string
  onChange: (value: string) => void
  description?: string
}) {
  return (
    <TextInput
      label={humanize(name)}
      description={description}
      value={value}
      onChange={(event) => onChange(event.currentTarget.value)}
    />
  )
}

// A Maybe Text: the same control, optional; an empty input means null.
export function OptionalTextControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: string | null
  onChange: (value: string | null) => void
}) {
  return (
    <TextInput
      label={humanize(name)}
      value={value ?? ''}
      onChange={(event) => onChange(event.currentTarget.value === '' ? null : event.currentTarget.value)}
    />
  )
}

export function TimeControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: string | null
  onChange: (value: string | null) => void
}) {
  return (
    <DateTimePicker
      label={humanize(name)}
      required
      value={value === null ? null : new Date(value)}
      onChange={(date) => onChange(date === null ? null : date.toISOString())}
    />
  )
}

// A select over a fixed set of tags: an enumeration's constructors, or a sum type's cases.
export function ChoiceControl<T extends string>({
  name,
  choices,
  value,
  onChange,
}: {
  name: string
  choices: T[]
  value: T | null
  onChange: (value: T) => void
}) {
  return (
    <Select
      label={humanize(name)}
      required
      data={choices.map((choice) => ({ value: choice, label: humanize(choice) }))}
      value={value}
      onChange={(selected) => {
        const choice = choices.find((c) => c === selected)
        if (choice !== undefined) onChange(choice)
      }}
      allowDeselect={false}
    />
  )
}

type Option = { value: string; label: string }

function IdSelect({
  name,
  options,
  value,
  onChange,
  error,
}: {
  name: string
  options: Option[] | undefined
  value: string | null
  onChange: (value: string | null) => void
  error: Error | null
}) {
  return (
    <Stack gap={4}>
      <Select
        label={humanize(name)}
        required
        searchable
        data={options ?? []}
        value={value}
        onChange={onChange}
      />
      {error && <ErrorBanner error={error} />}
    </Stack>
  )
}

type IdControlProps = { name: string; value: string | null; onChange: (value: string | null) => void }

export function DoctorSelect(props: IdControlProps) {
  const doctors = useDoctors()
  const options = doctors.data?.detail.map((d) => ({ value: d.id, label: d.name }))
  return <IdSelect {...props} options={options} error={doctors.error} />
}

export function PatientSelect(props: IdControlProps) {
  const patients = usePatients()
  const options = patients.data?.detail.map((p) => ({ value: p.id, label: p.name }))
  return <IdSelect {...props} options={options} error={patients.error} />
}

export function HealthcareServiceSelect(props: IdControlProps) {
  const services = useHealthcareServices()
  const options = services.data?.detail.map((s) => ({ value: s.id, label: s.name }))
  return <IdSelect {...props} options={options} error={services.error} />
}

// A slot is an element of the sealed DoctorCalendar: a select over the calendar's
// read for a week, keeping only the slot case. A slot has no name, so an option is
// its non-ID fields, with IDs shown by name.
export function AvailableSlotSelect(props: IdControlProps) {
  const [week, setWeek] = useState(currentWeek)
  const calendar = useDoctorCalendar(week)
  const doctors = useDoctors()
  const services = useHealthcareServices()
  const doctorName = (id: string) => doctors.data?.detail.find((d) => d.id === id)?.name ?? id
  const serviceName = (id: string) => services.data?.detail.find((s) => s.id === id)?.name ?? id
  const options = calendar.data?.detail.flatMap((entry) => {
    switch (entry.type) {
      case 'slot':
        return [
          {
            value: entry.id,
            label: [
              doctorName(entry.doctorId),
              serviceName(entry.healthcareServiceId),
              formatTime(entry.start),
              humanize(entry.duration.type),
            ].join(' · '),
          },
        ]
      case 'appointment':
        return []
    }
  })
  return (
    <Stack gap={4}>
      <WeekRange
        week={week}
        onChange={(next) => {
          setWeek(next)
          props.onChange(null)
        }}
      />
      <IdSelect {...props} options={options} error={calendar.error} />
    </Stack>
  )
}

// ── Enumerations ──────────────────────────────────────────────────────────

export const durations = cases<Schemas['Duration']['type']>({
  quarterOfAnHour: 'quarterOfAnHour',
  halfAnHour: 'halfAnHour',
  oneHour: 'oneHour',
})

export const appointmentParties = cases<Schemas['AppointmentParty']['type']>({
  doctorParty: 'doctorParty',
  patientParty: 'patientParty',
})

// ── Sum types: a select of the cases that reveals exactly the chosen case's controls ──

type Priority = Schemas['IntakeRequestPriority']
type RoutineDue = Schemas['RoutineDue']
type DoctorRequirement = Schemas['DoctorRequirement']
type CloseReason = Schemas['CloseReasonRequest']

const priorityCases = cases<Priority['type']>({ emergency: 'emergency', urgent: 'urgent', routine: 'routine' })

function newPriority(type: Priority['type']): Draft<Priority> {
  switch (type) {
    case 'emergency':
      return { type, mustBeSeenBy: null }
    case 'urgent':
      return { type, mustBeSeenBy: null }
    case 'routine':
      return { type, routine: null }
  }
}

export function completePriority(draft: Draft<Priority>): Priority | null {
  switch (draft.type) {
    case 'emergency':
      return draft.mustBeSeenBy === null ? null : { type: draft.type, mustBeSeenBy: draft.mustBeSeenBy }
    case 'urgent':
      return draft.mustBeSeenBy === null ? null : { type: draft.type, mustBeSeenBy: draft.mustBeSeenBy }
    case 'routine': {
      const routine = draft.routine === null ? null : completeRoutineDue(draft.routine)
      return routine === null ? null : { type: draft.type, routine }
    }
  }
}

export function PriorityControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: Draft<Priority> | null
  onChange: (value: Draft<Priority>) => void
}) {
  return (
    <Stack gap="xs">
      <ChoiceControl
        name={name}
        choices={priorityCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(newPriority(type))}
      />
      {value !== null && <PriorityCaseControls value={value} onChange={onChange} />}
    </Stack>
  )
}

function PriorityCaseControls({
  value,
  onChange,
}: {
  value: Draft<Priority>
  onChange: (value: Draft<Priority>) => void
}) {
  switch (value.type) {
    case 'emergency':
      return (
        <TimeControl
          name="mustBeSeenBy"
          value={value.mustBeSeenBy}
          onChange={(mustBeSeenBy) => onChange({ ...value, mustBeSeenBy })}
        />
      )
    case 'urgent':
      return (
        <TimeControl
          name="mustBeSeenBy"
          value={value.mustBeSeenBy}
          onChange={(mustBeSeenBy) => onChange({ ...value, mustBeSeenBy })}
        />
      )
    case 'routine':
      return (
        <RoutineDueControl
          name="routine"
          value={value.routine}
          onChange={(routine) => onChange({ ...value, routine })}
        />
      )
  }
}

const routineDueCases = cases<RoutineDue['type']>({
  routineAnytime: 'routineAnytime',
  routineNotBefore: 'routineNotBefore',
  routineNotAfter: 'routineNotAfter',
  routineWithin: 'routineWithin',
})

function newRoutineDue(type: RoutineDue['type']): Draft<RoutineDue> {
  switch (type) {
    case 'routineAnytime':
      return { type }
    case 'routineNotBefore':
      return { type, routineNotBefore: null }
    case 'routineNotAfter':
      return { type, routineNotAfter: null }
    case 'routineWithin':
      return { type, routineNotBefore: null, routineNotAfter: null }
  }
}

function completeRoutineDue(draft: Draft<RoutineDue>): RoutineDue | null {
  switch (draft.type) {
    case 'routineAnytime':
      return { type: draft.type }
    case 'routineNotBefore':
      return draft.routineNotBefore === null ? null : { type: draft.type, routineNotBefore: draft.routineNotBefore }
    case 'routineNotAfter':
      return draft.routineNotAfter === null ? null : { type: draft.type, routineNotAfter: draft.routineNotAfter }
    case 'routineWithin':
      return draft.routineNotBefore === null || draft.routineNotAfter === null
        ? null
        : { type: draft.type, routineNotBefore: draft.routineNotBefore, routineNotAfter: draft.routineNotAfter }
  }
}

function RoutineDueControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: Draft<RoutineDue> | null
  onChange: (value: Draft<RoutineDue>) => void
}) {
  return (
    <Stack gap="xs">
      <ChoiceControl
        name={name}
        choices={routineDueCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(newRoutineDue(type))}
      />
      {value !== null && <RoutineDueCaseControls value={value} onChange={onChange} />}
    </Stack>
  )
}

function RoutineDueCaseControls({
  value,
  onChange,
}: {
  value: Draft<RoutineDue>
  onChange: (value: Draft<RoutineDue>) => void
}) {
  switch (value.type) {
    case 'routineAnytime':
      return null
    case 'routineNotBefore':
      return (
        <TimeControl
          name="routineNotBefore"
          value={value.routineNotBefore}
          onChange={(routineNotBefore) => onChange({ ...value, routineNotBefore })}
        />
      )
    case 'routineNotAfter':
      return (
        <TimeControl
          name="routineNotAfter"
          value={value.routineNotAfter}
          onChange={(routineNotAfter) => onChange({ ...value, routineNotAfter })}
        />
      )
    case 'routineWithin':
      return (
        <>
          <TimeControl
            name="routineNotBefore"
            value={value.routineNotBefore}
            onChange={(routineNotBefore) => onChange({ ...value, routineNotBefore })}
          />
          <TimeControl
            name="routineNotAfter"
            value={value.routineNotAfter}
            onChange={(routineNotAfter) => onChange({ ...value, routineNotAfter })}
          />
        </>
      )
  }
}

const doctorRequirementCases = cases<DoctorRequirement['type']>({
  anyDoctor: 'anyDoctor',
  specificDoctor: 'specificDoctor',
})

function newDoctorRequirement(type: DoctorRequirement['type']): Draft<DoctorRequirement> {
  switch (type) {
    case 'anyDoctor':
      return { type }
    case 'specificDoctor':
      return { type, specificDoctor: null }
  }
}

export function completeDoctorRequirement(draft: Draft<DoctorRequirement>): DoctorRequirement | null {
  switch (draft.type) {
    case 'anyDoctor':
      return { type: draft.type }
    case 'specificDoctor':
      return draft.specificDoctor === null ? null : { type: draft.type, specificDoctor: draft.specificDoctor }
  }
}

export function DoctorRequirementControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: Draft<DoctorRequirement> | null
  onChange: (value: Draft<DoctorRequirement>) => void
}) {
  return (
    <Stack gap="xs">
      <ChoiceControl
        name={name}
        choices={doctorRequirementCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(newDoctorRequirement(type))}
      />
      {value?.type === 'specificDoctor' && (
        <DoctorSelect
          name="specificDoctor"
          value={value.specificDoctor}
          onChange={(specificDoctor) => onChange({ ...value, specificDoctor })}
        />
      )}
    </Stack>
  )
}

const closeReasonCases = cases<CloseReason['type']>({ completed: 'completed', cancelled: 'cancelled', noShow: 'noShow' })

function newCloseReason(type: CloseReason['type']): Draft<CloseReason> {
  switch (type) {
    case 'completed':
      return { type }
    case 'cancelled':
      return { type, cancelledBy: null, cancellationNote: null }
    case 'noShow':
      return { type, absentParty: null }
  }
}

export function completeCloseReason(draft: Draft<CloseReason>): CloseReason | null {
  switch (draft.type) {
    case 'completed':
      return { type: draft.type }
    case 'cancelled':
      return draft.cancelledBy === null
        ? null
        : { type: draft.type, cancelledBy: draft.cancelledBy, cancellationNote: draft.cancellationNote }
    case 'noShow':
      return draft.absentParty === null ? null : { type: draft.type, absentParty: draft.absentParty }
  }
}

export function CloseReasonControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: Draft<CloseReason> | null
  onChange: (value: Draft<CloseReason>) => void
}) {
  return (
    <Stack gap="xs">
      <ChoiceControl
        name={name}
        choices={closeReasonCases}
        value={value?.type ?? null}
        onChange={(type) => onChange(newCloseReason(type))}
      />
      {value !== null && <CloseReasonCaseControls value={value} onChange={onChange} />}
    </Stack>
  )
}

function CloseReasonCaseControls({
  value,
  onChange,
}: {
  value: Draft<CloseReason>
  onChange: (value: Draft<CloseReason>) => void
}) {
  switch (value.type) {
    case 'completed':
      return null
    case 'cancelled':
      return (
        <>
          <ChoiceControl
            name="cancelledBy"
            choices={appointmentParties}
            value={value.cancelledBy?.type ?? null}
            onChange={(type) => onChange({ ...value, cancelledBy: { type } })}
          />
          <OptionalTextControl
            name="cancellationNote"
            value={value.cancellationNote}
            onChange={(cancellationNote) => onChange({ ...value, cancellationNote })}
          />
        </>
      )
    case 'noShow':
      return (
        <ChoiceControl
          name="absentParty"
          choices={appointmentParties}
          value={value.absentParty?.type ?? null}
          onChange={(type) => onChange({ ...value, absentParty: { type } })}
        />
      )
  }
}
