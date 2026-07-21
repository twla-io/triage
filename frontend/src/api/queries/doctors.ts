import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'

export type DoctorDTO = Schemas['DoctorDTO']

export function useDoctors() {
  return useQuery({
    queryKey: ['doctors'],
    queryFn: () => get<DoctorDTO[]>('/doctors'),
  })
}

export function useCreateDoctor() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (name: string) => post<DoctorDTO>('/doctors', { name }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['doctors'] }),
  })
}
