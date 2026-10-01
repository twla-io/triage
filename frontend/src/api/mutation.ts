import { useMutation, useQueryClient } from '@tanstack/react-query'

/**
 * A mutation whose answer, whatever it is, may have changed any list:
 * after it settles every query is invalidated, so every list shows the
 * current state.
 */
export function useAnswerMutation<V, A>(mutationFn: (variables: V) => Promise<A>) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn,
    onSettled: () => queryClient.invalidateQueries(),
  })
}
