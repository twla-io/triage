import { Alert, Divider, List, Loader, Select, Stack, Title } from '@mantine/core'
import { useState } from 'react'

import { AddEntityForm } from '../components/AddEntityForm'
import { useCreateDoctor, useDoctors } from '../api/queries/doctors'
import { useCreatePatient, usePatients } from '../api/queries/patients'
import { DURATION_OPTIONS, useCreateHealthcareService, useHealthcareServices, type DurationType } from '../api/queries/services'
import { ApiError } from '../api/client'

function errorMessage(error: unknown): string {
  return error instanceof ApiError ? `${error.status}: ${error.message}` : String(error)
}

function DoctorsSection() {
  const { data: doctors, isLoading, error } = useDoctors()
  const createDoctor = useCreateDoctor()

  return (
    <Stack gap="xs">
      <Title order={3}>Doctors</Title>
      {isLoading && <Loader size="sm" />}
      {error && <Alert color="red">{errorMessage(error)}</Alert>}
      <List>
        {doctors?.map((doctor) => (
          <List.Item key={doctor.id}>{doctor.name}</List.Item>
        ))}
      </List>
      <AddEntityForm label="New doctor" onSubmit={(name) => createDoctor.mutate(name)} pending={createDoctor.isPending} />
      {createDoctor.error && <Alert color="red">{errorMessage(createDoctor.error)}</Alert>}
    </Stack>
  )
}

function PatientsSection() {
  const { data: patients, isLoading, error } = usePatients()
  const createPatient = useCreatePatient()

  return (
    <Stack gap="xs">
      <Title order={3}>Patients</Title>
      {isLoading && <Loader size="sm" />}
      {error && <Alert color="red">{errorMessage(error)}</Alert>}
      <List>
        {patients?.map((patient) => (
          <List.Item key={patient.id}>{patient.name}</List.Item>
        ))}
      </List>
      <AddEntityForm label="New patient" onSubmit={(name) => createPatient.mutate(name)} pending={createPatient.isPending} />
      {createPatient.error && <Alert color="red">{errorMessage(createPatient.error)}</Alert>}
    </Stack>
  )
}

function ServicesSection() {
  const { data: services, isLoading, error } = useHealthcareServices()
  const createService = useCreateHealthcareService()
  const [duration, setDuration] = useState<DurationType>('halfAnHour')

  return (
    <Stack gap="xs">
      <Title order={3}>Healthcare Services</Title>
      {isLoading && <Loader size="sm" />}
      {error && <Alert color="red">{errorMessage(error)}</Alert>}
      <List>
        {services?.map((service) => (
          <List.Item key={service.id}>
            {service.name} — {DURATION_OPTIONS.find((d) => d.value === service.duration.type)?.label}
          </List.Item>
        ))}
      </List>
      <AddEntityForm
        label="New service"
        onSubmit={(name) => createService.mutate({ name, duration })}
        pending={createService.isPending}
      >
        <Select
          label="Duration"
          data={DURATION_OPTIONS.map((d) => ({ value: d.value, label: d.label }))}
          value={duration}
          onChange={(value) => value && setDuration(value as DurationType)}
          allowDeselect={false}
        />
      </AddEntityForm>
      {createService.error && <Alert color="red">{errorMessage(createService.error)}</Alert>}
    </Stack>
  )
}

export function DirectoryPage() {
  return (
    <Stack gap="lg">
      <Title order={2}>Directory</Title>
      <DoctorsSection />
      <Divider />
      <PatientsSection />
      <Divider />
      <ServicesSection />
    </Stack>
  )
}
