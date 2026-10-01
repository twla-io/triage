import { useQuery } from '@tanstack/react-query'
import { call, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function useHealthcareServices() {
  return useQuery({ queryKey: ['healthcareServices'], queryFn: () => call('get', '/healthcare-services', {}) })
}

export function useCreateHealthcareService() {
  return useAnswerMutation((body: Schemas['CreateHealthcareServiceRequest']) =>
    call('post', '/healthcare-services', { body }),
  )
}
