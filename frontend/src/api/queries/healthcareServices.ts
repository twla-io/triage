import { useQuery } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function useHealthcareServices() {
  return useQuery({
    queryKey: ['healthcare-services'],
    queryFn: () => get('/healthcare-services', undefined, undefined),
  })
}

export function useCreateHealthcareService() {
  return useAnswerMutation((body: Schemas['CreateHealthcareServiceRequest']) =>
    post('/healthcare-services', undefined, body),
  )
}
