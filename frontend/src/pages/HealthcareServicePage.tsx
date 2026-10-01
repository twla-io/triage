import { useState } from 'react'
import { Button, Stack } from '@mantine/core'
import { useCreateHealthcareService, useHealthcareServices } from '../api/queries/healthcareServices'
import { durationTags, type Duration } from '../api/wire'
import { TagSelect, TextField } from '../components/controls'
import { FormModal } from '../components/FormModal'
import { humanize } from '../components/labels'
import { ReadAnswer } from '../components/outcome'
import { PageHeader } from '../components/PageHeader'
import { RecordTable } from '../components/RecordTable'
import { GeneratedDurationValue, IdValue, TextValue } from '../components/values'

function CreateHealthcareServiceForm({ onClose }: { onClose: () => void }) {
  const create = useCreateHealthcareService()
  const [name, setName] = useState('')
  const [duration, setDuration] = useState<Duration | null>(null)
  return (
    <FormModal
      useCase="createHealthcareService"
      onClose={onClose}
      submit={duration === null ? null : () => create.mutateAsync({ name, duration })}
    >
      <TextField name="name" value={name} onChange={setName} />
      <TagSelect
        name="duration"
        tags={durationTags}
        value={duration?.type ?? null}
        onChange={(t) => setDuration(t === null ? null : { type: t })}
      />
    </FormModal>
  )
}

export function HealthcareServicePage() {
  const services = useHealthcareServices()
  const [creating, setCreating] = useState(false)
  return (
    <Stack>
      <PageHeader entity="healthcareService">
        <Button onClick={() => setCreating(true)}>{humanize('createHealthcareService')}</Button>
      </PageHeader>
      {creating && <CreateHealthcareServiceForm onClose={() => setCreating(false)} />}
      <ReadAnswer query={services}>
        {(rows) => (
          <RecordTable
            rows={rows}
            columns={[
              ['id', (s) => <IdValue id={s.id} />],
              ['name', (s) => <TextValue text={s.name} />],
              ['duration', (s) => <GeneratedDurationValue value={s.duration} />],
            ]}
          />
        )}
      </ReadAnswer>
    </Stack>
  )
}
