import { useQuery } from '@tanstack/react-query'
import { get, toQuery, type Schemas } from '../client'

export type CalendarEntryDTO = Schemas['CalendarEntryDTO']

export interface CalendarRange {
  start: string
  end: string
  doctorId?: string
}

export function useCalendar(range: CalendarRange) {
  return useQuery({
    queryKey: ['calendar', range],
    queryFn: () =>
      get<CalendarEntryDTO[]>(
        `/calendar${toQuery({ start: range.start, end: range.end, doctorId: range.doctorId })}`,
      ),
  })
}
