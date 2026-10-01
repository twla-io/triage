import { Select, TextInput } from '@mantine/core'
import { DateTimePicker } from '@mantine/dates'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import { usePatients } from '../api/queries/patients'
import {
  appointmentPartyTags,
  closeReasonTags,
  doctorRequirementTags,
  intakeRequestPriorityTags,
  routineDueTags,
  type AppointmentParty,
  type CloseReasonRequest,
  type DoctorId,
  type DoctorRequirement,
  type HealthcareServiceId,
  type IntakeRequestPriority,
  type PatientId,
  type RoutineDue,
} from '../api/wire'
import { humanize, toUtcTime } from './labels'
import { okDetail } from './outcome'

// ── Leaf controls (forms-follow-request-types) ─────────────────────────────

export function TextField({
  name,
  value,
  onChange,
  optional = false,
  description,
}: {
  name: string
  value: string
  onChange: (v: string) => void
  optional?: boolean
  description?: string
}) {
  return (
    <TextInput
      label={humanize(name)}
      withAsterisk={!optional}
      description={description}
      value={value}
      onChange={(e) => onChange(e.currentTarget.value)}
    />
  )
}

export function TimeField({
  name,
  value,
  onChange,
}: {
  name: string
  value: Date | null
  onChange: (v: Date | null) => void
}) {
  return (
    <DateTimePicker
      label={humanize(name)}
      withAsterisk
      value={value}
      onChange={onChange}
      valueFormat="YYYY-MM-DD HH:mm"
      clearable
    />
  )
}

// A select over a list of constructors (an enumeration, or a sum type's cases).
export function TagSelect<T extends string>({
  name,
  tags,
  value,
  onChange,
}: {
  name: string
  tags: readonly T[]
  value: T | null
  onChange: (v: T | null) => void
}) {
  return (
    <Select
      label={humanize(name)}
      withAsterisk
      data={tags.map((t) => ({ value: t, label: humanize(t) }))}
      value={value}
      onChange={(v) => onChange(tags.find((t) => t === v) ?? null)}
      allowDeselect={false}
    />
  )
}

function EntitySelect({
  name,
  entries,
  value,
  onChange,
}: {
  name: string
  entries: { id: string; name: string }[] | undefined
  value: string | null
  onChange: (v: string | null) => void
}) {
  return (
    <Select
      label={humanize(name)}
      withAsterisk
      searchable
      data={(entries ?? []).map((e) => ({ value: e.id, label: e.name }))}
      value={value}
      onChange={onChange}
      allowDeselect={false}
    />
  )
}

type IdSelect<Id> = { name: string; value: Id | null; onChange: (v: Id | null) => void }

export function DoctorSelect(props: IdSelect<DoctorId>) {
  const doctors = useDoctors()
  return <EntitySelect {...props} entries={okDetail(doctors.data)} />
}

export function PatientSelect(props: IdSelect<PatientId>) {
  const patients = usePatients()
  return <EntitySelect {...props} entries={okDetail(patients.data)} />
}

export function HealthcareServiceSelect(props: IdSelect<HealthcareServiceId>) {
  const services = useHealthcareServices()
  return <EntitySelect {...props} entries={okDetail(services.data)} />
}

// ── Sum-type controls: a select of constructors revealing the chosen case ──
//
// A draft mirrors the sum type, with leaves that may still be empty.

export type AppointmentPartyDraft = AppointmentParty | null

function partyOf(tag: AppointmentParty['type'] | null): AppointmentPartyDraft {
  switch (tag) {
    case null:
      return null
    case 'doctorParty':
      return { type: 'doctorParty' }
    case 'patientParty':
      return { type: 'patientParty' }
  }
}

export function AppointmentPartyControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: AppointmentPartyDraft
  onChange: (v: AppointmentPartyDraft) => void
}) {
  return (
    <TagSelect
      name={name}
      tags={appointmentPartyTags}
      value={value?.type ?? null}
      onChange={(t) => onChange(partyOf(t))}
    />
  )
}

// DoctorRequirement
export type DoctorRequirementDraft = { type: 'anyDoctor' } | { type: 'specificDoctor'; specificDoctor: DoctorId | null }

