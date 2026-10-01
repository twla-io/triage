import { usePatients } from '../api/queries/patients'
import { ActionButton } from '../components/actions'
import { CreatePatientForm } from '../components/entityForms'
import { QueryView } from '../components/feedback'
import { actionLabel, humanize } from '../components/humanize'
import { Page, RecordCard, RecordList } from '../components/layout'
import { Fields, patientRows } from '../components/values'

const create = actionLabel('CreatePatient', 'Patient')

export function PatientPage() {
  const patients = usePatients()
  return (
    <Page
      title={humanize('Patient')}
      actions={
        <ActionButton label={create}>{(done) => <CreatePatientForm label={create} onDone={done} />}</ActionButton>
      }
    >
      <QueryView query={patients}>
        {(answer) => (
          <RecordList>
            {answer.detail.map((patient) => (
              <RecordCard key={patient.id}>
                <Fields rows={patientRows(patient)} />
              </RecordCard>
            ))}
          </RecordList>
        )}
      </QueryView>
    </Page>
  )
}
