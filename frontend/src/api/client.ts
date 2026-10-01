import type { components, paths } from './types'

export type Schemas = components['schemas']

const baseUrl = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8080'

export class ApiError extends Error {
  readonly status: number
  readonly body: string

  constructor(status: number, body: string) {
    super(`${status} ${body}`)
    this.status = status
    this.body = body
  }
}

type Json = 'application/json;charset=utf-8'
type Method = 'get' | 'post'
type Operation = { responses: { 200: { content: { [J in Json]: unknown } } } }

type RoutesWith<M extends Method> = {
  [P in keyof paths]: paths[P][M] extends Operation ? P : never
}[keyof paths]

type AnswerOf<O> = O extends { responses: { 200: { content: { [J in Json]: infer A } } } } ? A : never
type PathParamsOf<O> = O extends { parameters: { path: infer X extends Record<string, string> } } ? X : undefined
type QueryOf<O> = O extends { parameters: { query: infer X extends Record<string, string> } } ? X : undefined
type BodyOf<O> = O extends { requestBody?: never }
  ? undefined
  : O extends { requestBody?: { content: { [J in Json]: infer X } } }
    ? X
    : undefined

async function send(
  method: 'GET' | 'POST',
  route: string,
  pathParams: Record<string, string> | undefined,
  query: Record<string, string> | undefined,
  body: unknown,
): Promise<unknown> {
  const path = route.replace(/\{(\w+)\}/g, (_, name: string) => encodeURIComponent(pathParams?.[name] ?? ''))
  const search = query ? `?${new URLSearchParams(query).toString()}` : ''
  const response = await fetch(`${baseUrl}${path}${search}`, {
    method,
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) {
    throw new ApiError(response.status, await response.text())
  }
  return response.json()
}

// The one typed boundary: a response's JSON gets its route's answer type from types.ts.
export async function get<P extends RoutesWith<'get'>>(
  route: P,
  pathParams: PathParamsOf<paths[P]['get']>,
  query: QueryOf<paths[P]['get']>,
): Promise<AnswerOf<paths[P]['get']>> {
  const json = await send('GET', route, pathParams, query, undefined)
  return json as AnswerOf<paths[P]['get']>
}

export async function post<P extends RoutesWith<'post'>>(
  route: P,
  pathParams: PathParamsOf<paths[P]['post']>,
  body: BodyOf<paths[P]['post']>,
): Promise<AnswerOf<paths[P]['post']>> {
  const json = await send('POST', route, pathParams, undefined, body)
  return json as AnswerOf<paths[P]['post']>
}
