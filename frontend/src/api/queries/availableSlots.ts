import { apiPost } from '../client'
import {
  decodeCreateAvailableSlotAnswer,
  decodeMatchAvailableSlotByPriorityAnswer,
  type CreateAvailableSlotRequest,
  type SlotId,
} from '../wire'
import { useAnswerMutation } from './mutation'

export const useCreateAvailableSlot = () =>
  useAnswerMutation(async (body: CreateAvailableSlotRequest) =>
    decodeCreateAvailableSlotAnswer(await apiPost('/available-slots', body)),
  )

export const useMatchAvailableSlotByPriority = () =>
  useAnswerMutation(async (slotId: SlotId) =>
    decodeMatchAvailableSlotByPriorityAnswer(
      await apiPost(`/available-slots/${encodeURIComponent(slotId)}/match-by-priority`),
    ),
  )
