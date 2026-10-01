// The one fetch wrapper. Answers are returned untyped; src/api/wire.ts decodes them.

const baseUrl = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8080'

export class ApiError extends Error {
  readonly status: number
  readonly body: string

  constructor(status: number, body: string) {
    super(`${status}: ${body}`)
    this.name = 'ApiError'
    this.status = status
    this.body = body
  }
}

type Query = Record<string, string>

async function request(method: 'GET' | 'POST', path: string, query?: Query, body?: unknown): Promise<unknown> {
  const search = query ? `?${new URLSearchParams(query).toString()}` : ''
  const response = await fetch(`${baseUrl}${path}${search}`, {
    method,
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) throw new ApiError(response.status, text)
  const parsed: unknown = text === '' ? null : JSON.parse(text)
  return parsed
}

export const apiGet = (path: string, query?: Query): Promise<unknown> => request('GET', path, query)

export const apiPost = (path: string, body?: unknown): Promise<unknown> => request('POST', path, undefined, body)
