import { Select, TextInput } from '@mantine/core'
import { DateTimePicker } from '@mantine/dates'
import dayjs from 'dayjs'
import type { Schemas } from '../api/client'
import { useDoctors } from '../api/queries/doctors'
import { useHealthcareServices } from '../api/queries/healthcareServices'
import { usePatients } from '../api/queries/patients'
import { humanize } from './humanize'
import { wireTime } from './time'

/** A select of a sum type's (or enumeration's) constructors, humanized. */
export function CaseSelect<T extends string>({
  label,
  cases,
  value,
  onChange,
}: {
  label: string
  cases: readonly T[]
  value: T | null
  onChange: (tag: T) => void
}) {
  return (
    <Select
      label={label}
      data={cases.map((c) => ({ value: c, label: humanize(c) }))}
      value={value}
      onChange={(v) => {
        const tag = cases.find((c) => c === v)
        if (tag !== undefined) onChange(tag)
      }}
      allowDeselect={false}
      withAsterisk
    />
  )
}

export interface IdOption {
  value: string
  label: string
}

/** A select over an entity's elements, by id. */
export function IdSelect({
  label,
  options,
  value,
  onChange,
}: {
  label: string
  options: IdOption[]
  value: string | null
  onChange: (id: string | null) => void
}) {
  return (
    <Select
      label={label}
      data={options}
      value={value}
      onChange={onChange}
      searchable
      allowDeselect={false}
      withAsterisk
    />
  )
}

interface IdControlProps {
  label: string
  value: string | null
  onChange: (id: string | null) => void
}

export function DoctorSelect(props: IdControlProps) {
  const answer = useDoctors().data
  const doctors: Schemas['Doctor'][] = answer?.outcome === 'ok' ? answer.detail : []
  return <IdSelect {...props} options={doctors.map((d) => ({ value: d.id, label: d.name }))} />
}

export function PatientSelect(props: IdControlProps) {
  const answer = usePatients().data
  const patients: Schemas['Patient'][] = answer?.outcome === 'ok' ? answer.detail : []
  return <IdSelect {...props} options={patients.map((p) => ({ value: p.id, label: p.name }))} />
}

export function HealthcareServiceSelect(props: IdControlProps) {
  const answer = useHealthcareServices().data
  const services: Schemas['HealthcareService'][] = answer?.outcome === 'ok' ? answer.detail : []
  return <IdSelect {...props} options={services.map((s) => ({ value: s.id, label: s.name }))} />
}

/** A `UTCTime`: picked in local time, held in the wire's string form. */
export function DateTimeControl({
  label,
  value,
  onChange,
}: {
  label: string
  value: string | null
  onChange: (time: string | null) => void
}) {
  return (
    <DateTimePicker
      label={label}
      value={value === null ? null : dayjs(value).toDate()}
      onChange={(d) => onChange(d === null ? null : wireTime(d))}
      valueFormat="YYYY-MM-DD HH:mm"
      withAsterisk
    />
  )
}

/** A `Text`. */
export function TextControl({
  label,
  description,
  value,
  onChange,
}: {
  label: string
  description?: string
  value: string
  onChange: (text: string) => void
}) {
  return (
    <TextInput
      label={label}
      description={description}
      value={value}
      onChange={(e) => onChange(e.currentTarget.value)}
      withAsterisk
    />
  )
}

/** A `Maybe Text`: the same control, optional; left empty it is absent. */
export function OptionalTextControl({
  label,
  value,
  onChange,
}: {
  label: string
  value: string | null
  onChange: (text: string | null) => void
}) {
  return (
    <TextInput
      label={label}
      value={value ?? ''}
      onChange={(e) => onChange(e.currentTarget.value === '' ? null : e.currentTarget.value)}
    />
  )
}
