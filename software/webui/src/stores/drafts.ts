import { defineStore } from 'pinia'
import type { BoardOverride, BoardRfdcConfig, ManualChannel, PhaseCalibrationRecord, RfdcChannelConfig, WaveformRequest } from '../types'

export type NcoMode = 'auto' | 'manual'
export type PlayMode = 'single' | 'continuous_sine'
export interface OutputChannelDraft {
  channel: number; enabled: boolean; waveform: ManualChannel['waveform']; format: 'iq' | 'real'; targetRfGhz: number; dataAmplitude: number;
  dataPhaseDeg: number; dataOffsetMhz: number; channelDurationNs: number; delayNs: number; dacCurrentMa: number; ncoMode: NcoMode;
  ncoMhz: number; ncoPhaseDeg: number; nyquistZone: 1 | 2; calibrationPhaseDeg: number; calibrationNcoMhz: number;
}
export interface OutputDraft {
  name: string; playMode: PlayMode; loop: boolean; recordDurationNs: number; outputDurationMs: number; channels: OutputChannelDraft[];
  selectedChannels: number[]; activeChannel: number; dirty: boolean;
}
export type SweepAxis = 'data_amplitude' | 'data_offset_hz' | 'data_phase_deg' | 'target_rf_hz' | 'nco_hz' | 'nco_phase_deg' | 'dac_output_current_ma'
export interface SweepDraft {
  name: string; axis: SweepAxis; start: number; stop: number; step: number; mode: 'manual' | 'automatic';
  settleMs: number; autoMute: boolean; dirty: boolean;
}

const targetDefaults = [4.5, 4.5, 4.5, 4.5, 0, 0, 5.8, 6.2]
export function ncoPlan(targetGhz: number) {
  return targetGhz < 3.2 ? { ncoMhz: targetGhz * 1000, nyquistZone: 1 as const } : { ncoMhz: (targetGhz - 6.4) * 1000, nyquistZone: 2 as const }
}
function defaultChannel(channel: number): OutputChannelDraft {
  const targetRfGhz = targetDefaults[channel - 1]
  const plan = ncoPlan(targetRfGhz)
  const waveform: ManualChannel['waveform'] = channel <= 4 ? 'xy' : channel <= 6 ? 'z' : 'readout'
  return { channel, enabled: channel <= 2, waveform, format: channel <= 6 && channel >= 5 ? 'real' : 'iq', targetRfGhz, dataAmplitude: 0.5, dataPhaseDeg: 0,
    dataOffsetMhz: 20, channelDurationNs: 500, delayNs: 0, dacCurrentMa: 20, ncoMode: 'auto', ncoMhz: plan.ncoMhz,
    ncoPhaseDeg: 0, nyquistZone: plan.nyquistZone, calibrationPhaseDeg: 0, calibrationNcoMhz: 0 }
}
function defaultDraft(): OutputDraft {
  return { name: '单板 8 通道输出', playMode: 'single', loop: false, recordDurationNs: 10000, outputDurationMs: 100,
    channels: Array.from({ length: 8 }, (_, index) => defaultChannel(index + 1)), selectedChannels: [1], activeChannel: 1, dirty: false }
}
function calibrationFor(records: PhaseCalibrationRecord[], channel: number, targetRfGhz: number) {
  const frequencyHz = Math.round(targetRfGhz * 1e9)
  return records.find((item) => item.channel === channel && item.frequency_hz === frequencyHz)?.phase_deg || 0
}
function hydrate(draft: OutputDraft, rfdc?: BoardRfdcConfig | null, records: PhaseCalibrationRecord[] = []) {
  if (!draft.playMode) draft.playMode = draft.loop ? 'continuous_sine' : 'single'
  draft.loop = draft.playMode === 'continuous_sine'
  const waveformMap: Record<string, ManualChannel['waveform']> = {
    'dc-iq-cw': 'sine', 'iq-sine': 'sine', 'iq-gaussian-sine': 'xy', pypulse: 'xy', quantum: 'xy', burst: 'xy',
  }
  for (const channel of draft.channels) {
    if (!channel.format) channel.format = channel.channel >= 5 && channel.channel <= 6 ? 'real' : 'iq'
    if (typeof channel.delayNs !== 'number') channel.delayNs = 0
    if (!channel.waveform || waveformMap[channel.waveform]) channel.waveform = waveformMap[channel.waveform] || 'sine'
  }
  const sourceByChannel = new Map((rfdc?.channels || []).map((item) => [item.channel, item]))
  for (const channel of draft.channels) {
    const source = sourceByChannel.get(channel.channel)
    if (source) {
      if (typeof channel.targetRfGhz !== 'number') channel.targetRfGhz = source.target_rf_hz / 1e9
      if (typeof channel.dataAmplitude !== 'number') channel.dataAmplitude = source.data_amplitude
      if (typeof channel.dataPhaseDeg !== 'number') channel.dataPhaseDeg = source.data_phase_deg
      if (typeof channel.dataOffsetMhz !== 'number') channel.dataOffsetMhz = source.data_offset_hz / 1e6
      if (typeof channel.dacCurrentMa !== 'number') channel.dacCurrentMa = source.dac_output_current_ma
      if (typeof channel.ncoMhz !== 'number') channel.ncoMhz = source.nco_hz / 1e6
      if (typeof channel.ncoPhaseDeg !== 'number') channel.ncoPhaseDeg = source.nco_phase_deg
      if (channel.nyquistZone !== 1 && channel.nyquistZone !== 2) channel.nyquistZone = source.nyquist_zone
    }
    if (typeof channel.dataAmplitude !== 'number') channel.dataAmplitude = 0.5
    if (typeof channel.dataPhaseDeg !== 'number') channel.dataPhaseDeg = 0
    if (typeof channel.dataOffsetMhz !== 'number') channel.dataOffsetMhz = 0
    if (typeof channel.channelDurationNs !== 'number') channel.channelDurationNs = 500
    if (typeof channel.targetRfGhz !== 'number') channel.targetRfGhz = targetDefaults[channel.channel - 1] ?? 4.5
    if (typeof channel.dacCurrentMa !== 'number') channel.dacCurrentMa = 20
    if (typeof channel.ncoMhz !== 'number') channel.ncoMhz = ncoPlan(channel.targetRfGhz).ncoMhz
    if (typeof channel.ncoPhaseDeg !== 'number') channel.ncoPhaseDeg = 0
    if (channel.nyquistZone !== 1 && channel.nyquistZone !== 2) channel.nyquistZone = ncoPlan(channel.targetRfGhz).nyquistZone
    if (typeof channel.calibrationPhaseDeg !== 'number') channel.calibrationPhaseDeg = 0
    if (typeof channel.calibrationNcoMhz !== 'number') channel.calibrationNcoMhz = 0
    if (!channel.ncoMode) channel.ncoMode = 'auto'
    channel.calibrationPhaseDeg = calibrationFor(records, channel.channel, channel.targetRfGhz)
  }
  return draft
}

