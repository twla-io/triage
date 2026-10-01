import { post, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function useCreateAvailableSlot() {
  return useAnswerMutation((body: Schemas['CreateAvailableSlotRequest']) => post('/available-slots', undefined, body))
}

export function useMatchAvailableSlotByPriority() {
  return useAnswerMutation((slotId: Schemas['SlotId']) =>
    post('/available-slots/{slotId}/match-by-priority', { slotId }, undefined),
  )
}
