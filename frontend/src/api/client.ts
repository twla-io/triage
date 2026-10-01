import type { components, paths } from './types'

export type Schemas = components['schemas']

const baseUrl = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8080'

type Json = 'application/json;charset=utf-8'
type Method = 'get' | 'post'

export type Route<M extends Method> = {
  [P in keyof paths]: paths[P][M] extends undefined ? never : P
}[keyof paths]

type Operation<M extends Method, P extends Route<M>> = Exclude<paths[P][M], undefined>

export type AnswerOf<M extends Method, P extends Route<M>> =
  Operation<M, P> extends { responses: { 200: { content: Record<Json, infer A> } } } ? A : never

type ParametersOf<M extends Method, P extends Route<M>> =
  Operation<M, P> extends { parameters: infer X } ? X : never

type BodyOf<M extends Method, P extends Route<M>> =
  Operation<M, P> extends { requestBody?: infer R }
    ? [Exclude<R, undefined>] extends [never]
      ? never
      : Exclude<R, undefined> extends { content: Record<Json, infer B> } ? B : never
    : never

type Input<M extends Method, P extends Route<M>> =
  Pick<ParametersOf<M, P>, Extract<keyof ParametersOf<M, P>, 'path' | 'query'>> &
  ([BodyOf<M, P>] extends [never] ? { body?: undefined } : { body: BodyOf<M, P> })

/** A non-2xx response: its status and body, shown unchanged. */
export class ApiError extends Error {
  readonly status: number
  readonly body: string

  constructor(status: number, body: string) {
    super(`${status} ${body}`)
    this.status = status
    this.body = body
  }
}

interface LooseInput {
  path?: Record<string, string>
  query?: Record<string, string>
  body?: unknown
}

async function send(method: Method, route: string, input: LooseInput): Promise<unknown> {
  const path = route.replace(/\{(\w+)\}/g, (_, name: string) => encodeURIComponent(input.path?.[name] ?? ''))
  const query = input.query === undefined ? '' : `?${new URLSearchParams(input.query).toString()}`
  const response = await fetch(`${baseUrl}${path}${query}`, {
    method: method.toUpperCase(),
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: input.body === undefined ? undefined : JSON.stringify(input.body),
  })
  if (!response.ok) throw new ApiError(response.status, await response.text())
  return response.json()
}

/**
 * The one typed boundary: a response's JSON gets its route's answer type
 * from types.ts. The server is tested against its own schema, so the
 * contract is trusted and nothing is decoded at runtime.
 */
export async function call<M extends Method, P extends Route<M>>(
  method: M,
  route: P,
  input: Input<M, P>,
): Promise<AnswerOf<M, P>> {
  const loose: LooseInput = input
  return (await send(method, route, loose)) as AnswerOf<M, P>
}
