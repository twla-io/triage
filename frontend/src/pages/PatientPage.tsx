import { useState } from 'react'
import { useCreatePatient, usePatients } from '../api/queries/patients'
import { ActionButton, ActionForm, PageHeader, QueryView } from '../components/actions'
import { TextControl } from '../components/controls'
import { humanize } from '../components/humanize'
import { RecordList } from '../components/RecordList'
import { patientFields } from '../components/recordFields'
import { RecordCard } from '../components/values'

export function PatientPage() {
  const patients = usePatients()
  return (
    <>
      <PageHeader
        title={humanize('Patient')}
        action={
          <ActionButton label={humanize('create')} variant="filled">
            {(close) => <CreatePatientForm onDone={close} />}
          </ActionButton>
        }
      />
      <QueryView query={patients}>
        {(answer) => (
          <RecordList items={answer.detail} keyOf={(d) => d.id} render={(d) => <RecordCard fields={patientFields(d)} />} />
        )}
      </QueryView>
    </>
  )
}

function CreatePatientForm({ onDone }: { onDone: () => void }) {
  const mutation = useCreatePatient()
  const [name, setName] = useState('')
  return (
    <ActionForm
      label={humanize('create')}
      entity="patient"
      mutation={mutation}
      variables={{ name }}
      isSuccess={(a) => a.outcome === 'ok'}
      onDone={onDone}
    >
      <TextControl label={humanize('name')} value={name} onChange={setName} />
    </ActionForm>
  )
}
