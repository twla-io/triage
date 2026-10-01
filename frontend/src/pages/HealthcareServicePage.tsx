import { useState } from 'react'
import type { Schemas } from '../api/client'
import { useCreateHealthcareService, useHealthcareServices } from '../api/queries/healthcareServices'
import { ActionButton, ActionForm, PageHeader, QueryView } from '../components/actions'
import { TextControl } from '../components/controls'
import type { DraftRecord } from '../components/draft'
import { humanize } from '../components/humanize'
import { AnswerBanner } from '../components/outcome'
import { RecordList } from '../components/RecordList'
import { healthcareServiceFields } from '../components/recordFields'
import { DurationControl } from '../components/sumControls'
import { RecordCard } from '../components/values'

export function HealthcareServicePage() {
  const services = useHealthcareServices()
  return (
    <>
      <PageHeader
        title={humanize('HealthcareService')}
        action={
          <ActionButton label={humanize('create')} variant="filled">
            {(close) => <CreateHealthcareServiceForm onDone={close} />}
          </ActionButton>
        }
      />
      <QueryView query={services}>
        {(answer) =>
          answer.outcome === 'ok' ? (
            <RecordList
              items={answer.detail}
              keyOf={(s) => s.id}
              render={(s) => <RecordCard fields={healthcareServiceFields(s)} />}
            />
          ) : (
            <AnswerBanner answer={answer} entity="healthcareService" />
          )
        }
      </QueryView>
    </>
  )
}

function CreateHealthcareServiceForm({ onDone }: { onDone: () => void }) {
  const mutation = useCreateHealthcareService()
  const [draft, setDraft] = useState<DraftRecord<Schemas['CreateHealthcareServiceRequest']>>({
    name: '',
    duration: null,
  })
  const { name, duration } = draft
  return (
    <ActionForm
      label={humanize('create')}
      entity="healthcareService"
      mutation={mutation}
      variables={name !== null && duration !== null ? { name, duration } : null}
      isSuccess={(a) => a.outcome === 'ok'}
      onDone={onDone}
    >
      <TextControl label={humanize('name')} value={name ?? ''} onChange={(v) => setDraft({ ...draft, name: v })} />
      <DurationControl
        label={humanize('duration')}
        value={duration}
        onChange={(v) => setDraft({ ...draft, duration: v })}
      />
    </ActionForm>
  )
}
