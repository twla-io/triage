import { useQuery } from '@tanstack/react-query'
import { get } from '../client'
import { rangeQuery, type Week } from '../range'

export function useDoctorCalendar(week: Week) {
  const query = rangeQuery(week)
  return useQuery({
    queryKey: ['doctor-calendar', query.from, query.to],
    queryFn: () => get('/doctor-calendar', undefined, query),
  })
}
