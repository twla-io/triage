import { useQuery } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function useDoctors() {
  return useQuery({ queryKey: ['doctors'], queryFn: () => get('/doctors', undefined, undefined) })
}

export function useCreateDoctor() {
  return useAnswerMutation((body: Schemas['CreateDoctorRequest']) => post('/doctors', undefined, body))
}
