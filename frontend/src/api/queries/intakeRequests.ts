import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post, postEnveloped, toQuery, type Schemas } from '../client'

export type IntakeRequestDTO = Schemas['IntakeRequestDTO']
export type DoctorRequirementDTO = Schemas['DoctorRequirementDTO']

// IntakeRequestPriorityDTO's "due" field comes back from the generated
// schema as `unknown` (Transport.hs's swagger schema declares it as an
// inline free-form object, see Transport.hs's IntakeRequestPriorityDTO
// ToSchema instance) -- these two mirror Transport.hs's RoutineDueDTO /
// IntakeRequestPriorityDTO wire shapes by hand for the one direction that
// actually needs a precise type: building the request payload.
export type RoutineDuePayload =
  | { type: 'routineAnytime' }
  | { type: 'routineNotBefore'; from: string }
  | { type: 'routineNotAfter'; to: string }
  | { type: 'routineWithin'; from: string; to: string }

export type IntakeRequestPriorityPayload =
  | { type: 'emergency'; due: string }
  | { type: 'urgent'; due: string }
  | { type: 'routine'; due: RoutineDuePayload }

export function useSubmittedIntakeRequests() {
  return useQuery({
    queryKey: ['intake-requests', 'submitted'],
    queryFn: () => get<IntakeRequestDTO[]>('/intake-requests/submitted'),
  })
}

export function useIntakeWaitlist() {
  return useQuery({
    queryKey: ['intake-requests', 'waitlist'],
    queryFn: () => get<IntakeRequestDTO[]>('/intake-requests/waitlist'),
  })
}

export interface ClosedRange {
  start: string
  end: string
  doctorId?: string
}

export function useClosedIntakeRequests(range: ClosedRange) {
  return useQuery({
    queryKey: ['intake-requests', 'closed', range],
    queryFn: () =>
      get<IntakeRequestDTO[]>(
        `/intake-requests/closed${toQuery({ start: range.start, end: range.end, doctorId: range.doctorId })}`,
      ),
  })
}

export interface SubmitIntakeRequestInput {
  patientId: string
  narrative: string
  requestedDoctor: DoctorRequirementDTO
}

function invalidateIntakeQueries(queryClient: ReturnType<typeof useQueryClient>) {
  queryClient.invalidateQueries({ queryKey: ['intake-requests'] })
}

export function useSubmitIntakeRequest() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: SubmitIntakeRequestInput) => post<IntakeRequestDTO>('/intake-requests', input),
    onSuccess: () => invalidateIntakeQueries(queryClient),
  })
}

export function useAcceptIntakeRequest() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({
      id,
      healthcareServiceId,
      priority,
      doctorRequirement,
    }: {
      id: string
      healthcareServiceId: string
      priority: IntakeRequestPriorityPayload
      doctorRequirement: DoctorRequirementDTO
    }) =>
      postEnveloped<IntakeRequestDTO>(`/intake-requests/${id}/accept`, {
        healthcareServiceId,
        priority,
        doctorRequirement,
      }),
    onSuccess: () => invalidateIntakeQueries(queryClient),
  })
}

export function useRejectIntakeRequest() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, rejectionReason }: { id: string; rejectionReason: string }) =>
      postEnveloped<IntakeRequestDTO>(`/intake-requests/${id}/reject`, { rejectionReason }),
    onSuccess: () => invalidateIntakeQueries(queryClient),
  })
}

export function useMatchIntakeRequest() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, slotId }: { id: string; slotId: string }) =>
      postEnveloped(`/intake-requests/${id}/match`, { slotId }),
    onSuccess: () => {
      invalidateIntakeQueries(queryClient)
      queryClient.invalidateQueries({ queryKey: ['slots'] })
      queryClient.invalidateQueries({ queryKey: ['calendar'] })
    },
  })
}

export function useMarkIntakeRequestStale() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => postEnveloped<IntakeRequestDTO>(`/intake-requests/${id}/mark-stale`),
    onSuccess: () => invalidateIntakeQueries(queryClient),
  })
}
