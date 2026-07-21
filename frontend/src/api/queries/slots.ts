import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, postEnveloped, toQuery, type Envelope, type Schemas } from '../client'
import type { DurationType } from './services'

export type AvailableSlotDTO = Schemas['AvailableSlotDTO']

export interface SlotRange {
  start: string
  end: string
  doctorId?: string
  healthcareServiceId?: string
}

export function useAvailableSlots(range: SlotRange) {
  return useQuery({
    queryKey: ['slots', range],
    queryFn: () =>
      get<AvailableSlotDTO[]>(
        `/slots${toQuery({
          start: range.start,
          end: range.end,
          doctorId: range.doctorId,
          healthcareServiceId: range.healthcareServiceId,
        })}`,
      ),
  })
}

export interface CreateSlotInput {
  doctorId: string
  healthcareServiceId: string
  start: string
  duration: DurationType
}

// outcome is "slotCreated" (detail: AvailableSlotDTO) or "slotConflict" (detail: null).
export function useCreateSlot() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateSlotInput) =>
      postEnveloped<AvailableSlotDTO>('/slots', {
        doctorId: input.doctorId,
        healthcareServiceId: input.healthcareServiceId,
        start: input.start,
        duration: { type: input.duration },
      }),
    onSuccess: (result: Envelope<AvailableSlotDTO>) => {
      if (result.outcome === 'slotCreated') {
        queryClient.invalidateQueries({ queryKey: ['slots'] })
        queryClient.invalidateQueries({ queryKey: ['calendar'] })
      }
    },
  })
}
