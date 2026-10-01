import { useQuery } from '@tanstack/react-query'
import { apiGet, apiPost } from '../client'
import { decodeCreateDoctorAnswer, decodeFetchDoctorsAnswer, type CreateDoctorRequest } from '../wire'
import { useAnswerMutation } from './mutation'

export const useDoctors = () =>
  useQuery({
    queryKey: ['doctors'],
    queryFn: async () => decodeFetchDoctorsAnswer(await apiGet('/doctors')),
  })

export const useCreateDoctor = () =>
  useAnswerMutation(async (body: CreateDoctorRequest) => decodeCreateDoctorAnswer(await apiPost('/doctors', body)))