function emptyDoctorRequirement(tag: DoctorRequirement['type']): DoctorRequirementDraft {
  switch (tag) {
    case 'anyDoctor':
      return { type: 'anyDoctor' }
    case 'specificDoctor':
      return { type: 'specificDoctor', specificDoctor: null }
  }
}

export function completeDoctorRequirement(d: DoctorRequirementDraft): DoctorRequirement | null {
  switch (d.type) {
    case 'anyDoctor':
      return d
    case 'specificDoctor':
      return d.specificDoctor === null ? null : { type: 'specificDoctor', specificDoctor: d.specificDoctor }
  }
}

export function DoctorRequirementControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: DoctorRequirementDraft
  onChange: (v: DoctorRequirementDraft) => void
}) {
  return (
    <>
      <TagSelect
        name={name}
        tags={doctorRequirementTags}
        value={value.type}
        onChange={(t) => t !== null && onChange(emptyDoctorRequirement(t))}
      />
      {value.type === 'specificDoctor' && (
        <DoctorSelect
          name="specificDoctor"
          value={value.specificDoctor}
          onChange={(id) => onChange({ type: 'specificDoctor', specificDoctor: id })}
        />
      )}
    </>
  )
}

// RoutineDue
export type RoutineDueDraft =
  | { type: 'routineAnytime' }
  | { type: 'routineNotBefore'; routineNotBefore: Date | null }
  | { type: 'routineNotAfter'; routineNotAfter: Date | null }
  | { type: 'routineWithin'; routineNotBefore: Date | null; routineNotAfter: Date | null }

function emptyRoutineDue(tag: RoutineDue['type']): RoutineDueDraft {
  switch (tag) {
    case 'routineAnytime':
      return { type: 'routineAnytime' }
    case 'routineNotBefore':
      return { type: 'routineNotBefore', routineNotBefore: null }
    case 'routineNotAfter':
      return { type: 'routineNotAfter', routineNotAfter: null }
    case 'routineWithin':
      return { type: 'routineWithin', routineNotBefore: null, routineNotAfter: null }
  }
}

function completeRoutineDue(d: RoutineDueDraft): RoutineDue | null {
  switch (d.type) {
    case 'routineAnytime':
      return d
    case 'routineNotBefore':
      return d.routineNotBefore === null
        ? null
        : { type: 'routineNotBefore', routineNotBefore: toUtcTime(d.routineNotBefore) }
    case 'routineNotAfter':
      return d.routineNotAfter === null
        ? null
        : { type: 'routineNotAfter', routineNotAfter: toUtcTime(d.routineNotAfter) }
    case 'routineWithin':
      // RoutineWindow's rule (routineNotBefore <= routineNotAfter) is the
      // server's to check; it answers 400 naming the rule.
      return d.routineNotBefore === null || d.routineNotAfter === null
        ? null
        : {
            type: 'routineWithin',
            routineNotBefore: toUtcTime(d.routineNotBefore),
            routineNotAfter: toUtcTime(d.routineNotAfter),
          }
  }
}

function RoutineDueControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: RoutineDueDraft | null
  onChange: (v: RoutineDueDraft | null) => void
}) {
  return (
    <>
      <TagSelect
        name={name}
        tags={routineDueTags}
        value={value?.type ?? null}
        onChange={(t) => onChange(t === null ? null : emptyRoutineDue(t))}
      />
      {value?.type === 'routineNotBefore' && (
        <TimeField
          name="routineNotBefore"
          value={value.routineNotBefore}
          onChange={(v) => onChange({ ...value, routineNotBefore: v })}
        />
      )}
      {value?.type === 'routineNotAfter' && (
        <TimeField
          name="routineNotAfter"
          value={value.routineNotAfter}
          onChange={(v) => onChange({ ...value, routineNotAfter: v })}
        />
      )}
      {value?.type === 'routineWithin' && (
        <>
          <TimeField
            name="routineNotBefore"
            value={value.routineNotBefore}
            onChange={(v) => onChange({ ...value, routineNotBefore: v })}
          />
          <TimeField
            name="routineNotAfter"
            value={value.routineNotAfter}
            onChange={(v) => onChange({ ...value, routineNotAfter: v })}
          />
        </>
      )}
    </>
  )
}

