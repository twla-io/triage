import { useState } from 'react'
import { useCreateDoctor, useDoctors } from '../api/queries/doctors'
import { ActionButton, ActionForm, PageHeader, QueryView } from '../components/actions'
import { TextControl } from '../components/controls'
import { humanize } from '../components/humanize'
import { RecordList } from '../components/RecordList'
import { doctorFields } from '../components/recordFields'
import { RecordCard } from '../components/values'

export function DoctorPage() {
  const doctors = useDoctors()
  return (
    <>
      <PageHeader
        title={humanize('Doctor')}
        action={
          <ActionButton label={humanize('create')} variant="filled">
            {(close) => <CreateDoctorForm onDone={close} />}
          </ActionButton>
        }
      />
      <QueryView query={doctors}>
        {(answer) => (
          <RecordList items={answer.detail} keyOf={(d) => d.id} render={(d) => <RecordCard fields={doctorFields(d)} />} />
        )}
      </QueryView>
    </>
  )
}

function CreateDoctorForm({ onDone }: { onDone: () => void }) {
  const mutation = useCreateDoctor()
  const [name, setName] = useState('')
  return (
    <ActionForm
      label={humanize('create')}
      entity="doctor"
      mutation={mutation}
      variables={{ name }}
      isSuccess={(a) => a.outcome === 'ok'}
      onDone={onDone}
    >
      <TextControl label={humanize('name')} value={name} onChange={setName} />
    </ActionForm>
  )
}
