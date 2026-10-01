/**
 * A form's state for a value still being entered: the wire type itself,
 * with each value not yet given as `null`. A sum type keeps its `type`, so
 * the chosen case and its controls can never disagree; a nested sum type is
 * a draft of its own, or `null` while no case is chosen.
 */
export type Draft<T> = T extends { type: string }
  ? { [K in keyof T]: K extends 'type' ? T[K] : Slot<T[K]> }
  : never

export type Slot<V> = V extends { type: string } ? Draft<V> | null : V | null

/** A request body still being entered. */
export type DraftRecord<R> = { [K in keyof R]: Slot<R[K]> }

/**
 * Every case of a sum type, in constructor order. Fails to type-check if a
 * case is missing, so adding a constructor needs it listed.
 */
export function allCases<T extends string>() {
  return <const L extends readonly T[]>(
    list: L & ([Exclude<T, L[number]>] extends [never] ? unknown : { missingCase: Exclude<T, L[number]> }),
  ): readonly T[] => list
}
