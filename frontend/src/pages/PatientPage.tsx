import { useState } from 'react'
import { Button, Stack } from '@mantine/core'
import { useCreatePatient, usePatients } from '../api/queries/patients'
import { TextField } from '../components/controls'
import { FormModal } from '../components/FormModal'
import { humanize } from '../components/labels'
import { ReadAnswer } from '../components/outcome'
import { PageHeader } from '../components/PageHeader'
import { RecordTable } from '../components/RecordTable'
import { IdValue, TextValue } from '../components/values'

function CreatePatientForm({ onClose }: { onClose: () => void }) {
  const create = useCreatePatient()
  const [name, setName] = useState('')
  return (
    <FormModal useCase="createPatient" onClose={onClose} submit={() => create.mutateAsync({ name })}>
      <TextField name="name" value={name} onChange={setName} />
    </FormModal>
  )
}

export function PatientPage() {
  const patients = usePatients()
  const [creating, setCreating] = useState(false)
  return (
    <Stack>
      <PageHeader entity="patient">
        <Button onClick={() => setCreating(true)}>{humanize('createPatient')}</Button>
      </PageHeader>
      {creating && <CreatePatientForm onClose={() => setCreating(false)} />}
      <ReadAnswer query={patients}>
        {(rows) => (
          <RecordTable
            rows={rows}
            columns={[
              ['id', (p) => <IdValue id={p.id} />],
              ['name', (p) => <TextValue text={p.name} />],
            ]}
          />
        )}
      </ReadAnswer>
    </Stack>
  )
}
