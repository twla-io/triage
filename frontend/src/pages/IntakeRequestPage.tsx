import { useState } from 'react'
import { Button, Stack } from '@mantine/core'
import type { UseQueryResult } from '@tanstack/react-query'
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
import type { IntakeRequest, OkOrErrorAnswer, PatientId } from '../api/wire'
import { PatientSelect, TextField } from '../components/controls'
import { FormModal } from '../components/FormModal'
import { IntakeRequestCard } from '../components/IntakeRequestView'
import { humanize } from '../components/labels'
import { okDetail, ReadAnswer } from '../components/outcome'
import { PageHeader, SectionHeader } from '../components/PageHeader'
import { useWeekRange, WeekRangePicker, type WeekRange } from '../components/WeekRange'

function SubmitIntakeRequestForm({ onClose }: { onClose: () => void }) {
  const submit = useSubmitIntakeRequest()
  const [patientId, setPatientId] = useState<PatientId | null>(null)
  const [narrative, setNarrative] = useState('')
  return (
    <FormModal
      useCase="submitIntakeRequest"
      onClose={onClose}
      submit={patientId === null ? null : () => submit.mutateAsync({ patientId, narrative })}
    >
      <PatientSelect name="patientId" value={patientId} onChange={setPatientId} />
      {/* docs/decisions.md: a patient's preference of doctor goes into the
          narrative, and the narrative prompt invites one. */}
      <TextField
        name="narrative"
        value={narrative}
        onChange={setNarrative}
        description="A preferred doctor, if any, can be named here."
      />
    </FormModal>
  )
}

// One section per IntakeRequest case, fed by that case's read, in server order.
function CaseSection<R extends IntakeRequest>({
  name,
  query,
  week,
}: {
  name: IntakeRequest['type']
  query: UseQueryResult<OkOrErrorAnswer<R[]>>
  week?: WeekRange
}) {
  return (
    <Stack gap="xs">
      <SectionHeader name={name} count={okDetail(query.data)?.length}>
        {week && <WeekRangePicker week={week} />}
      </SectionHeader>
      <ReadAnswer query={query}>
        {(requests) => (
          <Stack gap="xs">
            {requests.map((r) => (
              <IntakeRequestCard key={r.id} request={r} />
            ))}
          </Stack>
        )}
      </ReadAnswer>
    </Stack>
  )
}

export function IntakeRequestPage() {
  const [submitting, setSubmitting] = useState(false)
  const rejectedWeek = useWeekRange()
  const withdrawnWeek = useWeekRange()
  const staleWeek = useWeekRange()
  const closedWeek = useWeekRange()

  const submitted = useSubmittedIntakeRequests()
  const rejected = useRejectedIntakeRequests(rejectedWeek.range)
  const accepted = useAcceptedIntakeRequests()
  const appointed = useAppointedIntakeRequests()
  const withdrawn = useWithdrawnIntakeRequests(withdrawnWeek.range)
  const stale = useStaleIntakeRequests(staleWeek.range)
  const closed = useClosedIntakeRequests(closedWeek.range)

  return (
    <Stack gap="xl">
      <PageHeader entity="intakeRequest">
        <Button onClick={() => setSubmitting(true)}>{humanize('submitIntakeRequest')}</Button>
      </PageHeader>
      {submitting && <SubmitIntakeRequestForm onClose={() => setSubmitting(false)} />}
      <CaseSection name="submitted" query={submitted} />
      <CaseSection name="rejected" query={rejected} week={rejectedWeek} />
      <CaseSection name="accepted" query={accepted} />
      <CaseSection name="appointed" query={appointed} />
      <CaseSection name="withdrawn" query={withdrawn} week={withdrawnWeek} />
      <CaseSection name="stale" query={stale} week={staleWeek} />
      <CaseSection name="closed" query={closed} week={closedWeek} />
    </Stack>
  )
}
