import { useMutation, useQueryClient } from '@tanstack/react-query'

// Every mutation hook goes through this: after any answer, every query is
// invalidated so every list shows the current state (show-every-outcome).
export function useAnswerMutation<Vars, Answer>(mutationFn: (vars: Vars) => Promise<Answer>) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn,
    onSettled: () => queryClient.invalidateQueries(),
  })
}

// A time range for reads that take `from` and `to`.
export interface TimeRange {
  from: string
  to: string
}
