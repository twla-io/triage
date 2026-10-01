import { useQuery } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function usePatients() {
  return useQuery({ queryKey: ['patients'], queryFn: () => get('/patients', undefined, undefined) })
}

export function useCreatePatient() {
  return useAnswerMutation((body: Schemas['CreatePatientRequest']) => post('/patients', undefined, body))
}
