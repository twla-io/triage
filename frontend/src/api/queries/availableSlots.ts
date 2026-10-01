import { call, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'

export function useCreateAvailableSlot() {
  return useAnswerMutation((body: Schemas['CreateAvailableSlotRequest']) => call('post', '/available-slots', { body }))
}

export function useMatchAvailableSlotByPriority() {
  return useAnswerMutation((slotId: Schemas['SlotId']) =>
    call('post', '/available-slots/{slotId}/match-by-priority', { path: { slotId } }),
  )
}
