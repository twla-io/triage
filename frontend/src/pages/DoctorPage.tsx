import { useState } from 'react'
import { Button, Stack } from '@mantine/core'
import { useCreateDoctor, useDoctors } from '../api/queries/doctors'
import { TextField } from '../components/controls'
import { FormModal } from '../components/FormModal'
import { humanize } from '../components/labels'
import { ReadAnswer } from '../components/outcome'
import { PageHeader } from '../components/PageHeader'
import { RecordTable } from '../components/RecordTable'
import { IdValue, TextValue } from '../components/values'

function CreateDoctorForm({ onClose }: { onClose: () => void }) {
  const create = useCreateDoctor()
  const [name, setName] = useState('')
  return (
    <FormModal useCase="createDoctor" onClose={onClose} submit={() => create.mutateAsync({ name })}>
      <TextField name="name" value={name} onChange={setName} />
    </FormModal>
  )
}

export function DoctorPage() {
  const doctors = useDoctors()
  const [creating, setCreating] = useState(false)
  return (
    <Stack>
      <PageHeader entity="doctor">
        <Button onClick={() => setCreating(true)}>{humanize('createDoctor')}</Button>
      </PageHeader>
      {creating && <CreateDoctorForm onClose={() => setCreating(false)} />}
      <ReadAnswer query={doctors}>
        {(rows) => (
          <RecordTable
            rows={rows}
            columns={[
              ['id', (d) => <IdValue id={d.id} />],
              ['name', (d) => <TextValue text={d.name} />],
            ]}
          />
        )}
      </ReadAnswer>
    </Stack>
  )
}
