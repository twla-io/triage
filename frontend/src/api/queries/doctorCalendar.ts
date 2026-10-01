import { useQuery } from '@tanstack/react-query'
import { apiGet } from '../client'
import { decodeFetchDoctorCalendarEntriesAnswer } from '../wire'
import type { TimeRange } from './mutation'

export const useDoctorCalendar = (range: TimeRange) =>
  useQuery({
    queryKey: ['doctor-calendar', range.from, range.to],
    queryFn: async () => decodeFetchDoctorCalendarEntriesAnswer(await apiGet('/doctor-calendar', { ...range })),
  })
