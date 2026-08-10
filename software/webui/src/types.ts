export type BoardState = 'OFFLINE' | 'IDLE' | 'READY' | 'ARMED' | 'RUNNING' | 'DONE' | 'FAULT' | 'MUTED'
export type RunState = 'QUEUED' | 'GENERATING' | 'UPLOADING' | 'READY' | 'ARMED' | 'RUNNING' | 'DONE' | 'FAULT' | 'ABORTED'
export type Role = 'admin' | 'user'

export interface UserRecord {
  id: number
  username: string
  role: Role
  enabled: boolean
  created_at: string
}

export interface LeaseRecord {
  id: number
  board_id: string
  user_id: number
  username: string
  status: 'active' | 'released' | 'forced'
  starts_at: string
  released_at?: string | null
}

export type UdpInterface = string

export interface BoardProfile {
  id: string
  name: string
  model: string
  ip: string
  port: number
  mac: string
  bootstrap_ip: string
  desired_ip: string
  active_ip: string
  desired_mac: string
  active_mac: string
  device_uid: string
  network_revision: number
  network_apply_status: 'unknown' | 'pending' | 'applied' | 'failed'
  network_apply_error: string
  udp_interface: UdpInterface
  udp_source_ip: string
  clock_source: 'onboard'
  target_profile: string
  jtag_cable_serial: string
  serial_path: string
  baud_rate: number
  serial_status: string
  serial_error: string
  location: string
  notes: string
  last_seen_at: string
  enabled: boolean
  lease?: LeaseRecord | null
}

export interface NetworkConfigSnapshot {
  board_id: string
  device_uid: string
  bootstrap_ip: string
  current_ip: string
  desired_ip: string
  current_mac: string
  desired_mac: string
  subnet_mask: string
  gateway: string
  port: number
  udp_interface: UdpInterface
  udp_source_ip: string
  revision: number
  apply_status: 'unknown' | 'pending' | 'applied' | 'failed'
  apply_error: string
  physical_link: boolean | null
  bootstrap_reachable: boolean
  active_reachable: boolean
  protocol_version: number
  capabilities: number
  link_state: number
}

export interface NetworkInterfaceInfo {
  name: UdpInterface
  present: boolean
  operstate: string
  carrier: boolean
  ipv4_addresses: string[]
  message: string
}

export interface BoardScanResult {
  interface: string
  target: string
  ok: boolean
  stage: 'host_nic' | 'discovery' | 'network_apply' | 'rfctrl2'
  board_id: string
  device_uid: string
  build_profile: string
  active_ip: string
  active_mac: string
  message: string
}

export interface BoardScanResponse {
  boards: BoardProfile[]
  interfaces: NetworkInterfaceInfo[]
  results: BoardScanResult[]
}

export interface CapabilityReport {
  source: string
  effective: string[]
  permitted: string[]
  ambient: string[]
  required: string[]
  missing: string[]
  ok: boolean
}

export interface BoardStatus {
  board_id: string
  state: BoardState
  online: boolean
  protocol_version: number
  hardware_profile: string
  sample_rate_hz: number
  interpolation: number
  axis_hz: number
  hmc_locked: boolean | null
  rfdc_ready: boolean | null
  rfdc_capabilities: number
  rfdc_config_valid_mask: number
  rfdc_config_busy: boolean
  playback_armed: boolean
  playback_prepared: boolean
  playback_running: boolean
  play_config_channel_mask: number
  play_fifo_valid_mask: number
  play_fifo_ready_mask: number
  play_executor_state: number
  play_ddr_read_counter: number
  play_bad_instr_count: number
  play_prefill_ready: boolean
  play_active_valid: boolean
  play_pending_valid: boolean
  rfdc_last_revision: number
  rfdc_last_error: number
  rfdc_last_error_stage: number
  rfdc_last_error_address: number
  underflow_mask: number
  error_count: number
  sync_epoch: number
  hardware_tick: number
  physical_link: boolean | null
  udp_interface: string
  udp_source_ip: string
  active_ip: string
  bootstrap_reachable: boolean
  network_configured: boolean
  device_uid: string
  network_revision: number
  network_apply_status: 'unknown' | 'pending' | 'applied' | 'failed'
  network_apply_error: string
  message: string
}

export interface PreflightCheck {
  key: string
  label: string
  state: 'pass' | 'warning' | 'fail' | 'info'
  message: string
}

export interface BoardPreflight {
  board_id: string
  can_start_live: boolean
  checks: PreflightCheck[]
  checked_at: string
}

export interface ManualChannel {
  channel: number
  enabled: boolean
  waveform: 'sine' | 'xy' | 'readout' | 'z'
  format: 'iq' | 'real'
  frequency_mhz: number
  data_offset_mhz?: number | null
  phase_deg: number
  amplitude: number
  data_amplitude?: number | null
  duration_ns: number
  delay_ns: number
  target_rf_mhz: number
  nco_mhz: number
  nyquist_zone: 1 | 2
  nco_phase_deg: number
}

export interface EzqChannel {
  channel: number
  enabled: boolean
  role: 'xy' | 'z' | 'readout'
  start_ns: number
  target_rf_mhz: number
  detune_mhz: number
  phase_deg: number
  amplitude: number
  duration_ns: number
  xy_gate: 'x_pi' | 'y_pi' | 'x_half' | 'y_half' | 'x12_pi' | 'x12_half' | 'spec'
  z_shape: 'square' | 'diabatic_cz'
}

