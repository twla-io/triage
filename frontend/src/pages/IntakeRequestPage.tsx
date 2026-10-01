import { useState } from 'react'
import type { Schemas } from '../api/client'
import {
  useAcceptedIntakeRequests,
  useAppointedIntakeRequests,
  useClosedIntakeRequests,
  useRejectedIntakeRequests,
  useStaleIntakeRequests,
  useSubmittedIntakeRequests,
  useWithdrawnIntakeRequests,
} from '../api/queries/intakeRequests'
import { currentWeek } from '../api/range'
import { ActionButton } from '../components/actions'
import { QueryView } from '../components/feedback'
import { actionLabel, humanize } from '../components/humanize'
import { intakeRequestActions } from '../components/intakeRequestActions'
import { SubmitIntakeRequestForm } from '../components/intakeRequestForms'
import { Page, RecordCard, RecordList, Section } from '../components/layout'
import { CaseBadge, Fields, intakeRequestRows } from '../components/values'
import { WeekRange } from '../components/WeekRange'

type IntakeRequest = Schemas['IntakeRequest']

const submit = actionLabel('SubmitIntakeRequest', 'IntakeRequest')

// A read by case returns the case's stage record; each element becomes that case's member of the sum.
const asSubmitted = (r: Schemas['SubmittedIntakeRequest']): Schemas['IntakeRequestSubmitted'] => ({ ...r, type: 'submitted' })
const asRejected = (r: Schemas['RejectedIntakeRequest']): Schemas['IntakeRequestRejected'] => ({ ...r, type: 'rejected' })
const asAccepted = (r: Schemas['TriagedIntakeRequest']): Schemas['IntakeRequestAccepted'] => ({ ...r, type: 'accepted' })
const asAppointed = (r: Schemas['AppointedIntakeRequest']): Schemas['IntakeRequestAppointed'] => ({ ...r, type: 'appointed' })
const asWithdrawn = (r: Schemas['WithdrawnIntakeRequest']): Schemas['IntakeRequestWithdrawn'] => ({ ...r, type: 'withdrawn' })
const asStale = (r: Schemas['StaleIntakeRequest']): Schemas['IntakeRequestStale'] => ({ ...r, type: 'stale' })
const asClosed = (r: Schemas['ClosedIntakeRequest']): Schemas['IntakeRequestClosed'] => ({ ...r, type: 'closed' })

function IntakeRequestList({ requests }: { requests: IntakeRequest[] }) {
  return (
    <RecordList>
      {requests.map((request) => (
        <RecordCard key={request.id} header={<CaseBadge type={request.type} />} actions={intakeRequestActions(request)}>
          <Fields rows={intakeRequestRows(request)} />
        </RecordCard>
      ))}
    </RecordList>
  )
}

function SubmittedSection() {
  const query = useSubmittedIntakeRequests()
  return (
    <Section title={humanize('Submitted')}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asSubmitted)} />}</QueryView>
    </Section>
  )
}

function RejectedSection() {
  const [week, setWeek] = useState(currentWeek)
  const query = useRejectedIntakeRequests(week)
  return (
    <Section title={humanize('Rejected')} controls={<WeekRange week={week} onChange={setWeek} />}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asRejected)} />}</QueryView>
    </Section>
  )
}

function AcceptedSection() {
  const query = useAcceptedIntakeRequests()
  return (
    <Section title={humanize('Accepted')}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asAccepted)} />}</QueryView>
    </Section>
  )
}

function AppointedSection() {
  const query = useAppointedIntakeRequests()
  return (
    <Section title={humanize('Appointed')}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asAppointed)} />}</QueryView>
    </Section>
  )
}

function WithdrawnSection() {
  const [week, setWeek] = useState(currentWeek)
  const query = useWithdrawnIntakeRequests(week)
  return (
    <Section title={humanize('Withdrawn')} controls={<WeekRange week={week} onChange={setWeek} />}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asWithdrawn)} />}</QueryView>
    </Section>
  )
}

function StaleSection() {
  const [week, setWeek] = useState(currentWeek)
  const query = useStaleIntakeRequests(week)
  return (
    <Section title={humanize('Stale')} controls={<WeekRange week={week} onChange={setWeek} />}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asStale)} />}</QueryView>
    </Section>
  )
}

function ClosedSection() {
  const [week, setWeek] = useState(currentWeek)
  const query = useClosedIntakeRequests(week)
  return (
    <Section title={humanize('Closed')} controls={<WeekRange week={week} onChange={setWeek} />}>
      <QueryView query={query}>{(answer) => <IntakeRequestList requests={answer.detail.map(asClosed)} />}</QueryView>
    </Section>
  )
}

// One section per case, in constructor order.
export function IntakeRequestPage() {
  return (
    <Page
      title={humanize('IntakeRequest')}
      actions={
        <ActionButton label={submit}>{(done) => <SubmitIntakeRequestForm label={submit} onDone={done} />}</ActionButton>
      }
    >
      <SubmittedSection />
      <RejectedSection />
      <AcceptedSection />
      <AppointedSection />
      <WithdrawnSection />
      <StaleSection />
      <ClosedSection />
    </Page>
  )
}
