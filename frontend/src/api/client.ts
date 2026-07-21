import type { components } from './types'

export type Schemas = components['schemas']

const BASE_URL: string = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:8080'

export class ApiError extends Error {
  status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

// One shared fetch wrapper: base URL, JSON headers, and non-2xx -> ApiError.
// Mirrors handleServiceError's "one place, not per-endpoint" discipline on
// the backend (src/Api.hs).
async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
      ...init?.headers,
    },
  })

  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new ApiError(res.status, body || res.statusText)
  }

  if (res.status === 204) {
    return undefined as T
  }

  return (await res.json()) as T
}

export function get<T>(path: string): Promise<T> {
  return request<T>(path)
}

export function post<T>(path: string, body?: unknown): Promise<T> {
  return request<T>(path, {
    method: 'POST',
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}

// Every mutation that has an outcome to discriminate (per Api.hs's own
// MIDDLEWARE section) responds with this shape: {"outcome": tag,
// "detail": value|null}. Unwrapped here, in the one place any caller needs
// to know the envelope exists at all — call sites just switch on `outcome`.
export interface Envelope<TDetail = unknown> {
  outcome: string
  detail: TDetail | null
}

export function postEnveloped<TDetail = unknown>(path: string, body?: unknown): Promise<Envelope<TDetail>> {
  return post<Envelope<TDetail>>(path, body)
}

function toQuery(params: Record<string, string | undefined>): string {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) search.set(key, value)
  }
  const qs = search.toString()
  return qs ? `?${qs}` : ''
}

export { toQuery }
