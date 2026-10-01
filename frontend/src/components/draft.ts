// A form's state for a wire value: the same shape, with every value not yet
// entered null. A sum type's draft stays a union of its cases.
export type Draft<T> = T extends object
  ? { [K in keyof T]: K extends 'type' ? T[K] : Draft<T[K]> | null }
  : T

// Every constructor of an enumeration or sum type, in Domain.hs order; the
// Record makes the list exhaustive.
export function cases<T extends string>(all: Record<T, T>): T[] {
  return Object.values(all)
}
