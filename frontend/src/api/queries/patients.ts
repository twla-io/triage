import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'

export type PatientDTO = Schemas['PatientDTO']

export function usePatients() {
  return useQuery({
    queryKey: ['patients'],
    queryFn: () => get<PatientDTO[]>('/patients'),
  })
}

export function useCreatePatient() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (name: string) => post<PatientDTO>('/patients', { name }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['patients'] }),
  })
}
