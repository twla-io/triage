import { useQuery } from '@tanstack/react-query'
import { apiGet, apiPost } from '../client'
import {
  decodeAcceptSubmittedIntakeRequestAnswer,
  decodeCloseAppointedIntakeRequestAnswer,
  decodeFetchAcceptedIntakeRequestsAnswer,
  decodeFetchAppointedIntakeRequestsAnswer,
  decodeFetchClosedIntakeRequestsAnswer,
  decodeFetchRejectedIntakeRequestsAnswer,
  decodeFetchStaleIntakeRequestsAnswer,
  decodeFetchSubmittedIntakeRequestsAnswer,
  decodeFetchWithdrawnIntakeRequestsAnswer,
  decodeMarkAcceptedIntakeRequestStaleAnswer,
  decodeMatchAcceptedIntakeRequestToSlotAnswer,
  decodeRejectSubmittedIntakeRequestAnswer,
  decodeSubmitIntakeRequestAnswer,
  decodeWithdrawIntakeRequestAnswer,
  type AcceptSubmittedIntakeRequestRequest,
  type CloseAppointedIntakeRequestRequest,
  type IntakeRequestId,
  type MatchAcceptedIntakeRequestToSlotRequest,
  type RejectSubmittedIntakeRequestRequest,
  type SubmitIntakeRequestRequest,
  type WithdrawIntakeRequestRequest,
} from '../wire'
import { useAnswerMutation, type TimeRange } from './mutation'

const base = '/intake-requests'
const one = (id: IntakeRequestId, action: string) => `${base}/${encodeURIComponent(id)}/${action}`

// ── Reads: one per IntakeRequest case ──────────────────────────────────────

export const useSubmittedIntakeRequests = () =>
  useQuery({
    queryKey: ['intake-requests', 'submitted'],
    queryFn: async () => decodeFetchSubmittedIntakeRequestsAnswer(await apiGet(`${base}/submitted`)),
  })

export const useRejectedIntakeRequests = (range: TimeRange) =>
  useQuery({
    queryKey: ['intake-requests', 'rejected', range.from, range.to],
    queryFn: async () => decodeFetchRejectedIntakeRequestsAnswer(await apiGet(`${base}/rejected`, { ...range })),
  })

export const useAcceptedIntakeRequests = () =>
  useQuery({
    queryKey: ['intake-requests', 'accepted'],
    queryFn: async () => decodeFetchAcceptedIntakeRequestsAnswer(await apiGet(`${base}/accepted`)),
  })

export const useAppointedIntakeRequests = () =>
  useQuery({
    queryKey: ['intake-requests', 'appointed'],
    queryFn: async () => decodeFetchAppointedIntakeRequestsAnswer(await apiGet(`${base}/appointed`)),
  })

export const useWithdrawnIntakeRequests = (range: TimeRange) =>
  useQuery({
    queryKey: ['intake-requests', 'withdrawn', range.from, range.to],
    queryFn: async () => decodeFetchWithdrawnIntakeRequestsAnswer(await apiGet(`${base}/withdrawn`, { ...range })),
  })

export const useStaleIntakeRequests = (range: TimeRange) =>
  useQuery({
    queryKey: ['intake-requests', 'stale', range.from, range.to],
    queryFn: async () => decodeFetchStaleIntakeRequestsAnswer(await apiGet(`${base}/stale`, { ...range })),
  })

export const useClosedIntakeRequests = (range: TimeRange) =>
  useQuery({
    queryKey: ['intake-requests', 'closed', range.from, range.to],
    queryFn: async () => decodeFetchClosedIntakeRequestsAnswer(await apiGet(`${base}/closed`, { ...range })),
  })

// ── Mutations ──────────────────────────────────────────────────────────────

export const useSubmitIntakeRequest = () =>
  useAnswerMutation(async (body: SubmitIntakeRequestRequest) =>
    decodeSubmitIntakeRequestAnswer(await apiPost(base, body)),
  )

export const useAcceptSubmittedIntakeRequest = () =>
  useAnswerMutation(async ({ id, body }: { id: IntakeRequestId; body: AcceptSubmittedIntakeRequestRequest }) =>
    decodeAcceptSubmittedIntakeRequestAnswer(await apiPost(one(id, 'accept'), body)),
  )

export const useRejectSubmittedIntakeRequest = () =>
  useAnswerMutation(async ({ id, body }: { id: IntakeRequestId; body: RejectSubmittedIntakeRequestRequest }) =>
    decodeRejectSubmittedIntakeRequestAnswer(await apiPost(one(id, 'reject'), body)),
  )

export const useWithdrawIntakeRequest = () =>
  useAnswerMutation(async ({ id, body }: { id: IntakeRequestId; body: WithdrawIntakeRequestRequest }) =>
    decodeWithdrawIntakeRequestAnswer(await apiPost(one(id, 'withdraw'), body)),
  )

export const useMatchAcceptedIntakeRequestToSlot = () =>
  useAnswerMutation(async ({ id, body }: { id: IntakeRequestId; body: MatchAcceptedIntakeRequestToSlotRequest }) =>
    decodeMatchAcceptedIntakeRequestToSlotAnswer(await apiPost(one(id, 'match-to-slot'), body)),
  )

export const useMarkAcceptedIntakeRequestStale = () =>
  useAnswerMutation(async (id: IntakeRequestId) =>
    decodeMarkAcceptedIntakeRequestStaleAnswer(await apiPost(one(id, 'mark-stale'))),
  )

export const useCloseAppointedIntakeRequest = () =>
  useAnswerMutation(async ({ id, body }: { id: IntakeRequestId; body: CloseAppointedIntakeRequestRequest }) =>
    decodeCloseAppointedIntakeRequestAnswer(await apiPost(one(id, 'close'), body)),
  )
