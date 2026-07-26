import { defineStore } from 'pinia'
import type { BoardOverride, BoardRfdcConfig, ManualChannel, RfdcChannelConfig, WaveformRequest } from '../types'

export type NcoMode = 'auto' | 'manual'
export type PlayMode = 'single' | 'continuous_sine'
export interface OutputChannelDraft {
  channel: number; enabled: boolean; waveform: ManualChannel['waveform']; targetRfGhz: number; dataAmplitude: number;
  dataPhaseDeg: number; dataOffsetMhz: number; channelDurationNs: number; dacCurrentMa: number; ncoMode: NcoMode;
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
  return { channel, enabled: channel <= 2, waveform: 'iq-sine', targetRfGhz, dataAmplitude: 0.5, dataPhaseDeg: 0,
    dataOffsetMhz: 20, channelDurationNs: 1000, dacCurrentMa: 20, ncoMode: 'auto', ncoMhz: plan.ncoMhz,
    ncoPhaseDeg: 0, nyquistZone: plan.nyquistZone, calibrationPhaseDeg: 0, calibrationNcoMhz: 0 }
}
function defaultDraft(): OutputDraft {
  return { name: '单板 8 通道输出', playMode: 'single', loop: false, recordDurationNs: 10000, outputDurationMs: 100,
    channels: Array.from({ length: 8 }, (_, index) => defaultChannel(index + 1)), selectedChannels: [1], activeChannel: 1, dirty: false }
}
function hydrate(draft: OutputDraft, rfdc?: BoardRfdcConfig | null) {
  if (!draft.playMode) draft.playMode = draft.loop ? 'continuous_sine' : 'single'
  draft.loop = draft.playMode === 'continuous_sine'
  if (!rfdc) return draft
  for (const channel of draft.channels) {
    const source = rfdc.channels.find((item) => item.channel === channel.channel)
    if (!source) continue
    channel.targetRfGhz = source.target_rf_hz / 1e9; channel.dataAmplitude = source.data_amplitude
    channel.dataPhaseDeg = source.data_phase_deg; channel.dataOffsetMhz = source.data_offset_hz / 1e6
    channel.dacCurrentMa = source.dac_output_current_ma; channel.ncoMhz = source.nco_hz / 1e6
    channel.ncoPhaseDeg = source.nco_phase_deg; channel.nyquistZone = source.nyquist_zone
  }
  return draft
}

export const useDraftsStore = defineStore('drafts', {
  state: () => ({ outputs: {} as Record<string, OutputDraft>, sweeps: {} as Record<string, SweepDraft>, username: '' }),
  actions: {
    setUser(username: string) { this.username = username },
    key(boardId: string) { return 'rfdc.output.' + (this.username || 'anonymous') + '.' + boardId },
    output(boardId: string, rfdc?: BoardRfdcConfig | null) {
      if (!this.outputs[boardId]) {
        let draft: OutputDraft | null = null
        try { draft = JSON.parse(localStorage.getItem(this.key(boardId)) || 'null') as OutputDraft | null } catch { draft = null }
        this.outputs[boardId] = hydrate(draft?.channels?.length === 8 ? draft : defaultDraft(), rfdc)
      }
      return this.outputs[boardId]
    },
    save(boardId: string) { const draft = this.outputs[boardId]; if (draft) { draft.dirty = false; localStorage.setItem(this.key(boardId), JSON.stringify(draft)) } },
    discard(boardId: string, rfdc?: BoardRfdcConfig | null) {
      let saved: OutputDraft | null = null
      try { saved = JSON.parse(localStorage.getItem(this.key(boardId)) || 'null') as OutputDraft | null } catch { saved = null }
      this.outputs[boardId] = hydrate(saved?.channels?.length === 8 ? saved : defaultDraft(), rfdc)
      this.outputs[boardId].dirty = false
    },
    markDirty(boardId: string) { if (this.outputs[boardId]) this.outputs[boardId].dirty = true },
    reset(boardId: string, rfdc?: BoardRfdcConfig | null) { this.outputs[boardId] = hydrate(defaultDraft(), rfdc); this.save(boardId) },
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
    manual_channels: draft.channels.map((item) => ({ channel: item.channel, enabled: item.enabled, waveform: continuousSine && item.enabled ? 'iq-sine' : item.waveform,
      frequency_mhz: item.dataOffsetMhz, phase_deg: item.dataPhaseDeg,
      amplitude: Math.round(Math.abs(item.dataAmplitude) * 32767), data_amplitude: item.dataAmplitude,
      duration_ns: Math.min(item.channelDurationNs, draft.recordDurationNs) })), ezq_channels: [] }
}
export function outputOverride(boardId: string, draft: OutputDraft): BoardOverride {
  return { board_id: boardId, channel_enabled: Object.fromEntries(draft.channels.map((item) => [item.channel, item.enabled])),
    nco_offset_hz: {},
    phase_offset_deg: Object.fromEntries(draft.channels.map((item) => [item.channel, item.calibrationPhaseDeg])), start_offset_ns: {} }
}
export function outputRfdc(boardId: string, draft: OutputDraft, base: BoardRfdcConfig): BoardRfdcConfig {
  const channels: RfdcChannelConfig[] = base.channels.map((source) => {
    const item = draft.channels[source.channel - 1]
    const plan = item.ncoMode === 'auto' ? ncoPlan(item.targetRfGhz) : { ncoMhz: item.ncoMhz, nyquistZone: item.nyquistZone }
    return { ...source, target_rf_hz: item.targetRfGhz * 1e9, nco_hz: (plan.ncoMhz + item.calibrationNcoMhz) * 1e6,
      nyquist_zone: plan.nyquistZone, data_offset_hz: item.dataOffsetMhz * 1e6, data_amplitude: item.dataAmplitude,
      data_phase_deg: item.dataPhaseDeg, nco_phase_deg: item.ncoPhaseDeg, dac_output_current_ma: item.dacCurrentMa }
  })
  return { ...base, board_id: boardId, channels }
}
