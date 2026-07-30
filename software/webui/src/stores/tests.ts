import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { PerformancePointRecord, PerformanceTestRecord } from '../types'

export const useTestsStore = defineStore('tests', {
  state: () => ({ items: [] as PerformanceTestRecord[], points: {} as Record<string, PerformancePointRecord[]> }),
  getters: { byId: (state) => (id: string) => state.items.find((item) => item.id === id) || null },
  actions: {
    async fetchAll() { this.items = await api<PerformanceTestRecord[]>('/api/tests') },
    upsert(record: PerformanceTestRecord) { const i = this.items.findIndex((item) => item.id === record.id); if (i >= 0) this.items[i] = record; else this.items.unshift(record) },
    upsertPoint(point: PerformancePointRecord) { const list = this.points[point.test_id] || (this.points[point.test_id] = []); const i = list.findIndex((item) => item.id === point.id); if (i >= 0) list[i] = point; else list.push(point) },
    async fetchPoints(id: string) { this.points[id] = await api<PerformancePointRecord[]>('/api/tests/' + id + '/points'); return this.points[id] },
    async create(payload: Record<string, unknown>) { const record = await api<PerformanceTestRecord>('/api/tests', { method: 'POST', body: payload }); this.upsert(record); return record },
    async action(id: string, action: 'start' | 'pause' | 'abort') { const record = await api<PerformanceTestRecord>('/api/tests/' + id + '/' + action, { method: 'POST' }); this.upsert(record); return record },
    async execute(id: string, index: number) { const point = await api<PerformancePointRecord>('/api/tests/' + id + '/points/' + index + '/execute', { method: 'POST' }); this.upsertPoint(point); return point },
    async measurement(id: string, index: number, payload: Record<string, unknown>) { const point = await api<PerformancePointRecord>('/api/tests/' + id + '/points/' + index + '/measurement', { method: 'POST', body: payload }); this.upsertPoint(point); return point },
  },
})
