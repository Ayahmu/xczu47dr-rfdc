<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { Activity, AlarmSmoke, Boxes, Cable, CircleCheck, CircleX, ClipboardList, Copy, Cpu, Crosshair, Download, Gauge, Info, KeyRound, LogOut, Pause, Play, RadioTower, RefreshCw, Save, Search, Settings2, ShieldCheck, Square, Terminal, Trash2, TriangleAlert, Upload, UserCog, Waves } from 'lucide-vue-next'
import { ElMessage } from 'element-plus'
import WavePreview from './components/WavePreview.vue'
import type { ArtifactRecord, AuditEvent, BoardOverride, BoardPreflight, BoardProfile, BoardRfdcConfig, BoardStatus, DiscoveryResource, EzqChannel, InventoryScanResult, ManualChannel, NetworkInterfaceInfo, PerformancePointRecord, PerformanceTestRecord, PreflightCheck, PreviewResponse, ProgramJob, RfdcChannelConfig, RunEvent, RunRecord, SerialLogLine, SerialPortInfo, UserRecord, WaveformRequest } from './types'

type View = 'overview' | 'editor' | 'run' | 'performance' | 'monitor' | 'boards' | 'serial' | 'program' | 'history' | 'users'
const activeView = ref<View>('overview')
const user = ref<UserRecord | null>(null)
const csrfToken = ref('')
const loginForm = reactive({ username: '', password: '' })
const loginBusy = ref(false)
const boards = ref<BoardProfile[]>([])
const statuses = ref<BoardStatus[]>([])
const runs = ref<RunRecord[]>([])
const events = ref<RunEvent[]>([])
const discoveries = ref<DiscoveryResource[]>([])
const networkInterfaces = ref<NetworkInterfaceInfo[]>([])
const inventoryScan = ref<InventoryScanResult | null>(null)
const preflight = ref<BoardPreflight | null>(null)
const preflightArtifactId = ref('')
const serialPorts = ref<SerialPortInfo[]>([])
const serialLines = ref<SerialLogLine[]>([])
const serialPaused = ref(false)
const artifacts = ref<ArtifactRecord[]>([])
const programJobs = ref<ProgramJob[]>([])
const selectedProgramId = ref('')
const programLines = ref<SerialLogLine[]>([])
const auditEvents = ref<AuditEvent[]>([])
const rfdcConfig = ref<BoardRfdcConfig | null>(null)
const performanceTests = ref<PerformanceTestRecord[]>([])
const selectedTestId = ref('')
const performancePoints = ref<PerformancePointRecord[]>([])
const testPointSpec = ref('2.25, 20, 40.5')
const testAuxSpec = ref('0.5')
const testAmplitudeAxis = ref<'dac_current' | 'data_amplitude'>('dac_current')
const measurementText = ref('{}')
const testForm = reactive({ name: 'RFDC 幅值测试', kind: 'amplitude' as 'amplitude' | 'frequency' | 'phase', mode: 'automatic' as 'automatic' | 'manual', channel: 1, channels: [1], settle_ms: 100, auto_mute: true, dry_run: false })
const users = ref<UserRecord[]>([])
const preview = ref<PreviewResponse | null>(null)
const selectedBoardId = ref('')
const selectedRunId = ref('')
const loadingPreview = ref(false)
const creatingRun = ref(false)
const scanning = ref(false)
const dryRun = ref(false)
const websocketState = ref<'connected' | 'offline'>('offline')
const boardDialog = ref(false)
const editingBoardId = ref<string | null>(null)
const artifactBit = ref<File | null>(null)
const artifactElf = ref<File | null>(null)
const artifactForm = reactive({ label: '', target_profile: 'custom_xczu47dr' })
const userForm = reactive({ username: '', password: '', role: 'user' as 'admin' | 'user' })
let websocket: WebSocket | null = null
let reconnectTimer = 0

const manualChannels = reactive<ManualChannel[]>(Array.from({ length: 8 }, (_, index) => ({
  channel: index + 1, enabled: index < 2, waveform: 'iq-sine', frequency_mhz: index < 4 ? 20 + index * 10 : 0,
  phase_deg: index * 45, amplitude: 12000, data_amplitude: null, duration_ns: 500,
})))
const ezqChannels = reactive<EzqChannel[]>(Array.from({ length: 8 }, (_, index) => {
  const channel = index + 1
  const role = channel <= 4 ? 'xy' : channel <= 6 ? 'z' : 'readout'
  return { channel, enabled: true, role, start_ns: index * 180, target_rf_mhz: role === 'xy' ? 4500 : role === 'z' ? 0 : channel === 7 ? 5800 : 6200, detune_mhz: 0, phase_deg: index * 45, amplitude: role === 'xy' ? 0.3 : role === 'z' ? 0.2 : 0.25, duration_ns: role === 'xy' ? 120 : role === 'z' ? 240 : 1000, xy_gate: 'x_pi', z_shape: 'square' }
}))
const waveform = reactive<WaveformRequest>({ name: '单板 8 通道任务', mode: 'manual', record_duration_ns: 10000, manual_channels: manualChannels, ezq_channels: ezqChannels })
const override = reactive<BoardOverride>({ board_id: '', channel_enabled: {}, nco_offset_hz: {}, phase_offset_deg: {}, start_offset_ns: {} })
const boardForm = reactive({
  name: '', model: 'XCZU47DR RFDC', role: 'master' as 'master' | 'follower', ip: '192.168.1.128', port: 1234, mac: '',
  udp_interface: 'enp225s0f0' as 'enp225s0f0' | 'enp225s0f1', udp_source_ip: '192.168.1.10', clock_source: 'onboard' as 'onboard' | 'master-10mhz',
  target_profile: 'custom_xczu47dr', sync_group: '', jtag_cable_serial: '', serial_path: '', baud_rate: 115200,
  location: '', notes: '', enabled: true,
})

const selectedBoard = computed(() => boards.value.find((item) => item.id === selectedBoardId.value) ?? null)
const selectedBoardFormInterface = computed(() => networkInterfaces.value.find((item) => item.name === boardForm.udp_interface) ?? null)
const selectedRun = computed(() => runs.value.find((item) => item.id === selectedRunId.value) ?? null)
const latestStatus = computed(() => new Map(statuses.value.map((item) => [item.board_id, item])))
const detectedJtagSerials = computed(() => new Set(
  discoveries.value
    .filter((item) => item.kind === 'jtag' && item.details.scan_scope === 'linux-usb')
    .map((item) => String(item.details.cable_serial ?? ''))
    .filter(Boolean),
))
const selectedRunBoardStatus = computed(() => {
  const boardId = selectedRun.value?.board_ids[0]
  return boardId ? latestStatus.value.get(boardId) ?? null : null
})
const canOperateLive = computed(() => Boolean(selectedBoard.value && user.value && selectedBoard.value.lease?.user_id === user.value.id))
const navigation = computed<Array<{ id: View; label: string; icon: typeof Gauge }>>(() => {
  const result = [
    { id: 'overview' as View, label: '板卡总览', icon: Gauge }, { id: 'editor' as View, label: '单板发波', icon: Waves },
    { id: 'run' as View, label: '单板运行', icon: Crosshair }, { id: 'performance' as View, label: '性能测试', icon: Activity }, { id: 'monitor' as View, label: '状态监控', icon: Activity },
    { id: 'serial' as View, label: '串口输出', icon: Terminal }, { id: 'history' as View, label: '任务历史', icon: ClipboardList },
  ]
  if (user.value?.role === 'admin') result.splice(4, 0,
    { id: 'boards', label: '板卡管理', icon: Boxes }, { id: 'program', label: 'JTAG 部署', icon: Cpu },
    { id: 'users', label: '用户与审计', icon: UserCog },
  )
  return result
})

