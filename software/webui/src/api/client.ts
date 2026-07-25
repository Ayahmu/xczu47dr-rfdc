let csrfToken = ''
let unauthorizedHandler: (() => void) | null = null

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
    this.name = 'ApiError'
  }
}

export function setApiSecurity(token: string, onUnauthorized?: () => void) {
  csrfToken = token
  unauthorizedHandler = onUnauthorized ?? null
}

type ApiOptions = Omit<RequestInit, 'body'> & { body?: BodyInit | Record<string, unknown> | unknown[] }

export async function api<T = unknown>(path: string, options: ApiOptions = {}): Promise<T> {
  const headers = new Headers(options.headers)
  let body = options.body as BodyInit | undefined
  if (options.body != null && !(options.body instanceof FormData) && typeof options.body !== 'string' && !(options.body instanceof Blob)) {
    headers.set('Content-Type', 'application/json')
    body = JSON.stringify(options.body)
  }
  if (options.method && !['GET', 'HEAD'].includes(options.method.toUpperCase())) {
    headers.set('X-CSRF-Token', csrfToken)
  }
  const response = await fetch(path, { ...options, headers, body, credentials: 'include' })
  if (response.status === 401) unauthorizedHandler?.()
  if (!response.ok) {
    const payload = await response.json().catch(() => ({})) as { detail?: string }
    throw new ApiError(response.status, payload.detail || response.statusText || '请求失败')
  }
  if (response.status === 204) return undefined as T
  return await response.json() as T
}

export function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error)
}
