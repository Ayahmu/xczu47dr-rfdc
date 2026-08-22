import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { BoardPreflight, BoardProfile, BoardRfdcConfig, BoardScanResponse, BoardStatus, DiscoveryResource, MaxLengthTestRecord, NetworkConfigSnapshot, NetworkInterfaceInfo, PhaseCalibrationRecord, SyncResult } from '../types'

export const useBoardsStore = defineStore('boards', {
  state: () => ({
    boards: [] as BoardProfile[], statuses: [] as BoardStatus[], discoveries: [] as DiscoveryResource[],
    interfaces: [] as NetworkInterfaceInfo[], loading: false, loaded: false,
  }),
  getters: {
    byId: (state) => (id: string) => state.boards.find((item) => item.id === id) || null,
    statusById: (state) => (id: string) => state.statuses.find((item) => item.board_id === id) || null,
  },
  actions: {
    async fetchAll(refresh = false) {
      this.loading = true
      try {
        const [boards, statuses, discoveries, interfaces] = await Promise.all([
          api<BoardProfile[]>('/api/boards'), api<BoardStatus[]>('/api/boards/status?refresh=' + refresh),
          api<DiscoveryResource[]>('/api/discovery'), api<NetworkInterfaceInfo[]>('/api/network/interfaces'),
        ])
        this.boards = boards; this.statuses = statuses; this.discoveries = discoveries; this.interfaces = interfaces; this.loaded = true
      } finally { this.loading = false }
    },
    async refreshStatus(boardId: string, refresh = true) {
      const status = await api<BoardStatus>('/api/boards/' + boardId + '/status?refresh=' + refresh)
      this.upsertStatus(status)
      return status
    },
    async scanNetwork() {
      this.loading = true
      try {
        const result = await api<BoardScanResponse>('/api/boards/scan', { method: 'POST' })
        await this.fetchAll(true)
        return result
      } finally { this.loading = false }
    },
    upsertStatus(status: BoardStatus) {
      const index = this.statuses.findIndex((item) => item.board_id === status.board_id)
      if (index >= 0) this.statuses[index] = status; else this.statuses.push(status)
    },
    upsertBoard(board: BoardProfile) {
      const index = this.boards.findIndex((item) => item.id === board.id)
      if (index >= 0) this.boards[index] = board; else this.boards.push(board)
    },
    async acquire(boardId: string) { this.upsertBoard(await api<BoardProfile>('/api/boards/' + boardId + '/lease', { method: 'POST' })) },
    async release(boardId: string) { this.upsertBoard(await api<BoardProfile>('/api/boards/' + boardId + '/release', { method: 'POST' })) },
    async forceRelease(boardId: string) { this.upsertBoard(await api<BoardProfile>('/api/admin/boards/' + boardId + '/force-release', { method: 'POST' })) },
    async abort(boardId: string) {
      const result = await api('/api/boards/' + boardId + '/abort', { method: 'POST' })
      await this.refreshStatus(boardId, false)
      return result
    },
    async syncTwoBoards(masterBoardId: string, slaveBoardId: string) {
      const result = await api<SyncResult>('/api/sync', { method: 'POST', body: { master_board_id: masterBoardId, slave_board_id: slaveBoardId } })
      await this.fetchAll(true)
      return result
    },
    maxLengthTests() { return api<MaxLengthTestRecord[]>('/api/max-length-tests') },
    startMaxLength(boardId: string, payload: Record<string, unknown>) {
      return api<MaxLengthTestRecord>('/api/boards/' + boardId + '/max-length-test', { method: 'POST', body: { ...payload, board_id: boardId } })
    },
    abortMaxLength(testId: string) { return api<MaxLengthTestRecord>('/api/max-length-tests/' + testId + '/abort', { method: 'POST' }) },
    rfdc(boardId: string, refresh = false) { return api<BoardRfdcConfig>('/api/boards/' + boardId + '/rfdc-config?refresh=' + refresh) },
    phaseCalibrations(boardId: string) { return api<PhaseCalibrationRecord[]>('/api/boards/' + boardId + '/phase-calibration') },
    savePhaseCalibration(boardId: string, payload: { frequency_hz: number; channel: number; phase_deg: number }) {
      return api<PhaseCalibrationRecord>('/api/boards/' + boardId + '/phase-calibration', { method: 'PUT', body: payload })
    },
    preflight(boardId: string, refresh = true) { return api<BoardPreflight>('/api/boards/' + boardId + '/preflight?refresh=' + refresh) },
    network(boardId: string, refresh = true) { return api<NetworkConfigSnapshot>('/api/boards/' + boardId + '/network-config?refresh=' + refresh) },
    async applyNetwork(boardId: string, payload: { revision: number; ip: string; mac: string; subnet_mask: string; gateway: string; port: number }) {
      const result = await api<NetworkConfigSnapshot>('/api/admin/boards/' + boardId + '/network-config/apply', { method: 'POST', body: payload })
      await this.fetchAll(false)
      return result
    },
  },
})
