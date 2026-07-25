import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { RunEvent, RunRecord } from '../types'

export const useRunsStore = defineStore('runs', {
  state: () => ({ items: [] as RunRecord[], events: {} as Record<string, RunEvent[]>, loading: false }),
  getters: { byId: (state) => (id: string) => state.items.find((item) => item.id === id) || null },
  actions: {
    async fetchAll() { this.items = await api<RunRecord[]>('/api/runs') },
    upsert(record: RunRecord) {
      const index = this.items.findIndex((item) => item.id === record.id)
      if (index >= 0) this.items[index] = record; else this.items.unshift(record)
    },
    addEvent(event: RunEvent) {
      const list = this.events[event.run_id] || (this.events[event.run_id] = [])
      list.unshift(event)
    },
    async fetchEvents(id: string) { this.events[id] = await api<RunEvent[]>('/api/runs/' + id + '/events'); return this.events[id] },
    async create(payload: Record<string, unknown>) { const record = await api<RunRecord>('/api/runs', { method: 'POST', body: payload }); this.upsert(record); return record },
    async action(id: string, action: 'arm' | 'trigger' | 'abort') { const record = await api<RunRecord>('/api/runs/' + id + '/' + action, { method: 'POST' }); this.upsert(record); return record },
  },
})