export interface BoardOverride {
  board_id: string
  channel_enabled: Record<number, boolean>
  nco_offset_hz: Record<number, number>
  phase_offset_deg: Record<number, number>
  start_offset_ns: Record<number, number>
}

export interface WaveformRequest {
  name: string
  mode: 'manual' | 'ezq'
  loop: boolean
  record_duration_ns: number
  manual_channels: ManualChannel[]
  ezq_channels: EzqChannel[]
}

export interface BoardWaveformJob {
  board_id: string
  waveform: WaveformRequest
  override?: BoardOverride | null
  rfdc_config?: BoardRfdcConfig | null
}

export interface RfdcChannelConfig {
  channel: number
  dac_output_current_ma: number
  target_rf_hz: number
  nco_hz: number
  nyquist_zone: 1 | 2
  data_offset_hz: number
  data_amplitude: number
  data_phase_deg: number
  nco_phase_deg: number
  actual_nco_hz?: number | null
  actual_nyquist_zone?: 1 | 2 | null
  actual_nco_phase_deg?: number | null
  actual_dac_output_current_ma?: number | null
  nco_word?: number | null
  phase_word?: number | null
  vop_code?: number | null
  hardware_status: number
}

export interface BoardRfdcConfig {
  board_id: string
  channels: RfdcChannelConfig[]
  revision: number
  applied_at?: string | null
  apply_status: 'unknown' | 'pending' | 'applied' | 'partial' | 'failed'
  apply_error: string
  requested_mask: number
  applied_mask: number
  error_mask: number
  config_valid_mask: number
  failure_stage: number
  failure_address: number
  axi_response: number
}

export interface PreviewSeries {
  channel: number
  role: string
  domain: 'iq' | 'real'
  time_ns: number[]
  value: number[]
  i: number[]
  q: number[]
  active_start_ns: number | null
  active_end_ns: number | null
}

export interface PreviewResponse {
  sample_rate_hz: number
  record_duration_ns: number
  bytes_per_channel: number
  series: PreviewSeries[]
  fft_channel: number
  fft_frequency_mhz: number[]
  fft_db: number[]
  warnings: string[]
}

export interface RunRecord {
  id: string
  name: string
  state: RunState
  dry_run: boolean
  board_ids: string[]
  start_mode: string
  execution_mode: string
  created_at: string
  updated_at: string
  artifact_dir: string
  progress: number
  error: string
  completion_mode: 'upload' | 'one_shot'
  playback_mode: 'single' | 'continuous_sine'
  loaded: boolean
}

export type TestKind = 'amplitude' | 'frequency' | 'phase'
export type TestState = 'DRAFT' | 'RUNNING' | 'PAUSED' | 'COMPLETED' | 'ABORTED' | 'FAILED'
export interface PerformanceTestRecord {
  id: string
  name: string
  board_id: string
  kind: TestKind
  channel: number
  channels: number[]
  mode: 'automatic' | 'manual'
  state: TestState
  current_point: number
  total_points: number
  settle_ms: number
  auto_mute: boolean
  dry_run: boolean
  scan_axis: string
  scan_start: number | null
  scan_stop: number | null
  scan_step: number | null
  scan_unit: string
  created_at: string
  updated_at: string
  error: string
  environment: Record<string, unknown>
}
export interface PerformancePointRecord {
  id: string
  test_id: string
  index: number
  state: 'PENDING' | 'RUNNING' | 'READY' | 'MEASURED' | 'FAILED' | 'SKIPPED'
  parameters: Record<string, unknown>
  measurement: Record<string, unknown>
  error: string
  updated_at: string
}

export interface RunEvent {
  run_id: string
  timestamp: string
  level: 'info' | 'warning' | 'error'
  message: string
}

export interface DiscoveryResource {
  id: number
  kind: 'jtag' | 'serial'
  fingerprint: string
  label: string
  details: Record<string, unknown>
  state: 'pending' | 'registered'
  board_id?: string | null
  first_seen_at: string
  last_seen_at: string
}

export interface InventoryScanResult {
  serial: SerialPortInfo[]
  jtag: Array<Record<string, string>>
  network: BoardStatus[]
  scan_error: string
}

export interface SerialPortInfo {
  path: string
  stable_path: string
  manufacturer: string
  serial_number: string
  vendor_id: string
  product_id: string
  bound_board_id?: string | null
}

export interface SerialLogLine { line: string; created_at: string }

export interface ArtifactRecord {
  id: string
  label: string
  target_profile: string
  bit_name: string
  elf_name: string
  bit_sha256: string
  elf_sha256: string
  bit_size: number
  elf_size: number
  created_at: string
  created_by: string
}

export interface ProgramJob {
  id: string
  board_id: string
  artifact_id: string
  state: 'QUEUED' | 'PREFLIGHT' | 'RUNNING' | 'SUCCEEDED' | 'FAILED'
  progress: number
  created_at: string
  updated_at: string
  created_by: string
  error: string
}

export interface AuditEvent {
  id: number
  type: string
  message: string
  username?: string | null
  board_id?: string | null
  created_at: string
  metadata: Record<string, unknown>
}
