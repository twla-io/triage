import { useQuery } from '@tanstack/react-query'
import { get, post, type Schemas } from '../client'
import { useAnswerMutation } from '../mutation'
import { rangeQuery, type Week } from '../range'

type Id = Schemas['IntakeRequestId']

export function useSubmittedIntakeRequests() {
  return useQuery({
    queryKey: ['intake-requests', 'submitted'],
    queryFn: () => get('/intake-requests/submitted', undefined, undefined),
  })
}

export function useRejectedIntakeRequests(week: Week) {
  const query = rangeQuery(week)
  return useQuery({
    queryKey: ['intake-requests', 'rejected', query.from, query.to],
    queryFn: () => get('/intake-requests/rejected', undefined, query),
  })
}

export function useAcceptedIntakeRequests() {
  return useQuery({
    queryKey: ['intake-requests', 'accepted'],
    queryFn: () => get('/intake-requests/accepted', undefined, undefined),
  })
}

export function useAppointedIntakeRequests() {
  return useQuery({
    queryKey: ['intake-requests', 'appointed'],
    queryFn: () => get('/intake-requests/appointed', undefined, undefined),
  })
}

export function useWithdrawnIntakeRequests(week: Week) {
  const query = rangeQuery(week)
  return useQuery({
    queryKey: ['intake-requests', 'withdrawn', query.from, query.to],
    queryFn: () => get('/intake-requests/withdrawn', undefined, query),
  })
}

export function useStaleIntakeRequests(week: Week) {
  const query = rangeQuery(week)
  return useQuery({
    queryKey: ['intake-requests', 'stale', query.from, query.to],
    queryFn: () => get('/intake-requests/stale', undefined, query),
  })
}

export function useClosedIntakeRequests(week: Week) {
  const query = rangeQuery(week)
  return useQuery({
    queryKey: ['intake-requests', 'closed', query.from, query.to],
    queryFn: () => get('/intake-requests/closed', undefined, query),
  })
}

export function useSubmitIntakeRequest() {
  return useAnswerMutation((body: Schemas['SubmitIntakeRequestRequest']) => post('/intake-requests', undefined, body))
}

export function useAcceptSubmittedIntakeRequest() {
  return useAnswerMutation((v: { id: Id; body: Schemas['AcceptSubmittedIntakeRequestRequest'] }) =>
    post('/intake-requests/{intakeRequestId}/accept', { intakeRequestId: v.id }, v.body),
  )
}

export function useRejectSubmittedIntakeRequest() {
  return useAnswerMutation((v: { id: Id; body: Schemas['RejectSubmittedIntakeRequestRequest'] }) =>
    post('/intake-requests/{intakeRequestId}/reject', { intakeRequestId: v.id }, v.body),
  )
}

export function useWithdrawIntakeRequest() {
  return useAnswerMutation((v: { id: Id; body: Schemas['WithdrawIntakeRequestRequest'] }) =>
    post('/intake-requests/{intakeRequestId}/withdraw', { intakeRequestId: v.id }, v.body),
  )
}

export function useMatchAcceptedIntakeRequestToSlot() {
  return useAnswerMutation((v: { id: Id; body: Schemas['MatchAcceptedIntakeRequestToSlotRequest'] }) =>
    post('/intake-requests/{intakeRequestId}/match-to-slot', { intakeRequestId: v.id }, v.body),
  )
}

export function useMarkAcceptedIntakeRequestStale() {
  return useAnswerMutation((id: Id) =>
    post('/intake-requests/{intakeRequestId}/mark-stale', { intakeRequestId: id }, undefined),
  )
}

export function useCloseAppointedIntakeRequest() {
  return useAnswerMutation((v: { id: Id; body: Schemas['CloseAppointedIntakeRequestRequest'] }) =>
    post('/intake-requests/{intakeRequestId}/close', { intakeRequestId: v.id }, v.body),
  )
}
