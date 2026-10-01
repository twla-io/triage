import { useQuery } from '@tanstack/react-query'
import { call, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function useDoctors() {
  return useQuery({ queryKey: ['doctors'], queryFn: () => call('get', '/doctors', {}) })
}

export function useCreateDoctor() {
  return useAnswerMutation((body: Schemas['CreateDoctorRequest']) => call('post', '/doctors', { body }))
}
