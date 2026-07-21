import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'

export type HealthcareServiceDTO = Schemas['HealthcareServiceDTO']
export type DurationDTO = Schemas['DurationDTO']
export type DurationType = DurationDTO['type']

export const DURATION_OPTIONS: { value: DurationType; label: string }[] = [
  { value: 'quarterOfAnHour', label: '15 minutes' },
  { value: 'halfAnHour', label: '30 minutes' },
  { value: 'oneHour', label: '1 hour' },
]

export function useHealthcareServices() {
  return useQuery({
    queryKey: ['healthcare-services'],
    queryFn: () => get<HealthcareServiceDTO[]>('/healthcare-services'),
  })
}

export function useCreateHealthcareService() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ name, duration }: { name: string; duration: DurationType }) =>
      post<HealthcareServiceDTO>('/healthcare-services', { name, duration: { type: duration } }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['healthcare-services'] }),
  })
}