async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers)
  if (!(options.body instanceof FormData)) headers.set('Content-Type', 'application/json')
  if (options.method && options.method !== 'GET') headers.set('X-CSRF-Token', csrfToken.value)
  const response = await fetch(path, { ...options, headers, credentials: 'include' })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    if (response.status === 401) user.value = null
    throw new Error(payload.detail ?? response.statusText)
  }
  return payload as T
}
function stateType(state?: string) {
  if (['RUNNING', 'READY', 'ARMED'].includes(state || '')) return 'success'
  if (['FAULT', 'OFFLINE', 'FAILED'].includes(state || '')) return 'danger'
  if (state === 'MUTED') return 'warning'
  return 'info'
}
function boardIsDetected(board: BoardProfile) {
  return Boolean(board.jtag_cable_serial && detectedJtagSerials.value.has(board.jtag_cable_serial))
}
function boardPresenceLabel(board: BoardProfile) {
  if (!board.jtag_cable_serial) return '未绑定'
  return boardIsDetected(board) ? 'ONLINE' : '未检测'
}
function networkStateLabel(status?: BoardStatus | null) {
  return status?.online ? status.state : '未响应'
}
function networkInterfaceLabel(item: NetworkInterfaceInfo) {
  const state = item.carrier ? '已连接' : item.present ? '无载波' : '不存在'
  const addresses = item.ipv4_addresses.length ? item.ipv4_addresses.join(', ') : '无 IPv4'
  return `${item.name} · ${state} · ${addresses}`
}
function roleLabel(channel: number) { return channel <= 4 ? 'XY' : channel <= 6 ? 'Z' : 'RO' }
function preflightIcon(state: PreflightCheck['state']) {
  return state === 'pass' ? CircleCheck : state === 'fail' ? CircleX : state === 'warning' ? TriangleAlert : Info
}
function updateRun(record: RunRecord) {
  const index = runs.value.findIndex((item) => item.id === record.id)
  if (index >= 0) runs.value[index] = record; else runs.value.unshift(record)
  if (!selectedRunId.value) selectedRunId.value = record.id
}
function updateBoardStatus(record: BoardStatus) {
  const index = statuses.value.findIndex((item) => item.board_id === record.board_id)
  if (index >= 0) statuses.value[index] = record; else statuses.value.push(record)
}
async function refreshRunBoardStatus(boardId: string) {
  updateBoardStatus(await api<BoardStatus>(`/api/boards/${boardId}/status?refresh=false`))
}
function runPayloadLabel(record: RunRecord) {
  if (record.dry_run && record.state === 'DONE') return '生成校验完成 · 未下发'
  if (record.loaded) return '板卡已加载波形'
  if (record.completion_mode === 'one_shot' && record.state === 'DONE') return '单次发波已结束'
  if (['DONE', 'FAULT', 'ABORTED'].includes(record.state)) return '任务已结束'
  return '处理中'
}
function updatePerformanceTest(record: PerformanceTestRecord) {
  const index = performanceTests.value.findIndex((item) => item.id === record.id)
  if (index >= 0) performanceTests.value[index] = record; else performanceTests.value.unshift(record)
  if (!selectedTestId.value) selectedTestId.value = record.id
}
async function restoreSession() {
  const session = await api<{ user: UserRecord | null; csrf_token: string | null }>('/api/auth/me')
  user.value = session.user; csrfToken.value = session.csrf_token ?? ''
}
async function login() {
  loginBusy.value = true
  try {
    const session = await api<{ user: UserRecord; csrf_token: string }>('/api/auth/login', { method: 'POST', body: JSON.stringify(loginForm) })
    user.value = session.user; csrfToken.value = session.csrf_token
    await refreshAll(); await generatePreview(); connectEvents()
  } catch (error) { ElMessage.error(`登录失败: ${(error as Error).message}`) }
  finally { loginBusy.value = false }
}
async function logout() {
  try { await api('/api/auth/logout', { method: 'POST' }) } finally { websocket?.close(); user.value = null; csrfToken.value = '' }
}
function syncSelection(next: BoardProfile[]) {
  if (!next.some((item) => item.id === selectedBoardId.value)) selectedBoardId.value = next[0]?.id ?? ''
  override.board_id = selectedBoardId.value
}
async function refreshAll() {
  if (!user.value) return
  try {
    const basic = await Promise.all([
      api<BoardProfile[]>('/api/boards'), api<BoardStatus[]>('/api/boards/status'), api<RunRecord[]>('/api/runs'),
      api<ArtifactRecord[]>('/api/artifacts'), api<ProgramJob[]>('/api/programs'), api<DiscoveryResource[]>('/api/discovery'), api<PerformanceTestRecord[]>('/api/tests'),
      api<NetworkInterfaceInfo[]>('/api/network/interfaces'),
    ])
    boards.value = basic[0]; statuses.value = basic[1]; runs.value = basic[2]; artifacts.value = basic[3]; programJobs.value = basic[4]; discoveries.value = basic[5]; performanceTests.value = basic[6]; networkInterfaces.value = basic[7]
    syncSelection(boards.value)
    if (!selectedRunId.value && runs.value[0]) selectedRunId.value = runs.value[0].id
    if (!selectedTestId.value && performanceTests.value[0]) selectedTestId.value = performanceTests.value[0].id
    if (user.value.role === 'admin') [users.value, auditEvents.value] = await Promise.all([api<UserRecord[]>('/api/admin/users'), api<AuditEvent[]>('/api/audit')])
  } catch (error) { ElMessage.error(`刷新失败: ${(error as Error).message}`) }
}
async function refreshRfdcConfig(fromPl = false) {
  if (!selectedBoardId.value) return
  try { rfdcConfig.value = await api<BoardRfdcConfig>(`/api/boards/${selectedBoardId.value}/rfdc-config?refresh=${fromPl}`) }
  catch (error) { ElMessage.error(`RFDC 配置读取失败: ${(error as Error).message}`) }
}
function selectedChannelMask() {
  const channels = waveform.mode === 'manual' ? manualChannels : ezqChannels
  return channels.reduce((mask, channel) => channel.enabled ? mask | (1 << (channel.channel - 1)) : mask, 0)
}
function rfdcCurrentRange(channel: number) { return channel === 5 || channel === 6 ? { min: 6.4, max: 32 } : { min: 2.25, max: 40.5 } }
function rfdcCurrentInvalid(channel: RfdcChannelConfig) {
  const range = rfdcCurrentRange(channel.channel)
  return channel.dac_output_current_ma < range.min || channel.dac_output_current_ma > range.max
}
async function applyRfdcConfig() {
  if (!selectedBoard.value || !rfdcConfig.value) return
  if (!canOperateLive.value) return ElMessage.warning('应用板端参数前需要申请当前板卡使用权')
  try {
    const channelMask = selectedChannelMask()
    if (!channelMask) return ElMessage.warning('请至少启用一个通道')
    rfdcConfig.value = await api<BoardRfdcConfig>(`/api/boards/${selectedBoard.value.id}/rfdc-config/apply`, { method: 'POST', body: JSON.stringify({ channels: rfdcConfig.value.channels, channel_mask: channelMask }) })
    if (rfdcConfig.value.apply_status === 'partial') ElMessage.warning(`PL 仅确认部分通道，error mask 0x${rfdcConfig.value.error_mask.toString(16).padStart(2, '0')}`)
    else ElMessage.success(`PL 已回读确认 RFDC 参数，revision ${rfdcConfig.value.revision}`)
  } catch (error) { ElMessage.error(`RFDC 参数应用失败: ${(error as Error).message}`) }
}
function parseNumbers(value: string) {
  return value.split(/[,，\s]+/).map((item) => Number(item.trim())).filter((item) => Number.isFinite(item))
}
function performancePointPayload() {
  const values = parseNumbers(testPointSpec.value)
  const aux = parseNumbers(testAuxSpec.value)[0] ?? 0
  if (!values.length) throw new Error('请至少输入一个测试点')
  if (testForm.kind === 'amplitude') {
    return testAmplitudeAxis.value === 'dac_current'
      ? values.map((value) => ({ dac_output_current_ma: value, data_amplitude: aux }))
      : values.map((value) => ({ data_amplitude: value, dac_output_current_ma: aux }))
  }
  if (testForm.kind === 'frequency') return values.map((value) => ({ target_rf_hz: value * (value < 100000 ? 1e6 : 1), data_offset_hz: aux * 1e6 }))
  return values.map((value) => ({ data_phase_deg: value, nco_phase_deg: aux }))
}
async function loadPerformancePoints() {
  if (!selectedTestId.value) { performancePoints.value = []; return }
  try { performancePoints.value = await api<PerformancePointRecord[]>(`/api/tests/${selectedTestId.value}/points`) }
  catch (error) { ElMessage.error(`测试点读取失败: ${(error as Error).message}`) }
}
async function createPerformanceTest() {
  if (!selectedBoard.value) return ElMessage.warning('请先选择板卡')
  try {
    const record = await api<PerformanceTestRecord>('/api/tests', { method: 'POST', body: JSON.stringify({ ...testForm, board_id: selectedBoard.value.id, points: performancePointPayload() }) })
    updatePerformanceTest(record); await loadPerformancePoints(); ElMessage.success('性能测试已创建')
  } catch (error) { ElMessage.error(`测试创建失败: ${(error as Error).message}`) }
}
async function startPerformanceTest() {
  if (!selectedTestId.value) return
  try { updatePerformanceTest(await api<PerformanceTestRecord>(`/api/tests/${selectedTestId.value}/start`, { method: 'POST' })); await loadPerformancePoints() }
  catch (error) { ElMessage.error(`测试启动失败: ${(error as Error).message}`) }
}
async function pausePerformanceTest() {
  if (!selectedTestId.value) return
  try { updatePerformanceTest(await api<PerformanceTestRecord>(`/api/tests/${selectedTestId.value}/pause`, { method: 'POST' })) }
  catch (error) { ElMessage.error(`测试暂停失败: ${(error as Error).message}`) }
}
async function abortPerformanceTest() {
  if (!selectedTestId.value) return
  try { updatePerformanceTest(await api<PerformanceTestRecord>(`/api/tests/${selectedTestId.value}/abort`, { method: 'POST' })) }
  catch (error) { ElMessage.error(`测试取消失败: ${(error as Error).message}`) }
}
async function executePerformancePoint(index: number) {
  if (!selectedTestId.value) return
  try { await api(`/api/tests/${selectedTestId.value}/points/${index}/execute`, { method: 'POST' }); await loadPerformancePoints() }
  catch (error) { ElMessage.error(`测试点执行失败: ${(error as Error).message}`) }
}
async function recordMeasurement(index: number) {
  if (!selectedTestId.value) return
  try {
    const measurement = JSON.parse(measurementText.value)
    await api(`/api/tests/${selectedTestId.value}/points/${index}/measurement`, { method: 'POST', body: JSON.stringify(measurement) }); await loadPerformancePoints()
  } catch (error) { ElMessage.error(`测量值保存失败: ${(error as Error).message}`) }
}
function exportPerformance(extension: 'csv' | 'json') {
  if (selectedTestId.value) window.location.href = `/api/tests/${selectedTestId.value}/export.${extension}`
}
async function refreshStatus() {
  try { statuses.value = await api<BoardStatus[]>('/api/boards/status?refresh=true'); await refreshPreflight(false) }
  catch (error) { ElMessage.error(`状态读取失败: ${(error as Error).message}`) }
}
async function refreshPreflight(refresh = true) {
  if (!selectedBoardId.value) return
  const query = new URLSearchParams({ refresh: String(refresh) })
  if (preflightArtifactId.value) query.set('artifact_id', preflightArtifactId.value)
  try { preflight.value = await api<BoardPreflight>(`/api/boards/${selectedBoardId.value}/preflight?${query}`) }
  catch (error) { ElMessage.error(`预检失败: ${(error as Error).message}`) }
}
async function toggleLease(board: BoardProfile, force = false) {
  try {
    if (!board.lease) await api(`/api/boards/${board.id}/lease`, { method: 'POST' })
    else if (force) await api(`/api/admin/boards/${board.id}/force-release`, { method: 'POST' })
    else await api(`/api/boards/${board.id}/release`, { method: 'POST' })
    await refreshAll()
  } catch (error) { ElMessage.error(`使用权操作失败: ${(error as Error).message}`) }
}
async function generatePreview() {
  loadingPreview.value = true
  try { syncWaveformFromRfdc(); preview.value = await api('/api/waveforms/preview', { method: 'POST', body: JSON.stringify({ waveform, override, fft_channel: 1 }) }) }
  catch (error) { ElMessage.error(`预览失败: ${(error as Error).message}`) }
  finally { loadingPreview.value = false }
}
async function createRun() {
  if (!selectedBoard.value) return ElMessage.warning('请先选择板卡')
  syncWaveformFromRfdc()
  if (!dryRun.value && !canOperateLive.value) return ElMessage.warning('真实发波前需要申请这块板卡的使用权')
  if (!dryRun.value && !window.confirm(`将向 ${selectedBoard.value.name} 上传波形。继续？`)) return
  creatingRun.value = true
  try {
    const record = await api<RunRecord>('/api/runs', { method: 'POST', body: JSON.stringify({ jobs: [{ board_id: selectedBoard.value.id, waveform, override, rfdc_config: rfdcConfig.value }], dry_run: dryRun.value, execution_mode: 'single' }) })
    updateRun(record); selectedRunId.value = record.id; activeView.value = 'run'
  } catch (error) { ElMessage.error(`创建任务失败: ${(error as Error).message}`) }
  finally { creatingRun.value = false }
}
function syncWaveformFromRfdc() {
  if (waveform.mode !== 'manual' || !rfdcConfig.value) return
  for (const channel of rfdcConfig.value.channels) {
    const target = manualChannels[channel.channel - 1]
    if (!target) continue
    target.data_amplitude = channel.data_amplitude
    target.amplitude = Math.round(Math.abs(channel.data_amplitude) * 32767)
    target.frequency_mhz = channel.data_offset_hz / 1e6
    target.phase_deg = channel.data_phase_deg
  }
}
async function runAction(action: 'arm' | 'start' | 'abort') {
  if (!selectedRun.value) return
  if (action === 'abort' && !window.confirm('将停止并静音当前板卡。继续？')) return
  try {
    const record = await api<RunRecord>(`/api/runs/${selectedRun.value.id}/${action}`, { method: 'POST' })
    updateRun(record)
    await refreshRunBoardStatus(record.board_ids[0])
    ElMessage.success(action === 'arm' ? '板卡已 ARM' : action === 'start' ? '触发命令已确认' : '板卡已停止并静音')
  }
  catch (error) { ElMessage.error(`${action} 失败: ${(error as Error).message}`) }
}
async function loadedBoardAction(action: 'arm' | 'trigger' | 'abort') {
  const boardId = selectedRun.value?.board_ids[0]
  if (!boardId) return
  if (action === 'abort' && !window.confirm('将停止并静音当前板卡。继续？')) return
  try {
    updateRun(await api<RunRecord>(`/api/boards/${boardId}/${action}`, { method: 'POST' }))
    await refreshRunBoardStatus(boardId)
    ElMessage.success(action === 'arm' ? 'ARM 已完成，板卡已进入 PREPARED' : action === 'trigger' ? 'TRIGGER 已确认，板卡正在发波' : '板卡已停止并静音')
  }
  catch (error) { ElMessage.error(`${action} 失败: ${(error as Error).message}`) }
}
function prepareLiveUpload() {
  const boardId = selectedRun.value?.board_ids[0]
  if (boardId) selectedBoardId.value = boardId
  dryRun.value = false
  activeView.value = 'editor'
  ElMessage.info('已切换为真实发送，请确认参数并点击“上传到本板”')
}
async function scanInventory() {
  scanning.value = true
  try {
    inventoryScan.value = await api<InventoryScanResult>('/api/admin/discovery/scan', { method: 'POST' })
    discoveries.value = await api('/api/discovery'); statuses.value = inventoryScan.value.network
  }
  catch (error) { ElMessage.error(`扫描失败: ${(error as Error).message}`) }
  finally { scanning.value = false }
}
function openBoardEditor(board?: BoardProfile) {
  editingBoardId.value = board?.id ?? null
  Object.assign(boardForm, board ? {
    name: board.name, model: board.model, role: board.role, ip: board.ip, port: board.port, mac: board.mac,
    udp_interface: board.udp_interface, udp_source_ip: board.udp_source_ip, clock_source: board.clock_source,
    target_profile: board.target_profile, sync_group: board.sync_group, jtag_cable_serial: board.jtag_cable_serial,
    serial_path: board.serial_path, baud_rate: board.baud_rate, location: board.location, notes: board.notes, enabled: board.enabled,
  } : { name: '', model: 'XCZU47DR RFDC', role: 'master', ip: '192.168.1.128', port: 1234, mac: '', udp_interface: 'enp225s0f0', udp_source_ip: '192.168.1.10', clock_source: 'onboard', target_profile: 'custom_xczu47dr', sync_group: '', jtag_cable_serial: '', serial_path: '', baud_rate: 115200, location: '', notes: '', enabled: true })
  boardDialog.value = true
}
async function saveBoard() {
  try {
    const path = editingBoardId.value ? `/api/admin/boards/${editingBoardId.value}` : '/api/admin/boards'
    await api(path, { method: editingBoardId.value ? 'PATCH' : 'POST', body: JSON.stringify(boardForm) })
    boardDialog.value = false; await refreshAll()
  } catch (error) { ElMessage.error(`保存失败: ${(error as Error).message}`) }
}
async function refreshSerial() {
  if (!selectedBoardId.value) return
  try { [serialPorts.value, serialLines.value] = await Promise.all([api<SerialPortInfo[]>('/api/serial/ports'), api<SerialLogLine[]>(`/api/serial/${selectedBoardId.value}/logs`)]) }
  catch (error) { ElMessage.error(`串口读取失败: ${(error as Error).message}`) }
}
async function toggleSerialPause() {
  serialPaused.value = !serialPaused.value
  if (!serialPaused.value) await refreshSerial()
}
function linesAsText(lines: SerialLogLine[]) {
  return lines.map((item) => `${new Date(item.created_at).toLocaleString()} ${item.line}`).join('\n')
}
async function copyLines(lines: SerialLogLine[]) {
  const content = linesAsText(lines)
  try {
    await navigator.clipboard.writeText(content)
  } catch {
    const field = document.createElement('textarea')
    field.value = content; field.style.position = 'fixed'; field.style.opacity = '0'
    document.body.appendChild(field); field.select(); document.execCommand('copy'); field.remove()
  }
  ElMessage.success('日志已复制')
}
function downloadLines(lines: SerialLogLine[], filename: string) {
  const url = URL.createObjectURL(new Blob([linesAsText(lines)], { type: 'text/plain;charset=utf-8' }))
  const anchor = document.createElement('a')
  anchor.href = url; anchor.download = filename; anchor.click(); URL.revokeObjectURL(url)
}
async function bindSerial(path: string) {
  if (!selectedBoard.value) return
  try {
    await api(`/api/admin/boards/${selectedBoard.value.id}/serial`, { method: 'POST', body: JSON.stringify({ path, baud_rate: selectedBoard.value.baud_rate || 115200 }) })
    await refreshAll(); await refreshSerial()
  } catch (error) { ElMessage.error(`串口绑定失败: ${(error as Error).message}`) }
}
function chooseFile(event: Event, kind: 'bit' | 'elf') {
  const file = (event.target as HTMLInputElement).files?.[0] ?? null
  if (kind === 'bit') artifactBit.value = file; else artifactElf.value = file
}
async function uploadArtifact() {
  if (!artifactBit.value || !artifactElf.value || !artifactForm.label) return ElMessage.warning('请选择 bit、ELF 并填写版本名称')
  const form = new FormData()
  form.append('label', artifactForm.label); form.append('target_profile', artifactForm.target_profile); form.append('bitstream', artifactBit.value); form.append('firmware', artifactElf.value)
  try { await api('/api/admin/artifacts', { method: 'POST', body: form }); artifactForm.label = ''; artifacts.value = await api('/api/artifacts') }
  catch (error) { ElMessage.error(`上传失败: ${(error as Error).message}`) }
}
async function programBoard(artifact: ArtifactRecord) {
  if (!selectedBoard.value) return ElMessage.warning('请先选择目标板卡')
  if (!window.confirm(`将复位并重新部署 ${selectedBoard.value.name}。继续？`)) return
  try {
    const job = await api<ProgramJob>(`/api/admin/boards/${selectedBoard.value.id}/programs`, { method: 'POST', body: JSON.stringify({ artifact_id: artifact.id }) })
    programJobs.value = await api('/api/programs'); await selectProgram(job)
  }
  catch (error) { ElMessage.error(`部署任务创建失败: ${(error as Error).message}`) }
}
async function selectProgram(job: ProgramJob) {
  selectedProgramId.value = job.id
  try { programLines.value = await api<SerialLogLine[]>(`/api/programs/${job.id}/logs`) }
  catch (error) { ElMessage.error(`部署日志读取失败: ${(error as Error).message}`) }
}
async function addUser() {
  try { await api('/api/admin/users', { method: 'POST', body: JSON.stringify({ ...userForm, enabled: true }) }); userForm.username = ''; userForm.password = ''; users.value = await api('/api/admin/users') }
  catch (error) { ElMessage.error(`用户创建失败: ${(error as Error).message}`) }
}
async function updateUserAccount(account: UserRecord, password?: string) {
  try {
    await api(`/api/admin/users/${account.id}`, { method: 'PATCH', body: JSON.stringify({ role: account.role, enabled: account.enabled, password: password || null }) })
    users.value = await api('/api/admin/users')
  } catch (error) {
    ElMessage.error(`用户更新失败: ${(error as Error).message}`)
    users.value = await api('/api/admin/users')
  }
}
async function resetUserPassword(account: UserRecord) {
  const password = window.prompt(`为 ${account.username} 设置新密码（至少 8 位）`)
  if (password === null) return
  if (password.length < 8) return ElMessage.warning('密码至少需要 8 位')
  await updateUserAccount(account, password)
}
function connectEvents() {
  websocket?.close(); window.clearTimeout(reconnectTimer)
  if (!user.value) return
  const protocol = location.protocol === 'https:' ? 'wss' : 'ws'
  websocket = new WebSocket(`${protocol}://${location.host}/api/events`)
  websocket.onopen = () => { websocketState.value = 'connected' }
  websocket.onmessage = (message) => {
    const event = JSON.parse(message.data) as { type: string; data?: unknown }
    if (event.type === 'run.update') updateRun(event.data as RunRecord)
    if (event.type === 'run.done') {
      const record = event.data as RunRecord
      updateRun(record)
      if (!record.dry_run) void refreshRunBoardStatus(record.board_ids[0])
    }
    if (event.type === 'run.event') events.value.unshift(event.data as RunEvent)
    if (event.type === 'test.point.updated') { const point = event.data as PerformancePointRecord; const index = performancePoints.value.findIndex((item) => item.id === point.id); if (index >= 0) performancePoints.value[index] = point; else if (point.test_id === selectedTestId.value) performancePoints.value.push(point) }
    if (event.type === 'test.completed') updatePerformanceTest(event.data as PerformanceTestRecord)
    if (event.type === 'inventory.updated') void refreshAll()
    if (event.type === 'programming.updated') {
      const job = event.data as ProgramJob; const index = programJobs.value.findIndex((item) => item.id === job.id)
      if (index >= 0) programJobs.value[index] = job; else programJobs.value.unshift(job)
    }
    if (event.type === 'programming.log') {
      const line = event.data as { job_id: string; line: string }
      if (line.job_id === selectedProgramId.value) programLines.value.push({ line: line.line, created_at: new Date().toISOString() })
    }
    if (!serialPaused.value && event.type === 'serial.line' && (event.data as { board_id: string }).board_id === selectedBoardId.value) serialLines.value.push(event.data as SerialLogLine)
  }
  websocket.onclose = () => { websocketState.value = 'offline'; if (user.value) reconnectTimer = window.setTimeout(connectEvents, 2000) }
}
watch(selectedBoardId, (value) => {
  override.board_id = value
  void refreshRfdcConfig()
  if (activeView.value === 'serial') void refreshSerial()
  if (activeView.value === 'monitor') void refreshPreflight()
})
watch(preflightArtifactId, () => { if (activeView.value === 'monitor') void refreshPreflight(false) })
watch(activeView, (value) => {
  if (value === 'serial') void refreshSerial()
  if (value === 'monitor') void refreshPreflight()
  if (value === 'program' && !selectedProgramId.value && programJobs.value[0]) void selectProgram(programJobs.value[0])
  if (value === 'performance') { void refreshRfdcConfig(); void loadPerformancePoints() }
})
watch(selectedTestId, () => { void loadPerformancePoints() })
watch(() => rfdcConfig.value?.channels.map((item) => item.target_rf_hz).join(','), () => {
  for (const channel of rfdcConfig.value?.channels ?? []) {
    channel.nco_hz = channel.target_rf_hz < 3200000000 ? channel.target_rf_hz : channel.target_rf_hz - 6400000000
    channel.nyquist_zone = channel.target_rf_hz < 3200000000 ? 1 : 2
  }
})
onMounted(async () => {
  try { await restoreSession() } catch { user.value = null }
  if (user.value) { await refreshAll(); await generatePreview(); connectEvents() }
})
onBeforeUnmount(() => { websocket?.close(); window.clearTimeout(reconnectTimer) })
</script>

