import { useState } from 'react'
import type { Schemas } from '../api/client'
import { useDoctorCalendar } from '../api/queries/doctorCalendar'
import { currentWeek } from '../api/range'
import { ActionButton } from '../components/actions'
import { doctorCalendarEntryActions } from '../components/doctorCalendarEntryActions'
import { CreateAvailableSlotForm } from '../components/entityForms'
import { QueryView } from '../components/feedback'
import { actionLabel, humanize } from '../components/humanize'
import { Page, RecordTable, Section } from '../components/layout'
import { appointedRows, availableSlotRows } from '../components/values'
import { WeekRange } from '../components/WeekRange'

// AvailableSlot has no collection read of its own: slots are shown, and created, here.
const create = actionLabel('CreateAvailableSlot', 'AvailableSlot')

// The calendar's one read, split by case; each part keeps the read's order.
function slotsOf(entries: Schemas['DoctorCalendarEntry'][]) {
  return entries.flatMap((entry) => {
    switch (entry.type) {
      case 'slot':
        return [entry]
      case 'appointment':
        return []
    }
  })
}

function appointmentsOf(entries: Schemas['DoctorCalendarEntry'][]) {
  return entries.flatMap((entry) => {
    switch (entry.type) {
      case 'slot':
        return []
      case 'appointment':
        return [entry]
    }
  })
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
        {(answer) => {
          const entries = answer.detail.doctorCalendarEntries
          return (
            <>
              <Section title={humanize('Slot')}>
                <RecordTable
                  records={slotsOf(entries)}
                  rowKey={(entry) => entry.id}
                  rows={availableSlotRows}
                  actions={doctorCalendarEntryActions}
                />
              </Section>
              <Section title={humanize('Appointment')}>
                <RecordTable
                  records={appointmentsOf(entries)}
                  rowKey={(entry) => entry.id}
                  rows={appointedRows}
                  actions={doctorCalendarEntryActions}
                />
              </Section>
            </>
          )
        }}
      </QueryView>
    </Page>
  )
}
