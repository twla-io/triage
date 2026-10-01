import { useHealthcareServices } from '../api/queries/healthcareServices'
import { ActionButton } from '../components/actions'
import { CreateHealthcareServiceForm } from '../components/entityForms'
import { QueryView } from '../components/feedback'
import { actionLabel, humanize } from '../components/humanize'
import { Page, RecordCard, RecordList } from '../components/layout'
import { Fields, healthcareServiceRows } from '../components/values'

const create = actionLabel('CreateHealthcareService', 'HealthcareService')

export function HealthcareServicePage() {
  const services = useHealthcareServices()
  return (
    <Page
      title={humanize('HealthcareService')}
      actions={
        <ActionButton label={create}>
          {(done) => <CreateHealthcareServiceForm label={create} onDone={done} />}
        </ActionButton>
      }
    >
      <QueryView query={services}>
        {(answer) => (
          <RecordList>
            {answer.detail.map((service) => (
              <RecordCard key={service.id}>
                <Fields rows={healthcareServiceRows(service)} />
              </RecordCard>
            ))}
          </RecordList>
        )}
      </QueryView>
    </Page>
  )
}
