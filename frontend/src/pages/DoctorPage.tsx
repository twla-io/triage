import { useDoctors } from '../api/queries/doctors'
import { ActionButton } from '../components/actions'
import { CreateDoctorForm } from '../components/entityForms'
import { QueryView } from '../components/feedback'
import { actionLabel, humanize } from '../components/humanize'
import { Page, RecordCard, RecordList } from '../components/layout'
import { doctorRows, Fields } from '../components/values'

const create = actionLabel('CreateDoctor', 'Doctor')

export function DoctorPage() {
  const doctors = useDoctors()
  return (
    <Page
      title={humanize('Doctor')}
      actions={
        <ActionButton label={create}>{(done) => <CreateDoctorForm label={create} onDone={done} />}</ActionButton>
      }
    >
      <QueryView query={doctors}>
        {(answer) => (
          <RecordList>
            {answer.detail.map((doctor) => (
              <RecordCard key={doctor.id}>
                <Fields rows={doctorRows(doctor)} />
              </RecordCard>
            ))}
          </RecordList>
        )}
      </QueryView>
    </Page>
  )
}
