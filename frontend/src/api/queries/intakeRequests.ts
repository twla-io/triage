import { useQuery } from '@tanstack/react-query'
import { call, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'
import type { Range } from '../range'

// ── Reads, one per case ─────────────────────────────────────────────────────

export function useSubmittedIntakeRequests() {
  return useQuery({
    queryKey: ['intakeRequests', 'submitted'],
    queryFn: () => call('get', '/intake-requests/submitted', {}),
  })
}

export function useRejectedIntakeRequests(range: Range) {
  return useQuery({
    queryKey: ['intakeRequests', 'rejected', range.from, range.to],
    queryFn: () => call('get', '/intake-requests/rejected', { query: { from: range.from, to: range.to } }),
  })
}

export function useAcceptedIntakeRequests() {
  return useQuery({
    queryKey: ['intakeRequests', 'accepted'],
    queryFn: () => call('get', '/intake-requests/accepted', {}),
  })
}

export function useAppointedIntakeRequests() {
  return useQuery({
    queryKey: ['intakeRequests', 'appointed'],
    queryFn: () => call('get', '/intake-requests/appointed', {}),
  })
}

export function useWithdrawnIntakeRequests(range: Range) {
  return useQuery({
    queryKey: ['intakeRequests', 'withdrawn', range.from, range.to],
    queryFn: () => call('get', '/intake-requests/withdrawn', { query: { from: range.from, to: range.to } }),
  })
}

export function useStaleIntakeRequests(range: Range) {
  return useQuery({
    queryKey: ['intakeRequests', 'stale', range.from, range.to],
    queryFn: () => call('get', '/intake-requests/stale', { query: { from: range.from, to: range.to } }),
  })
}

export function useClosedIntakeRequests(range: Range) {
  return useQuery({
    queryKey: ['intakeRequests', 'closed', range.from, range.to],
    queryFn: () => call('get', '/intake-requests/closed', { query: { from: range.from, to: range.to } }),
  })
}

// ── Mutations ───────────────────────────────────────────────────────────────

type IntakeRequestId = Schemas['IntakeRequestId']

export function useSubmitIntakeRequest() {
  return useAnswerMutation((body: Schemas['SubmitIntakeRequestRequest']) => call('post', '/intake-requests', { body }))
}

export function useAcceptSubmittedIntakeRequest() {
  return useAnswerMutation(
    ({ intakeRequestId, body }: { intakeRequestId: IntakeRequestId; body: Schemas['AcceptSubmittedIntakeRequestRequest'] }) =>
      call('post', '/intake-requests/{intakeRequestId}/accept', { path: { intakeRequestId }, body }),
  )
}

export function useRejectSubmittedIntakeRequest() {
  return useAnswerMutation(
    ({ intakeRequestId, body }: { intakeRequestId: IntakeRequestId; body: Schemas['RejectSubmittedIntakeRequestRequest'] }) =>
      call('post', '/intake-requests/{intakeRequestId}/reject', { path: { intakeRequestId }, body }),
  )
}

export function useWithdrawIntakeRequest() {
  return useAnswerMutation(
    ({ intakeRequestId, body }: { intakeRequestId: IntakeRequestId; body: Schemas['WithdrawIntakeRequestRequest'] }) =>
      call('post', '/intake-requests/{intakeRequestId}/withdraw', { path: { intakeRequestId }, body }),
  )
}

export function useMatchAcceptedIntakeRequestToSlot() {
  return useAnswerMutation(
    ({ intakeRequestId, body }: { intakeRequestId: IntakeRequestId; body: Schemas['MatchAcceptedIntakeRequestToSlotRequest'] }) =>
      call('post', '/intake-requests/{intakeRequestId}/match-to-slot', { path: { intakeRequestId }, body }),
  )
}

export function useMarkAcceptedIntakeRequestStale() {
  return useAnswerMutation((intakeRequestId: IntakeRequestId) =>
    call('post', '/intake-requests/{intakeRequestId}/mark-stale', { path: { intakeRequestId } }),
  )
}

export function useCloseAppointedIntakeRequest() {
  return useAnswerMutation(
    ({ intakeRequestId, body }: { intakeRequestId: IntakeRequestId; body: Schemas['CloseAppointedIntakeRequestRequest'] }) =>
      call('post', '/intake-requests/{intakeRequestId}/close', { path: { intakeRequestId }, body }),
  )
}
