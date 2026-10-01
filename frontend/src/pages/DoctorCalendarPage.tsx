import { useState } from 'react'
import { Group, Stack } from '@mantine/core'
import type { Schemas } from '../api/client'
import { useCreateAvailableSlot } from '../api/queries/availableSlots'
import { useDoctorCalendarEntries } from '../api/queries/doctorCalendar'
import { ActionButton, ActionForm, PageHeader, QueryView } from '../components/actions'
import { DateTimeControl, DoctorSelect, HealthcareServiceSelect } from '../components/controls'
import { DoctorCalendarEntryActions } from '../components/doctorCalendarEntryActions'
import type { DraftRecord } from '../components/draft'
import { humanize } from '../components/humanize'
import { AnswerBanner } from '../components/outcome'
import { RecordList } from '../components/RecordList'
import { doctorCalendarEntryFields } from '../components/recordFields'
import { CaseBadge, DurationValue, FieldList, RecordCard, useNames } from '../components/values'
import { useWeek, WeekRange } from '../components/WeekRange'

/**
 * The sealed DoctorCalendar's page: its entries for a week, in the order the
 * read returns them, and the creation of AvailableSlot, whose elements are
 * shown only through this read.
 */
export function DoctorCalendarPage() {
  const week = useWeek()
  const entries = useDoctorCalendarEntries(week.range)
  return (
    <>
      <PageHeader
        title={humanize('DoctorCalendar')}
        action={
          <ActionButton label={humanize('create')} variant="filled">
            {(close) => <CreateAvailableSlotForm onDone={close} />}
          </ActionButton>
        }
      />
      <Stack gap="sm">
        <Group>
          <WeekRange week={week} />
        </Group>
        <QueryView query={entries}>
          {(a) =>
            a.outcome === 'ok' ? (
              <RecordList
                items={a.detail}
                keyOf={(e) => `${e.type}:${e.id}`}
                render={(e) => (
                  <RecordCard
                    heading={<CaseBadge tag={e.type} />}
                    fields={doctorCalendarEntryFields(e)}
                    actions={<DoctorCalendarEntryActions entry={e} />}
                  />
                )}
              />
            ) : (
              <AnswerBanner answer={a} entity="doctorCalendarEntry" />
            )
          }
        </QueryView>
      </Stack>
    </>
  )
}

function CreateAvailableSlotForm({ onDone }: { onDone: () => void }) {
  const mutation = useCreateAvailableSlot()
  const names = useNames()
  const [draft, setDraft] = useState<DraftRecord<Schemas['CreateAvailableSlotRequest']>>({
    doctorId: null,
    healthcareServiceId: null,
    start: null,
  })
  const { doctorId, healthcareServiceId, start } = draft
  // docs/decisions.md, "A slot's duration comes from its healthcare service":
  // the request has no duration; the UI shows the service's, read-only.
  const service = healthcareServiceId === null ? undefined : names.healthcareServiceRecord(healthcareServiceId)
  return (
    <ActionForm
      label={humanize('create')}
      entity="availableSlot"
      mutation={mutation}
      variables={
        doctorId !== null && healthcareServiceId !== null && start !== null
          ? { doctorId, healthcareServiceId, start }
          : null
      }
      isSuccess={(a) => a.outcome === 'availableSlotAdded'}
      onDone={onDone}
    >
      <DoctorSelect label={humanize('doctorId')} value={doctorId} onChange={(v) => setDraft({ ...draft, doctorId: v })} />
      <HealthcareServiceSelect
        label={humanize('healthcareServiceId')}
        value={healthcareServiceId}
        onChange={(v) => setDraft({ ...draft, healthcareServiceId: v })}
      />
      <DateTimeControl label={humanize('start')} value={start} onChange={(v) => setDraft({ ...draft, start: v })} />
      {service && <FieldList fields={[{ label: humanize('duration'), value: <DurationValue value={service.duration} /> }]} />}
    </ActionForm>
  )
}
