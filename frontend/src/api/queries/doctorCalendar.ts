import { useQuery } from '@tanstack/react-query'
import { call } from '../client'
import type { Range } from '../range'

export function useDoctorCalendarEntries(range: Range) {
  return useQuery({
    queryKey: ['doctorCalendar', range.from, range.to],
    queryFn: () => call('get', '/doctor-calendar', { query: { from: range.from, to: range.to } }),
  })
}