// IntakeRequestPriority
export type PriorityDraft =
  | { type: 'emergency'; mustBeSeenBy: Date | null }
  | { type: 'urgent'; mustBeSeenBy: Date | null }
  | { type: 'routine'; routine: RoutineDueDraft | null }

function emptyPriority(tag: IntakeRequestPriority['type']): PriorityDraft {
  switch (tag) {
    case 'emergency':
      return { type: 'emergency', mustBeSeenBy: null }
    case 'urgent':
      return { type: 'urgent', mustBeSeenBy: null }
    case 'routine':
      return { type: 'routine', routine: null }
  }
}

export function completePriority(d: PriorityDraft): IntakeRequestPriority | null {
  switch (d.type) {
    case 'emergency':
      return d.mustBeSeenBy === null ? null : { type: 'emergency', mustBeSeenBy: toUtcTime(d.mustBeSeenBy) }
    case 'urgent':
      return d.mustBeSeenBy === null ? null : { type: 'urgent', mustBeSeenBy: toUtcTime(d.mustBeSeenBy) }
    case 'routine': {
      const routine = d.routine === null ? null : completeRoutineDue(d.routine)
      return routine === null ? null : { type: 'routine', routine }
    }
  }
}

export function PriorityControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: PriorityDraft | null
  onChange: (v: PriorityDraft | null) => void
}) {
  return (
    <>
      <TagSelect
        name={name}
        tags={intakeRequestPriorityTags}
        value={value?.type ?? null}
        onChange={(t) => onChange(t === null ? null : emptyPriority(t))}
      />
      {(value?.type === 'emergency' || value?.type === 'urgent') && (
        <TimeField
          name="mustBeSeenBy"
          value={value.mustBeSeenBy}
          onChange={(v) => onChange({ ...value, mustBeSeenBy: v })}
        />
      )}
      {value?.type === 'routine' && (
        <RoutineDueControl
          name="routine"
          value={value.routine}
          onChange={(routine) => onChange({ type: 'routine', routine })}
        />
      )}
    </>
  )
}

// CloseReason (request form)
export type CloseReasonDraft =
  | { type: 'completed' }
  | { type: 'cancelled'; cancelledBy: AppointmentPartyDraft; cancellationNote: string }
  | { type: 'noShow'; absentParty: AppointmentPartyDraft }

function emptyCloseReason(tag: CloseReasonRequest['type']): CloseReasonDraft {
  switch (tag) {
    case 'completed':
      return { type: 'completed' }
    case 'cancelled':
      return { type: 'cancelled', cancelledBy: null, cancellationNote: '' }
    case 'noShow':
      return { type: 'noShow', absentParty: null }
  }
}

export function completeCloseReason(d: CloseReasonDraft): CloseReasonRequest | null {
  switch (d.type) {
    case 'completed':
      return d
    case 'cancelled':
      return d.cancelledBy === null
        ? null
        : {
            type: 'cancelled',
            cancelledBy: d.cancelledBy,
            cancellationNote: d.cancellationNote === '' ? undefined : d.cancellationNote,
          }
    case 'noShow':
      return d.absentParty === null ? null : { type: 'noShow', absentParty: d.absentParty }
  }
}

export function CloseReasonControl({
  name,
  value,
  onChange,
}: {
  name: string
  value: CloseReasonDraft | null
  onChange: (v: CloseReasonDraft | null) => void
}) {
  return (
    <>
      <TagSelect
        name={name}
        tags={closeReasonTags}
        value={value?.type ?? null}
        onChange={(t) => onChange(t === null ? null : emptyCloseReason(t))}
      />
      {value?.type === 'cancelled' && (
        <>
          <AppointmentPartyControl
            name="cancelledBy"
            value={value.cancelledBy}
            onChange={(cancelledBy) => onChange({ ...value, cancelledBy })}
          />
          <TextField
            name="cancellationNote"
            optional
            value={value.cancellationNote}
            onChange={(cancellationNote) => onChange({ ...value, cancellationNote })}
          />
        </>
      )}
      {value?.type === 'noShow' && (
        <AppointmentPartyControl
          name="absentParty"
          value={value.absentParty}
          onChange={(absentParty) => onChange({ type: 'noShow', absentParty })}
        />
      )}
    </>
  )
}
