import { useQuery } from '@tanstack/react-query'
import { call, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function usePatients() {
  return useQuery({ queryKey: ['patients'], queryFn: () => call('get', '/patients', {}) })
}

export function useCreatePatient() {
  return useAnswerMutation((body: Schemas['CreatePatientRequest']) => call('post', '/patients', { body }))
}