export const useDraftsStore = defineStore('drafts', {
  state: () => ({ outputs: {} as Record<string, OutputDraft>, sweeps: {} as Record<string, SweepDraft>, username: '' }),
  actions: {
    setUser(username: string) { this.username = username },
    key(boardId: string) { return 'rfdc.output.board.' + boardId },
    legacyKey(boardId: string) { return 'rfdc.output.' + (this.username || 'anonymous') + '.' + boardId },
    findLegacyText(boardId: string) {
      const direct = localStorage.getItem(this.legacyKey(boardId))
      if (direct) return direct
      for (let index = 0; index < localStorage.length; index++) {
        const candidate = localStorage.key(index)
        if (candidate && candidate.startsWith('rfdc.output.') && candidate.endsWith('.' + boardId)) {
          return localStorage.getItem(candidate)
        }
      }
      return null
    },
    output(boardId: string, rfdc?: BoardRfdcConfig | null, records: PhaseCalibrationRecord[] = []) {
      if (!this.outputs[boardId]) {
        const savedText = localStorage.getItem(this.key(boardId))
        const legacyText = this.findLegacyText(boardId)
        let draft: OutputDraft | null = null
        try { draft = JSON.parse(savedText || legacyText || 'null') as OutputDraft | null } catch { draft = null }
        this.outputs[boardId] = hydrate(draft?.channels?.length === 8 ? draft : defaultDraft(), rfdc, records)
        this.outputs[boardId].dirty = false
        if (!savedText && legacyText) this.persist(boardId)
      }
      return this.outputs[boardId]
    },
    syncFromServer(boardId: string, _rfdc: BoardRfdcConfig, records: PhaseCalibrationRecord[]) {
      const draft = this.outputs[boardId]
      if (!draft) return
      for (const channel of draft.channels) {
        channel.calibrationPhaseDeg = calibrationFor(records, channel.channel, channel.targetRfGhz)
      }
      this.persist(boardId)
    },
    persist(boardId: string) {
      const draft = this.outputs[boardId]
      if (draft) localStorage.setItem(this.key(boardId), JSON.stringify(draft))
    },
    save(boardId: string) { const draft = this.outputs[boardId]; if (draft) { draft.dirty = false; this.persist(boardId) } },
    discard(boardId: string, rfdc?: BoardRfdcConfig | null, records: PhaseCalibrationRecord[] = []) {
      let saved: OutputDraft | null = null
      try { saved = JSON.parse(localStorage.getItem(this.key(boardId)) || this.findLegacyText(boardId) || 'null') as OutputDraft | null } catch { saved = null }
      this.outputs[boardId] = hydrate(saved?.channels?.length === 8 ? saved : defaultDraft(), rfdc, records)
      this.outputs[boardId].dirty = false
    },
    markDirty(boardId: string) {
      const draft = this.outputs[boardId]
      if (!draft) return
      draft.dirty = true
      this.persist(boardId)
    },
    reset(boardId: string, rfdc?: BoardRfdcConfig | null, records: PhaseCalibrationRecord[] = []) { this.outputs[boardId] = hydrate(defaultDraft(), rfdc, records); this.save(boardId) },
    sweep(boardId: string) {
      if (!this.sweeps[boardId]) {
        const key = 'rfdc.sweep.' + (this.username || 'anonymous') + '.' + boardId
        try { this.sweeps[boardId] = JSON.parse(localStorage.getItem(key) || 'null') as SweepDraft } catch { this.sweeps[boardId] = null as unknown as SweepDraft }
        if (!this.sweeps[boardId]?.axis) this.sweeps[boardId] = { name: '幅值逐点扫描', axis: 'data_amplitude', start: 0, stop: 1, step: 0.05, mode: 'manual', settleMs: 100, autoMute: true, dirty: false }
      }
      return this.sweeps[boardId]
    },
    saveSweep(boardId: string) {
      const sweep = this.sweeps[boardId]
      if (sweep) { sweep.dirty = false; localStorage.setItem('rfdc.sweep.' + (this.username || 'anonymous') + '.' + boardId, JSON.stringify(sweep)) }
    },
  },
})