<template>
  <div v-if="!user" class="login-shell">
    <form class="login-panel" @submit.prevent="login">
      <div class="login-brand"><RadioTower :size="28" /><div><strong>XCZU47DR RFDC</strong><span>实验室板卡控制台</span></div></div>
      <el-input v-model="loginForm.username" autocomplete="username" placeholder="用户名" />
      <el-input v-model="loginForm.password" type="password" show-password autocomplete="current-password" placeholder="密码" />
      <el-button type="primary" native-type="submit" :loading="loginBusy">登录</el-button>
    </form>
  </div>
  <div v-else class="app-shell">
    <aside class="sidebar">
      <div class="brand-mark"><RadioTower :size="23" /></div>
      <nav class="side-nav"><el-tooltip v-for="item in navigation" :key="item.id" :content="item.label" placement="right"><button class="nav-icon" :class="{ active: activeView === item.id }" :aria-label="item.label" @click="activeView = item.id"><component :is="item.icon" :size="20" /></button></el-tooltip></nav>
      <el-tooltip content="退出登录" placement="right"><button class="nav-icon bottom-action" @click="logout"><LogOut :size="19" /></button></el-tooltip>
    </aside>
    <div class="workspace">
      <header class="topbar">
        <div class="product-title"><span class="eyebrow">单板优先控制台</span><h1>XCZU47DR RFDC</h1></div>
        <div class="board-strip"><el-select v-model="selectedBoardId" class="board-select" placeholder="选择板卡"><el-option v-for="board in boards" :key="board.id" :label="board.name" :value="board.id" /></el-select><div v-if="selectedBoard" class="board-indicator"><span class="state-dot" :class="{ online: boardIsDetected(selectedBoard) }"></span><span>{{ selectedBoard.ip }}</span><el-tag size="small" :type="boardIsDetected(selectedBoard) ? 'success' : 'info'">{{ boardPresenceLabel(selectedBoard) }}</el-tag></div><el-tag size="small" :type="websocketState === 'connected' ? 'success' : 'info'">{{ websocketState === 'connected' ? 'LIVE' : 'RECONNECTING' }}</el-tag><div class="user-chip"><ShieldCheck :size="16" />{{ user.username }}</div></div>
      </header>
      <main class="main-content">
        <section v-if="activeView === 'overview'" class="view-stack">
          <div class="section-heading"><div><span class="eyebrow">设备与使用权</span><h2>板卡总览</h2></div><el-button :icon="RefreshCw" @click="refreshAll">刷新</el-button></div>
          <div class="board-grid"><article v-for="board in boards" :key="board.id" class="board-card" :class="{ selected: board.id === selectedBoardId }" @click="selectedBoardId = board.id"><div class="board-card-head"><div><h3>{{ board.name }}</h3><span>{{ board.model }} · {{ board.location || '服务器' }}</span></div><el-tag :type="boardIsDetected(board) ? 'success' : 'info'">{{ boardPresenceLabel(board) }}</el-tag></div><dl class="metric-list"><div><dt>网络</dt><dd>{{ board.ip }}:{{ board.port }}</dd></div><div><dt>JTAG</dt><dd>{{ board.jtag_cable_serial || '未登记' }}</dd></div><div><dt>串口</dt><dd>{{ board.serial_status }}</dd></div><div><dt>配置</dt><dd>{{ board.target_profile }}</dd></div></dl><div class="lease-row"><span>{{ board.lease ? `${board.lease.username} 正在使用` : '当前空闲' }}</span><el-button v-if="!board.lease" size="small" type="primary" @click.stop="toggleLease(board)">申请使用</el-button><el-button v-else-if="board.lease.user_id === user.id" size="small" @click.stop="toggleLease(board)">释放</el-button><el-button v-else-if="user.role === 'admin'" size="small" type="danger" plain @click.stop="toggleLease(board, true)">强制释放</el-button></div></article></div>
          <section class="surface"><div class="surface-head"><h3>最近单板任务</h3><ClipboardList :size="18" /></div><el-table :data="runs.slice(0, 6)" size="small"><el-table-column prop="name" label="任务" /><el-table-column label="板卡"><template #default="scope">{{ scope.row.board_ids[0] }}</template></el-table-column><el-table-column prop="state" label="状态"><template #default="scope"><el-tag :type="stateType(scope.row.state)">{{ scope.row.state }}</el-tag></template></el-table-column></el-table></section>
        </section>

        <section v-else-if="activeView === 'editor'" class="editor-layout">
          <section v-if="rfdcConfig" class="surface rfdc-panel">
            <div class="surface-head"><div><span class="eyebrow">PL 配置 · revision {{ rfdcConfig.revision }} · valid 0x{{ rfdcConfig.config_valid_mask.toString(16).padStart(2, '0') }}</span><h3>RFDC 输出与频率</h3></div><div class="heading-actions"><el-tag :type="rfdcConfig.apply_status === 'applied' ? 'success' : rfdcConfig.apply_status === 'failed' || rfdcConfig.apply_status === 'partial' ? 'danger' : 'info'">{{ rfdcConfig.apply_status }}</el-tag><el-tooltip content="从 PL 回读配置"><el-button :icon="RefreshCw" @click="refreshRfdcConfig(true)" /></el-tooltip><el-button type="primary" @click="applyRfdcConfig">应用到 PL</el-button></div></div>
            <div class="rfdc-table"><div class="rfdc-head"><span>通道</span><span>DAC mA</span><span>目标 RF Hz</span><span>IQ 幅值</span><span>数据相位</span><span>NCO Hz</span><span>NCO 相位</span><span>PL 实际值</span></div><div v-for="channel in rfdcConfig.channels" :key="channel.channel" class="rfdc-row" :class="{ 'rfdc-invalid': rfdcCurrentInvalid(channel) }"><strong>CH{{ channel.channel }}</strong><el-input-number v-model="channel.dac_output_current_ma" :min="rfdcCurrentRange(channel.channel).min" :max="rfdcCurrentRange(channel.channel).max" :step="0.05" :precision="2" /><el-input-number v-model="channel.target_rf_hz" :min="0" :max="6400000000" :step="1000000" :controls="false" /><el-input-number v-model="channel.data_amplitude" :min="-1" :max="1" :step="0.01" :precision="3" /><el-input-number v-model="channel.data_phase_deg" :min="-3600" :max="3600" :step="1" /><el-input-number v-model="channel.nco_hz" :min="-3200000000" :max="3200000000" :step="1000000" :controls="false" /><el-input-number v-model="channel.nco_phase_deg" :min="-3600" :max="3600" :step="1" /><span class="rfdc-actual">{{ channel.actual_nco_hz == null ? '未确认' : `${channel.actual_nco_hz} Hz · ${channel.actual_dac_output_current_ma?.toFixed(3)} mA` }}</span></div></div>
            <p v-if="rfdcConfig.apply_error" class="form-error">{{ rfdcConfig.apply_error }}</p><p v-if="rfdcConfig.failure_address" class="form-error">阶段 {{ rfdcConfig.failure_stage }} · 寄存器 0x{{ rfdcConfig.failure_address.toString(16) }} · AXI {{ rfdcConfig.axi_response }}</p>
          </section>
          <section class="editor-panel"><div class="section-heading compact"><div><span class="eyebrow">{{ selectedBoard?.name || '未选择板卡' }}</span><h2>单板波形</h2></div><div class="heading-actions"><el-button :icon="RefreshCw" :loading="loadingPreview" @click="generatePreview">预览</el-button><el-button type="primary" :icon="dryRun ? Save : Upload" :loading="creatingRun" @click="createRun">{{ dryRun ? '生成校验' : '上传到本板' }}</el-button></div></div><div class="target-band"><Cpu :size="20" /><el-select v-model="selectedBoardId"><el-option v-for="board in boards.filter(item => item.enabled)" :key="board.id" :label="`${board.name} · ${board.ip}`" :value="board.id" /></el-select><el-tag :type="canOperateLive ? 'success' : 'warning'">{{ canOperateLive ? '可真实发波' : '需申请使用权' }}</el-tag></div><div class="template-bar"><el-input v-model="waveform.name" /><el-segmented v-model="waveform.mode" :options="[{ label: '手动 8 通道', value: 'manual' }, { label: 'ez-Q', value: 'ezq' }]" /><div class="record-field"><el-input-number v-model="waveform.record_duration_ns" :min="100" :max="1000000000" /><span class="unit">记录 ns</span></div><el-switch v-model="dryRun" active-text="Dry Run" inactive-text="真实发送" /></div>
            <div v-if="waveform.mode === 'manual'" class="channel-table"><div class="channel-head"><span>通道</span><span>选择</span><span>类型</span><span>IQ MHz</span><span>相位 deg</span><span>幅度</span><span>长度 ns</span></div><div v-for="channel in manualChannels" :key="channel.channel" class="channel-row"><strong>CH{{ channel.channel }} <small>{{ roleLabel(channel.channel) }}</small></strong><el-switch v-model="channel.enabled" /><el-select v-model="channel.waveform" :disabled="!channel.enabled"><el-option label="IQ CW" value="dc-iq-cw" /><el-option label="IQ Sine" value="iq-sine" /><el-option label="IQ Gaussian" value="iq-gaussian-sine" /></el-select><el-input-number v-model="channel.frequency_mhz" :disabled="!channel.enabled" :min="-160" :max="160" /><el-input-number v-model="channel.phase_deg" :disabled="!channel.enabled" :min="-3600" :max="3600" /><el-input-number v-model="channel.amplitude" :disabled="!channel.enabled" :min="0" :max="32767" /><el-input-number v-model="channel.duration_ns" :disabled="!channel.enabled" :min="1" /></div></div>
            <div v-else class="channel-table ezq-table"><div class="channel-head"><span>通道</span><span>选择</span><span>角色</span><span>RF MHz</span><span>Detune</span><span>幅度</span><span>起始 / 长度 ns</span></div><div v-for="channel in ezqChannels" :key="channel.channel" class="channel-row"><strong>CH{{ channel.channel }}</strong><el-switch v-model="channel.enabled" /><span class="role-label">{{ channel.role.toUpperCase() }}</span><el-input-number v-model="channel.target_rf_mhz" :disabled="!channel.enabled || channel.role === 'z'" :min="0" :max="6400" /><el-input-number v-model="channel.detune_mhz" :disabled="!channel.enabled || channel.role === 'z'" :min="-160" :max="160" /><el-input-number v-model="channel.amplitude" :disabled="!channel.enabled" :min="-1" :max="1" :step="0.01" /><div class="time-cell"><el-input-number v-model="channel.start_ns" :disabled="!channel.enabled" :min="0" /><el-input-number v-model="channel.duration_ns" :disabled="!channel.enabled" :min="1" /></div></div></div>
            <section class="override-panel"><div class="surface-head"><h3>本板校准覆盖</h3><Settings2 :size="18" /></div><div class="override-grid"><div v-for="channel in 8" :key="channel"><span>CH{{ channel }}</span><el-input-number v-model="override.nco_offset_hz[channel]" placeholder="NCO Hz" :controls="false" /><el-input-number v-model="override.phase_offset_deg[channel]" placeholder="Phase deg" :controls="false" /><el-input-number v-model="override.start_offset_ns[channel]" placeholder="Start ns" :controls="false" /></div></div></section>
          </section><aside class="preview-panel"><WavePreview :preview="preview" /></aside>
        </section>

        <section v-else-if="activeView === 'run'" class="view-stack">
          <div class="section-heading">
            <div><span class="eyebrow">{{ selectedRun?.board_ids[0] ?? '无任务' }}</span><h2>单板运行</h2></div>
            <el-select v-model="selectedRunId" class="run-select"><el-option v-for="run in runs" :key="run.id" :label="`${run.name} · ${run.state}`" :value="run.id" /></el-select>
          </div>
          <section v-if="selectedRun" class="run-console">
            <div class="run-state">
              <div><span class="eyebrow">{{ selectedRun.name }}</span><h3>{{ selectedRun.state }}</h3><el-progress :percentage="Math.round(selectedRun.progress * 100)" /></div>
              <div class="run-meta">
                <span>{{ selectedRun.dry_run ? 'DRY RUN' : 'LIVE' }}</span>
                <span>{{ selectedRun.board_ids[0] }}</span>
                <span>{{ runPayloadLabel(selectedRun) }}</span>
                <span v-if="!selectedRun.dry_run">RFCTRL2 {{ networkStateLabel(selectedRunBoardStatus) }} · {{ selectedRunBoardStatus?.playback_prepared ? 'PREPARED' : selectedRunBoardStatus?.playback_armed ? '预取中' : selectedRunBoardStatus?.playback_running ? '发波' : '静音' }}</span>
              </div>
            </div>
            <el-alert v-if="selectedRun.dry_run && selectedRun.state === 'DONE'" class="run-result" title="生成校验已完成，没有向板卡发送 UDP 数据" type="success" show-icon :closable="false" />
            <div class="run-actions">
              <template v-if="selectedRun.dry_run && selectedRun.state === 'DONE'">
                <el-button :icon="Waves" @click="activeView = 'editor'">返回波形编辑</el-button>
                <el-button type="primary" :icon="Upload" @click="prepareLiveUpload">切换为真实发送</el-button>
              </template>
              <template v-else-if="selectedRun.loaded && selectedRun.state === 'DONE'">
                <el-button :icon="AlarmSmoke" :disabled="selectedRunBoardStatus?.playback_armed || selectedRunBoardStatus?.playback_running" @click="loadedBoardAction('arm')">ARM 本板</el-button>
                <el-button :icon="Play" type="primary" :disabled="!selectedRunBoardStatus?.playback_prepared" @click="loadedBoardAction('trigger')">TRIGGER 发波</el-button>
                <el-button :icon="Square" type="danger" @click="loadedBoardAction('abort')">停止并静音</el-button>
              </template>
              <template v-else>
                <el-button :icon="AlarmSmoke" :disabled="selectedRun.state !== 'READY'" @click="runAction('arm')">ARM 本板</el-button>
                <el-button type="primary" :icon="Play" :disabled="selectedRun.state !== 'ARMED'" @click="runAction('start')">启动发波</el-button>
                <el-button type="danger" :icon="Square" :disabled="!['ARMED','RUNNING','READY'].includes(selectedRun.state)" @click="runAction('abort')">停止并静音</el-button>
              </template>
            </div>
          </section>
          <section class="surface"><div class="surface-head"><h3>运行事件</h3><Activity :size="18" /></div><div class="event-list"><div v-for="event in events.filter(item => item.run_id === selectedRunId)" :key="event.timestamp + event.message" :class="['event-line', event.level]"><time>{{ new Date(event.timestamp).toLocaleTimeString() }}</time><span>{{ event.message }}</span></div></div></section>
        </section>

        <section v-else-if="activeView === 'performance'" class="view-stack">
          <div class="section-heading"><div><span class="eyebrow">单板 RFDC 指标测试</span><h2>性能测试工作台</h2></div><div class="heading-actions"><el-button :icon="Download" @click="exportPerformance('csv')">导出 CSV</el-button><el-button :icon="Download" @click="exportPerformance('json')">导出 JSON</el-button></div></div>
          <section class="surface performance-form"><div class="surface-head"><div><h3>创建测试点序列</h3><span class="form-hint">实测值由频谱仪、示波器或功率计测量后录入</span></div><el-tag :type="canOperateLive ? 'success' : 'warning'">{{ canOperateLive ? '当前板卡可真实测试' : '当前为 Dry Run 或需申请使用权' }}</el-tag></div><div class="performance-grid"><el-input v-model="testForm.name" placeholder="测试名称" /><el-select v-model="testForm.kind"><el-option label="幅值：DAC 电流 / IQ 幅值" value="amplitude" /><el-option label="频率：目标 RF 扫描" value="frequency" /><el-option label="相位：数据 / NCO 相位" value="phase" /></el-select><el-select v-model="testForm.mode"><el-option label="自动逐点" value="automatic" /><el-option label="手动逐点确认" value="manual" /></el-select><el-select v-model="testForm.channels" multiple collapse-tags placeholder="测试通道"><el-option v-for="channel in 8" :key="channel" :label="`CH${channel}`" :value="channel" /></el-select><el-segmented v-if="testForm.kind === 'amplitude'" v-model="testAmplitudeAxis" :options="[{ label: '扫描 DAC mA', value: 'dac_current' }, { label: '扫描 IQ 幅值', value: 'data_amplitude' }]" /><el-input v-model="testPointSpec" :placeholder="testForm.kind === 'frequency' ? '频率点 MHz，例如 100, 1000, 6000' : testForm.kind === 'phase' ? '相位点 deg，例如 0, 90, 180, 270' : testAmplitudeAxis === 'dac_current' ? 'DAC 电流点 mA，例如 2.25, 20, 40.5' : 'IQ 幅值点，例如 -1, -0.5, 0, 0.5, 1'" /><el-input v-model="testAuxSpec" :placeholder="testForm.kind === 'amplitude' ? (testAmplitudeAxis === 'dac_current' ? '固定 IQ 幅值，例如 0.5' : '固定 DAC 电流 mA，例如 20') : testForm.kind === 'frequency' ? '固定数据偏移 MHz' : '固定 NCO 相位 deg'" /><el-input-number v-model="testForm.settle_ms" :min="0" :max="60000" /><el-switch v-model="testForm.auto_mute" active-text="点后自动静音" /><el-switch v-model="testForm.dry_run" active-text="Dry Run" inactive-text="真实测试" /><el-button type="primary" :icon="Save" @click="createPerformanceTest">创建测试</el-button></div></section>
          <section class="surface"><div class="surface-head"><div><h3>测试会话</h3><span class="form-hint">单板 {{ selectedBoard?.name || '未选择' }}</span></div><div class="heading-actions"><el-select v-model="selectedTestId" class="test-select"><el-option v-for="test in performanceTests" :key="test.id" :label="`${test.name} · ${test.state}`" :value="test.id" /></el-select><el-button :icon="Play" type="primary" :disabled="!selectedTestId" @click="startPerformanceTest">开始</el-button><el-button :icon="Pause" :disabled="!selectedTestId" @click="pausePerformanceTest">暂停</el-button><el-button :icon="Square" type="danger" plain :disabled="!selectedTestId" @click="abortPerformanceTest">取消</el-button></div></div><el-table :data="performancePoints"><el-table-column prop="index" label="#" width="70" /><el-table-column prop="state" label="状态" width="120"><template #default="scope"><el-tag :type="stateType(scope.row.state)">{{ scope.row.state }}</el-tag></template></el-table-column><el-table-column label="设定参数"><template #default="scope"><code>{{ JSON.stringify(scope.row.parameters) }}</code></template></el-table-column><el-table-column label="实测值"><template #default="scope"><code>{{ JSON.stringify(scope.row.measurement) }}</code></template></el-table-column><el-table-column label="操作" width="280"><template #default="scope"><el-button size="small" :disabled="!['PENDING','READY','FAILED'].includes(scope.row.state)" @click="executePerformancePoint(scope.row.index)">执行点</el-button><el-input v-model="measurementText" size="small" placeholder='JSON，例如 {"rms": -12.3}' /><el-button size="small" type="primary" @click="recordMeasurement(scope.row.index)">保存测量</el-button></template></el-table-column></el-table></section>
        </section>

        <section v-else-if="activeView === 'monitor'" class="view-stack">
          <div class="section-heading"><div><span class="eyebrow">RFCTRL2 与资源资格</span><h2>单板预检</h2></div><el-button :icon="RefreshCw" @click="refreshStatus">刷新全部状态</el-button></div>
          <section class="surface">
            <div class="preflight-toolbar"><div><strong>{{ selectedBoard?.name }}</strong><span>{{ preflight ? new Date(preflight.checked_at).toLocaleString() : '尚未检查' }}</span></div><el-select v-model="preflightArtifactId" clearable placeholder="可选：校验烧写发布"><el-option v-for="artifact in artifacts" :key="artifact.id" :label="`${artifact.label} · ${artifact.target_profile}`" :value="artifact.id" /></el-select><el-tag size="large" :type="preflight?.can_start_live ? 'success' : 'warning'">{{ preflight?.can_start_live ? '满足真实发波条件' : '需要处理预检项' }}</el-tag></div>
            <div class="preflight-list"><article v-for="check in preflight?.checks ?? []" :key="check.key" :class="['preflight-row', check.state]"><component :is="preflightIcon(check.state)" :size="18" /><div><strong>{{ check.label }}</strong><span>{{ check.message }}</span></div></article></div>
          </section>
          <section class="surface"><div class="surface-head"><h3>RFCTRL2 状态</h3><Activity :size="18" /></div><el-table :data="statuses"><el-table-column prop="board_id" label="板卡" /><el-table-column label="控制链路"><template #default="scope"><el-tag :type="scope.row.online ? stateType(scope.row.state) : 'warning'">{{ networkStateLabel(scope.row) }}</el-tag></template></el-table-column><el-table-column label="播放状态"><template #default="scope">{{ scope.row.playback_prepared ? 'PREPARED' : scope.row.playback_running ? 'RUNNING' : scope.row.playback_armed ? '预取中' : '静音' }}</template></el-table-column><el-table-column prop="protocol_version" label="RFCTRL" /><el-table-column prop="hmc_locked" label="HMC"><template #default="scope">{{ scope.row.hmc_locked === true ? 'LOCKED' : scope.row.hmc_locked === false ? 'UNLOCKED' : '---' }}</template></el-table-column><el-table-column prop="underflow_mask" label="Underflow" /><el-table-column prop="message" label="消息" /></el-table></section>
        </section>

        <section v-else-if="activeView === 'boards'" class="view-stack">
          <div class="section-heading"><div><span class="eyebrow">服务器资源</span><h2>板卡登记</h2></div><div class="heading-actions"><el-button :icon="Search" :loading="scanning" @click="scanInventory">检测 USB 设备</el-button><el-button type="primary" @click="openBoardEditor()">登记板卡</el-button></div></div>
          <el-alert v-if="inventoryScan?.scan_error" :title="inventoryScan.scan_error" type="error" show-icon :closable="false" />
          <div v-if="inventoryScan" class="scan-summary"><span>ONLINE 板卡 {{ inventoryScan.jtag.length }}</span><span>ttyUSB 串口 {{ inventoryScan.serial.length }}</span></div>
          <section class="surface">
            <el-table :data="boards">
              <el-table-column prop="name" label="板卡" />
              <el-table-column label="状态"><template #default="scope"><el-tag :type="boardIsDetected(scope.row) ? 'success' : 'info'">{{ boardPresenceLabel(scope.row) }}</el-tag></template></el-table-column>
              <el-table-column prop="ip" label="板卡 IP" />
              <el-table-column prop="udp_interface" label="UDP 网卡" />
              <el-table-column prop="udp_source_ip" label="源 IP" />
              <el-table-column prop="jtag_cable_serial" label="JTAG serial" />
              <el-table-column prop="serial_path" label="UART" />
              <el-table-column label="操作" width="100"><template #default="scope"><el-button size="small" @click="openBoardEditor(scope.row)">编辑</el-button></template></el-table-column>
            </el-table>
          </section>
          <section class="surface">
            <div class="surface-head"><h3>服务器 UDP 网卡</h3><Cable :size="18" /></div>
            <el-table :data="networkInterfaces">
              <el-table-column prop="name" label="网卡" />
              <el-table-column label="载波"><template #default="scope"><el-tag :type="scope.row.carrier ? 'success' : 'warning'">{{ scope.row.carrier ? '已连接' : '未连接' }}</el-tag></template></el-table-column>
              <el-table-column label="IPv4"><template #default="scope">{{ scope.row.ipv4_addresses.join(', ') || '未配置' }}</template></el-table-column>
              <el-table-column prop="message" label="状态" />
            </el-table>
          </section>
          <section class="surface"><div class="surface-head"><h3>发现资源</h3><Cable :size="18" /></div><el-table :data="discoveries"><el-table-column prop="kind" label="类型" /><el-table-column prop="label" label="标识" /><el-table-column label="状态"><template #default><el-tag type="success">ONLINE</el-tag></template></el-table-column><el-table-column label="绑定"><template #default="scope">{{ scope.row.board_id || '待绑定' }}</template></el-table-column><el-table-column prop="last_seen_at" label="最近发现"><template #default="scope">{{ new Date(scope.row.last_seen_at).toLocaleString() }}</template></el-table-column></el-table></section>
        </section>

        <section v-else-if="activeView === 'serial'" class="view-stack">
          <div class="section-heading">
            <div><span class="eyebrow">{{ selectedBoard?.serial_path || '未绑定串口' }}</span><h2>只读串口输出</h2></div>
            <div class="heading-actions log-actions">
              <el-button :icon="serialPaused ? Play : Pause" @click="toggleSerialPause">{{ serialPaused ? '继续' : '暂停' }}</el-button>
              <el-tooltip content="清空当前浏览器视图"><el-button :icon="Trash2" aria-label="清屏" @click="serialLines = []" /></el-tooltip>
              <el-tooltip content="复制串口日志"><el-button :icon="Copy" aria-label="复制" @click="copyLines(serialLines)" /></el-tooltip>
              <el-tooltip content="下载串口日志"><el-button :icon="Download" aria-label="下载" @click="downloadLines(serialLines, `${selectedBoardId}-uart.log`)" /></el-tooltip>
              <el-tooltip content="重新读取历史"><el-button :icon="RefreshCw" aria-label="刷新" @click="refreshSerial" /></el-tooltip>
            </div>
          </div>
          <section v-if="user.role === 'admin'" class="surface"><div class="serial-bind"><span>绑定到 {{ selectedBoard?.name }}</span><el-select placeholder="选择 ttyUSB 串口" @change="bindSerial"><el-option v-for="port in serialPorts" :key="port.path" :label="`${port.path}${port.bound_board_id ? ' · 已绑定' : ''}`" :value="port.path" :disabled="Boolean(port.bound_board_id)" /></el-select></div></section>
          <pre class="serial-console"><span v-for="(line, index) in serialLines" :key="line.created_at + index"><time>{{ new Date(line.created_at).toLocaleTimeString() }}</time> {{ line.line }}</span></pre>
        </section>

        <section v-else-if="activeView === 'program'" class="view-stack">
          <div class="section-heading"><div><span class="eyebrow">仅 JTAG 临时部署</span><h2>Bitstream 与 Firmware</h2></div></div>
          <section class="surface"><div class="artifact-upload"><el-input v-model="artifactForm.label" placeholder="发布名称" /><el-select v-model="artifactForm.target_profile"><el-option label="custom_xczu47dr" value="custom_xczu47dr" /><el-option label="custom_xczu47dr_b" value="custom_xczu47dr_b" /><el-option label="custom_xczu47dr_bw" value="custom_xczu47dr_bw" /></el-select><label class="file-control">BIT<input type="file" accept=".bit" @change="chooseFile($event, 'bit')" /></label><label class="file-control">ELF<input type="file" accept=".elf" @change="chooseFile($event, 'elf')" /></label><el-button type="primary" :icon="Upload" @click="uploadArtifact">上传发布</el-button></div></section>
          <section class="surface"><el-table :data="artifacts"><el-table-column prop="label" label="发布" /><el-table-column prop="target_profile" label="配置" /><el-table-column prop="bit_name" label="Bitstream" /><el-table-column prop="elf_name" label="Firmware" /><el-table-column label="操作"><template #default="scope"><el-button size="small" type="danger" plain @click="programBoard(scope.row)">部署到本板</el-button></template></el-table-column></el-table></section>
          <section class="surface">
            <div class="surface-head"><h3>部署任务</h3><Cpu :size="18" /></div>
            <el-table :data="programJobs" highlight-current-row @row-click="selectProgram"><el-table-column prop="id" label="任务" /><el-table-column prop="board_id" label="板卡" /><el-table-column prop="state" label="状态"><template #default="scope"><el-tag :type="stateType(scope.row.state)">{{ scope.row.state }}</el-tag></template></el-table-column><el-table-column prop="error" label="错误" /></el-table>
          </section>
          <section v-if="selectedProgramId" class="surface program-log-panel">
            <div class="surface-head"><div><span class="eyebrow">{{ selectedProgramId }}</span><h3>XSCT 原始日志</h3></div><div class="heading-actions"><el-tooltip content="复制部署日志"><el-button :icon="Copy" aria-label="复制" @click="copyLines(programLines)" /></el-tooltip><el-tooltip content="下载部署日志"><el-button :icon="Download" aria-label="下载" @click="downloadLines(programLines, `${selectedProgramId}-xsct.log`)" /></el-tooltip><el-tooltip content="重新读取日志"><el-button :icon="RefreshCw" aria-label="刷新" @click="selectProgram(programJobs.find(item => item.id === selectedProgramId)!)" /></el-tooltip></div></div>
            <pre class="serial-console program-console"><span v-for="(line, index) in programLines" :key="line.created_at + index"><time>{{ new Date(line.created_at).toLocaleTimeString() }}</time> {{ line.line }}</span></pre>
          </section>
        </section>

        <section v-else-if="activeView === 'users'" class="view-stack"><div class="section-heading"><div><span class="eyebrow">权限与记录</span><h2>用户和审计</h2></div></div><section class="surface"><div class="user-create"><el-input v-model="userForm.username" placeholder="用户名" /><el-input v-model="userForm.password" type="password" show-password placeholder="初始密码" /><el-select v-model="userForm.role"><el-option label="普通用户" value="user" /><el-option label="管理员" value="admin" /></el-select><el-button type="primary" @click="addUser">创建用户</el-button></div><el-table :data="users"><el-table-column prop="username" label="用户" /><el-table-column label="角色" width="160"><template #default="scope"><el-select v-model="scope.row.role" @change="updateUserAccount(scope.row)"><el-option label="普通用户" value="user" /><el-option label="管理员" value="admin" /></el-select></template></el-table-column><el-table-column label="启用" width="100"><template #default="scope"><el-switch v-model="scope.row.enabled" @change="updateUserAccount(scope.row)" /></template></el-table-column><el-table-column label="操作" width="120"><template #default="scope"><el-button :icon="KeyRound" size="small" @click="resetUserPassword(scope.row)">重置密码</el-button></template></el-table-column></el-table></section><section class="surface"><div class="surface-head"><h3>审计记录</h3><ShieldCheck :size="18" /></div><el-table :data="auditEvents"><el-table-column prop="created_at" label="时间"><template #default="scope">{{ new Date(scope.row.created_at).toLocaleString() }}</template></el-table-column><el-table-column prop="username" label="用户" /><el-table-column prop="type" label="事件" /><el-table-column prop="message" label="内容" /></el-table></section></section>

        <section v-else class="view-stack"><div class="section-heading"><div><span class="eyebrow">Artifact 与记录</span><h2>单板任务历史</h2></div><el-button :icon="RefreshCw" @click="refreshAll">刷新</el-button></div><section class="surface"><el-table :data="runs" @row-click="(row: RunRecord) => { selectedRunId = row.id; activeView = 'run' }"><el-table-column prop="name" label="任务" /><el-table-column label="板卡"><template #default="scope">{{ scope.row.board_ids[0] }}</template></el-table-column><el-table-column prop="state" label="状态"><template #default="scope"><el-tag :type="stateType(scope.row.state)">{{ scope.row.state }}</el-tag></template></el-table-column><el-table-column prop="created_at" label="创建时间"><template #default="scope">{{ new Date(scope.row.created_at).toLocaleString() }}</template></el-table-column><el-table-column prop="artifact_dir" label="Artifact" /></el-table></section></section>
      </main>
    </div>
    <el-dialog v-model="boardDialog" :title="editingBoardId ? '编辑板卡' : '登记板卡'" width="min(760px, 92vw)">
      <div class="board-form">
        <el-input v-model="boardForm.name" placeholder="板卡名称" />
        <el-input v-model="boardForm.model" placeholder="型号" />
        <el-input v-model="boardForm.ip" placeholder="板卡控制 IP" />
        <el-input-number v-model="boardForm.port" :min="1" :max="65535" />
        <el-select v-model="boardForm.udp_interface" placeholder="选择服务器 UDP 网卡">
          <el-option v-for="item in networkInterfaces" :key="item.name" :label="networkInterfaceLabel(item)" :value="item.name" />
        </el-select>
        <el-input v-model="boardForm.udp_source_ip" placeholder="服务器源 IP，例如 192.168.1.10" />
        <el-alert v-if="selectedBoardFormInterface && (!selectedBoardFormInterface.carrier || !selectedBoardFormInterface.ipv4_addresses.includes(boardForm.udp_source_ip))" class="network-warning" :title="`${selectedBoardFormInterface.message}；保存档案不会自动修改服务器网络配置`" type="warning" show-icon :closable="false" />
        <el-input v-model="boardForm.mac" placeholder="MAC" />
        <el-select v-model="boardForm.role"><el-option label="独立/主板" value="master" /><el-option label="从板（预留）" value="follower" /></el-select>
        <el-select v-model="boardForm.target_profile"><el-option label="custom_xczu47dr" value="custom_xczu47dr" /><el-option label="custom_xczu47dr_b" value="custom_xczu47dr_b" /><el-option label="custom_xczu47dr_bw" value="custom_xczu47dr_bw" /></el-select>
        <el-input v-model="boardForm.jtag_cable_serial" placeholder="JTAG cable serial" />
        <el-input v-model="boardForm.serial_path" placeholder="/dev/ttyUSB0" />
        <el-input-number v-model="boardForm.baud_rate" :min="300" :max="4000000" />
        <el-input v-model="boardForm.location" placeholder="位置" />
        <el-input v-model="boardForm.sync_group" placeholder="同步组（预留）" />
        <el-input v-model="boardForm.notes" type="textarea" placeholder="备注" />
        <el-switch v-model="boardForm.enabled" active-text="启用" />
      </div>
      <template #footer><el-button @click="boardDialog = false">取消</el-button><el-button type="primary" @click="saveBoard">保存</el-button></template>
    </el-dialog>
  </div>
</template>
