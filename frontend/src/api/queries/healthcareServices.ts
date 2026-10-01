import { useQuery } from '@tanstack/react-query'
import { apiGet, apiPost } from '../client'
import {
  decodeCreateHealthcareServiceAnswer,
  decodeFetchHealthcareServicesAnswer,
  type CreateHealthcareServiceRequest,
} from '../wire'
import { useAnswerMutation } from './mutation'

export const useHealthcareServices = () =>
  useQuery({
    queryKey: ['healthcare-services'],
    queryFn: async () => decodeFetchHealthcareServicesAnswer(await apiGet('/healthcare-services')),
  })

export const useCreateHealthcareService = () =>
  useAnswerMutation(async (body: CreateHealthcareServiceRequest) =>
    decodeCreateHealthcareServiceAnswer(await apiPost('/healthcare-services', body)),
  )
