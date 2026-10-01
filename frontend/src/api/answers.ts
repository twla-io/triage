import type { Schemas } from './client'

/** Every answer the API gives: one member per outcome, `detail` typed. */
export type AnyAnswer = Schemas[Extract<keyof Schemas, `${string}Answer`>] | Schemas['MatchOutcome']
