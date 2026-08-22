import { defineStore } from 'pinia'
import { useBoardsStore } from './boards'
import { useRunsStore } from './runs'
import { useTestsStore } from './tests'
import type { BoardRfdcConfig, PerformancePointRecord, PerformanceTestRecord, RunEvent, RunRecord, SerialLogLine } from '../types'

export const useEventsStore = defineStore('events', {
  state: () => ({ state: 'offline' as 'connected' | 'connecting' | 'offline', socket: null as WebSocket | null, timer: 0, serial: {} as Record<string, SerialLogLine[]> }),
  actions: {
    clearSerial(boardId?: string) {
      if (boardId) this.serial[boardId] = []
      else this.serial = {}
    },
    connect() {
      this.disconnect(); this.state = 'connecting'
      const protocol = location.protocol === 'https:' ? 'wss' : 'ws'
      const socket = new WebSocket(protocol + '://' + location.host + '/api/events')
      this.socket = socket
      socket.onopen = () => { this.state = 'connected' }
      socket.onmessage = (message) => {
        const event = JSON.parse(message.data) as { type: string; data?: unknown }
        const runs = useRunsStore(); const tests = useTestsStore(); const boards = useBoardsStore()
        if (event.type === 'run.update' || event.type === 'run.done') runs.upsert(event.data as RunRecord)
        if (event.type === 'run.event') runs.addEvent(event.data as RunEvent)
        if (event.type === 'test.point.updated') tests.upsertPoint(event.data as PerformancePointRecord)
        if (event.type === 'test.started' || event.type === 'test.completed') tests.upsert(event.data as PerformanceTestRecord)
        if (event.type.startsWith('rfdc.apply.')) { const config = event.data as BoardRfdcConfig; void boards.refreshStatus(config.board_id, false) }
        if (event.type === 'serial.line') {
          const line = event.data as SerialLogLine & { board_id: string }
          const list = this.serial[line.board_id] || (this.serial[line.board_id] = [])
          list.push({ line: line.line, created_at: line.created_at })
          if (list.length > 5000) list.splice(0, list.length - 5000)
        }
        if (event.type === 'inventory.updated' || event.type === 'lease.updated') void boards.fetchAll(false)
      }
      socket.onclose = () => { this.state = 'offline'; this.socket = null; this.timer = window.setTimeout(() => this.connect(), 3000) }
      socket.onerror = () => socket.close()
    },
    disconnect() { window.clearTimeout(this.timer); if (this.socket) { this.socket.onclose = null; this.socket.close() }; this.socket = null; this.state = 'offline' },
  },
})
