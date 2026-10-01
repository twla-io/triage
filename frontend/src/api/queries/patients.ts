import { useQuery } from '@tanstack/react-query'
import { apiGet, apiPost } from '../client'
import { decodeCreatePatientAnswer, decodeFetchPatientsAnswer, type CreatePatientRequest } from '../wire'
import { useAnswerMutation } from './mutation'

export const usePatients = () =>
  useQuery({
    queryKey: ['patients'],
    queryFn: async () => decodeFetchPatientsAnswer(await apiGet('/patients')),
  })

export const useCreatePatient = () =>
  useAnswerMutation(async (body: CreatePatientRequest) => decodeCreatePatientAnswer(await apiPost('/patients', body)))
