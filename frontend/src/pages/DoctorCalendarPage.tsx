import { useState } from 'react'
import type { Schemas } from '../api/client'
import { useDoctorCalendar } from '../api/queries/doctorCalendar'
import { currentWeek } from '../api/range'
import { ActionButton } from '../components/actions'
import { doctorCalendarEntryActions } from '../components/doctorCalendarEntryActions'
import { CreateAvailableSlotForm } from '../components/entityForms'
import { QueryView } from '../components/feedback'
import { actionLabel, humanize } from '../components/humanize'
import { Page, RecordCard, RecordList } from '../components/layout'
import { appointedRows, availableSlotRows, CaseBadge, Fields, type Row } from '../components/values'
import { WeekRange } from '../components/WeekRange'

// AvailableSlot has no collection read of its own: slots are shown, and created, here.
const create = actionLabel('CreateAvailableSlot', 'AvailableSlot')

function entryRows(entry: Schemas['DoctorCalendarEntry']): Row[] {
  switch (entry.type) {
    case 'slot':
      return availableSlotRows(entry)
    case 'appointment':
      return appointedRows(entry)
  }
}

export function DoctorCalendarPage() {
  const [week, setWeek] = useState(currentWeek)
  const calendar = useDoctorCalendar(week)
  return (
    <Page
      title={humanize('DoctorCalendar')}
      actions={
        <ActionButton label={create}>{(done) => <CreateAvailableSlotForm label={create} onDone={done} />}</ActionButton>
      }
    >
      <WeekRange week={week} onChange={setWeek} />
      <QueryView query={calendar}>
        {(answer) => (
          <RecordList>
            {answer.detail.map((entry) => (
              <RecordCard
                key={`${entry.type}:${entry.id}`}
                header={<CaseBadge type={entry.type} />}
                actions={doctorCalendarEntryActions(entry)}
              >
                <Fields rows={entryRows(entry)} />
              </RecordCard>
            ))}
          </RecordList>
        )}
      </QueryView>
    </Page>
  )
}
