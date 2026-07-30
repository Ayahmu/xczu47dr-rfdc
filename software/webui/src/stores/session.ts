import { defineStore } from 'pinia'
import { api, setApiSecurity } from '../api/client'
import type { UserRecord } from '../types'

interface SessionResponse { user: UserRecord | null; csrf_token: string | null }

export const useSessionStore = defineStore('session', {
  state: () => ({ user: null as UserRecord | null, csrfToken: '', initialized: false }),
  getters: { isAdmin: (state) => state.user?.role === 'admin' },
  actions: {
    installSecurity() {
      setApiSecurity(this.csrfToken, () => { this.user = null; this.csrfToken = '' })
    },
    async restore() {
      if (this.initialized) return
      try {
        const session = await api<SessionResponse>('/api/auth/me')
        this.user = session.user
        this.csrfToken = session.csrf_token || ''
      } finally {
        this.initialized = true
        this.installSecurity()
      }
    },
    async login(username: string, password: string) {
      const session = await api<SessionResponse>('/api/auth/login', { method: 'POST', body: { username, password } })
      this.user = session.user
      this.csrfToken = session.csrf_token || ''
      this.initialized = true
      this.installSecurity()
    },
    async logout() {
      try { await api('/api/auth/logout', { method: 'POST' }) } finally {
        this.user = null
        this.csrfToken = ''
        this.installSecurity()
      }
    },
  },
})
