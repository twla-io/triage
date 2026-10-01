import { useState } from 'react'
import { TextInput } from '@mantine/core'
import type { Schemas } from '../api/client'
import { useCreateAvailableSlot, useMatchAvailableSlotByPriority } from '../api/queries/availableSlots'
import { useCreateDoctor } from '../api/queries/doctors'
import { useCreateHealthcareService, useHealthcareServices } from '../api/queries/healthcareServices'
import { useCreatePatient } from '../api/queries/patients'
import { AnswerForm } from './actions'
import { ChoiceControl, DoctorSelect, durations, HealthcareServiceSelect, TextControl, TimeControl } from './controls'
import { humanize } from './humanize'
import {
  describeCreateAvailableSlot,
  describeCreateDoctor,
  describeCreateHealthcareService,
  describeCreatePatient,
  describeMatchAvailableSlotByPriority,
} from './outcomes'

type FormProps = { label: string; onDone: () => void }

export function CreateDoctorForm({ label, onDone }: FormProps) {
  const [name, setName] = useState('')
  const mutation = useCreateDoctor()
  return (
    <AnswerForm label={label} mutation={mutation} variables={{ name }} describe={describeCreateDoctor} onDone={onDone}>
      <TextControl name="name" value={name} onChange={setName} />
    </AnswerForm>
  )
}

export function CreatePatientForm({ label, onDone }: FormProps) {
  const [name, setName] = useState('')
  const mutation = useCreatePatient()
  return (
    <AnswerForm label={label} mutation={mutation} variables={{ name }} describe={describeCreatePatient} onDone={onDone}>
      <TextControl name="name" value={name} onChange={setName} />
    </AnswerForm>
  )
}

export function CreateHealthcareServiceForm({ label, onDone }: FormProps) {
  const [name, setName] = useState('')
  const [duration, setDuration] = useState<Schemas['Duration'] | null>(null)
  const mutation = useCreateHealthcareService()
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={duration === null ? null : { name, duration }}
      describe={describeCreateHealthcareService}
      onDone={onDone}
    >
      <TextControl name="name" value={name} onChange={setName} />
      <ChoiceControl
        name="duration"
        choices={durations}
        value={duration?.type ?? null}
        onChange={(type) => setDuration({ type })}
      />
    </AnswerForm>
  )
}

export function CreateAvailableSlotForm({ label, onDone }: FormProps) {
  const [doctorId, setDoctorId] = useState<string | null>(null)
  const [healthcareServiceId, setHealthcareServiceId] = useState<string | null>(null)
  const [start, setStart] = useState<string | null>(null)
  const services = useHealthcareServices()
  const mutation = useCreateAvailableSlot()
  // Decision "A slot's duration comes from its healthcare service": the UI shows it read-only.
  const duration = services.data?.detail.find((s) => s.id === healthcareServiceId)?.duration
  const variables =
    doctorId === null || healthcareServiceId === null || start === null
      ? null
      : { doctorId, healthcareServiceId, start }
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={variables}
      describe={describeCreateAvailableSlot}
      onDone={onDone}
    >
      <DoctorSelect name="doctorId" value={doctorId} onChange={setDoctorId} />
      <HealthcareServiceSelect name="healthcareServiceId" value={healthcareServiceId} onChange={setHealthcareServiceId} />
      <TimeControl name="start" value={start} onChange={setStart} />
      <TextInput label={humanize('duration')} value={duration ? humanize(duration.type) : ''} readOnly disabled />
    </AnswerForm>
  )
}

export function MatchAvailableSlotByPriorityForm({
  slotId,
  label,
  onDone,
}: FormProps & { slotId: Schemas['SlotId'] }) {
  const mutation = useMatchAvailableSlotByPriority()
  return (
    <AnswerForm
      label={label}
      mutation={mutation}
      variables={slotId}
      describe={describeMatchAvailableSlotByPriority}
      onDone={onDone}
    />
  )
}
