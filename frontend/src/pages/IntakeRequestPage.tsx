import { useState, type ReactNode } from 'react'
import { Stack } from '@mantine/core'
import type { Schemas } from '../api/client'
import {
  useAcceptedIntakeRequests,
  useAppointedIntakeRequests,
  useClosedIntakeRequests,
  useRejectedIntakeRequests,
  useStaleIntakeRequests,
  useSubmitIntakeRequest,
  useSubmittedIntakeRequests,
  useWithdrawnIntakeRequests,
} from '../api/queries/intakeRequests'
import { ActionButton, ActionForm, PageHeader, QueryView, SectionHeader } from '../components/actions'
import { PatientSelect, TextControl } from '../components/controls'
import { humanize } from '../components/humanize'
import { IntakeRequestActions } from '../components/intakeRequestActions'
import { AnswerBanner } from '../components/outcome'
import { RecordList } from '../components/RecordList'
import { intakeRequestFields } from '../components/recordFields'
import { RecordCard } from '../components/values'
import { useWeek, WeekRange, type Week } from '../components/WeekRange'

type IntakeRequest = Schemas['IntakeRequest']

const ENTITY = 'intakeRequest'

/** One section per case, in constructor order, each fed by that case's read. */
export function IntakeRequestPage() {
  return (
    <>
      <PageHeader
        title={humanize('IntakeRequest')}
        action={
          <ActionButton label={humanize('submit')} variant="filled">
            {(close) => <SubmitIntakeRequestForm onDone={close} />}
          </ActionButton>
        }
      />
      <Stack gap="xl">
        <SubmittedSection />
        <RejectedSection />
        <AcceptedSection />
        <AppointedSection />
        <WithdrawnSection />
        <StaleSection />
        <ClosedSection />
      </Stack>
    </>
  )
}

function Section({ tag, week, children }: { tag: IntakeRequest['type']; week?: Week; children: ReactNode }) {
  return (
    <section>
      <SectionHeader title={humanize(tag)} extra={week && <WeekRange week={week} />} />
      {children}
    </section>
  )
}

function IntakeRequestList({ requests }: { requests: IntakeRequest[] }) {
  return (
    <RecordList
      items={requests}
      keyOf={(r) => r.id}
      render={(r) => <RecordCard fields={intakeRequestFields(r)} actions={<IntakeRequestActions request={r} />} />}
    />
  )
}

// Each read returns its case's stage record; the section makes each element
// that case's member of IntakeRequest.

function SubmittedSection() {
  const query = useSubmittedIntakeRequests()
  const toCase = (r: Schemas['SubmittedIntakeRequest']): Schemas['IntakeRequestSubmitted'] => ({ ...r, type: 'submitted' })
  return (
    <Section tag="submitted">
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

function RejectedSection() {
  const week = useWeek()
  const query = useRejectedIntakeRequests(week.range)
  const toCase = (r: Schemas['RejectedIntakeRequest']): Schemas['IntakeRequestRejected'] => ({ ...r, type: 'rejected' })
  return (
    <Section tag="rejected" week={week}>
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

function AcceptedSection() {
  const query = useAcceptedIntakeRequests()
  const toCase = (r: Schemas['TriagedIntakeRequest']): Schemas['IntakeRequestAccepted'] => ({ ...r, type: 'accepted' })
  return (
    <Section tag="accepted">
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

function AppointedSection() {
  const query = useAppointedIntakeRequests()
  const toCase = (r: Schemas['AppointedIntakeRequest']): Schemas['IntakeRequestAppointed'] => ({ ...r, type: 'appointed' })
  return (
    <Section tag="appointed">
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

function WithdrawnSection() {
  const week = useWeek()
  const query = useWithdrawnIntakeRequests(week.range)
  const toCase = (r: Schemas['WithdrawnIntakeRequest']): Schemas['IntakeRequestWithdrawn'] => ({ ...r, type: 'withdrawn' })
  return (
    <Section tag="withdrawn" week={week}>
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

function StaleSection() {
  const week = useWeek()
  const query = useStaleIntakeRequests(week.range)
  const toCase = (r: Schemas['StaleIntakeRequest']): Schemas['IntakeRequestStale'] => ({ ...r, type: 'stale' })
  return (
    <Section tag="stale" week={week}>
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

function ClosedSection() {
  const week = useWeek()
  const query = useClosedIntakeRequests(week.range)
  const toCase = (r: Schemas['ClosedIntakeRequest']): Schemas['IntakeRequestClosed'] => ({ ...r, type: 'closed' })
  return (
    <Section tag="closed" week={week}>
      <QueryView query={query}>
        {(a) =>
          a.outcome === 'ok' ? <IntakeRequestList requests={a.detail.map(toCase)} /> : <AnswerBanner answer={a} entity={ENTITY} />
        }
      </QueryView>
    </Section>
  )
}

// docs/decisions.md, "The doctor requirement is decided at triage": the
// submit form's narrative prompt invites a preferred doctor.
const NARRATIVE_PROMPT = 'A preferred doctor, if any, can be named here.'

function SubmitIntakeRequestForm({ onDone }: { onDone: () => void }) {
  const mutation = useSubmitIntakeRequest()
  const [patientId, setPatientId] = useState<Schemas['PatientId'] | null>(null)
  const [narrative, setNarrative] = useState('')
  return (
    <ActionForm
      label={humanize('submit')}
      entity={ENTITY}
      mutation={mutation}
      variables={patientId === null ? null : { patientId, narrative }}
      isSuccess={(a) => a.outcome === 'ok'}
      onDone={onDone}
    >
      <PatientSelect label={humanize('patientId')} value={patientId} onChange={setPatientId} />
      <TextControl
        label={humanize('narrative')}
        description={NARRATIVE_PROMPT}
        value={narrative}
        onChange={setNarrative}
      />
    </ActionForm>
  )
}