export function outputWaveform(draft: OutputDraft): WaveformRequest {
  const continuousSine = draft.playMode === 'continuous_sine'
  return { name: draft.name, mode: 'manual', loop: continuousSine, record_duration_ns: draft.recordDurationNs,
    manual_channels: draft.channels.map((item) => {
      const dataAmplitude = typeof item.dataAmplitude === 'number' ? item.dataAmplitude : 0.5
      const dataOffsetMhz = typeof item.dataOffsetMhz === 'number' ? item.dataOffsetMhz : 0
      return { channel: item.channel, enabled: item.enabled, waveform: item.waveform, format: item.format,
      frequency_mhz: dataOffsetMhz, data_offset_mhz: dataOffsetMhz, phase_deg: typeof item.dataPhaseDeg === 'number' ? item.dataPhaseDeg : 0,
      amplitude: Math.round(Math.abs(dataAmplitude) * 32767), data_amplitude: dataAmplitude,
      duration_ns: Math.min(item.channelDurationNs, draft.recordDurationNs), delay_ns: item.delayNs,
      target_rf_mhz: typeof item.targetRfGhz === 'number' ? item.targetRfGhz : 0, nco_mhz: typeof item.ncoMhz === 'number' ? item.ncoMhz : 0,
      nyquist_zone: item.nyquistZone === 2 ? 2 : 1, nco_phase_deg: typeof item.ncoPhaseDeg === 'number' ? item.ncoPhaseDeg : 0 }
    }), ezq_channels: [] }
}
export function outputOverride(boardId: string, draft: OutputDraft): BoardOverride {
  return { board_id: boardId, channel_enabled: Object.fromEntries(draft.channels.map((item) => [item.channel, item.enabled])),
    nco_offset_hz: {},
    phase_offset_deg: Object.fromEntries(draft.channels.map((item) => [item.channel, 0])), start_offset_ns: {} }
}
export function outputRfdc(boardId: string, draft: OutputDraft, base: BoardRfdcConfig): BoardRfdcConfig {
  const channels: RfdcChannelConfig[] = base.channels.map((source) => {
    const item = draft.channels[source.channel - 1]
    const real = item.format === 'real'
    const targetRfGhz = typeof item.targetRfGhz === 'number' ? item.targetRfGhz : 0
    const ncoMhz = typeof item.ncoMhz === 'number' ? item.ncoMhz : 0
    const nyquistZone = item.nyquistZone === 2 ? 2 : 1
    const dataAmplitude = typeof item.dataAmplitude === 'number' ? item.dataAmplitude : 0.5
    const plan: { ncoMhz: number; nyquistZone: 1 | 2 } = item.ncoMode === 'auto' ? ncoPlan(targetRfGhz) : { ncoMhz, nyquistZone }
    return { ...source, target_rf_hz: real ? 0 : targetRfGhz * 1e9, nco_hz: real ? 0 : (plan.ncoMhz + (typeof item.calibrationNcoMhz === 'number' ? item.calibrationNcoMhz : 0)) * 1e6,
      nyquist_zone: real ? 1 : plan.nyquistZone, data_offset_hz: (typeof item.dataOffsetMhz === 'number' ? item.dataOffsetMhz : 0) * 1e6,
      data_amplitude: dataAmplitude, data_phase_deg: typeof item.dataPhaseDeg === 'number' ? item.dataPhaseDeg : 0,
      nco_phase_deg: typeof item.ncoPhaseDeg === 'number' ? item.ncoPhaseDeg : 0,
      calibration_phase_deg: typeof item.calibrationPhaseDeg === 'number' ? item.calibrationPhaseDeg : 0,
      dac_output_current_ma: typeof item.dacCurrentMa === 'number' ? item.dacCurrentMa : 20 }
  })
  return { ...base, board_id: boardId, channels }
}
