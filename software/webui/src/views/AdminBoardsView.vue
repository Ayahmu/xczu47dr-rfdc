<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Cable, Edit3, RefreshCw, Search } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { api, errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import type { BoardProfile, BoardScanResponse, BoardScanResult, BoardStatus, CapabilityReport, InventoryScanResult, NetworkInterfaceInfo, SerialPortInfo } from '../types'
import { formatTime, stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const activeTab = ref('profiles')
const drawer = ref(false)
const editingId = ref('')
const scanning = ref(false)
const refreshingId = ref('')
const serialPorts = ref<SerialPortInfo[]>([])
const scanResults = ref<BoardScanResult[]>([])
const capabilities = ref<CapabilityReport | null>(null)
const query = ref('')
const form = reactive({
  name: '',
  udp_interface: '',
  jtag_cable_serial: '',
  serial_path: '',
  baud_rate: 115200,
  location: '',
  notes: '',
  enabled: true,
})
const linkInterfaces = computed(() => boards.interfaces)
const selectedInterface = computed(() => boards.interfaces.find((item) => item.name === editingBoard.value?.udp_interface) || null)
const editingBoard = computed(() => editingId.value ? boards.byId(editingId.value) : null)
const filtered = computed(() => boards.boards.filter((item) => {
  const haystack = `${item.name} ${item.id} ${item.desired_ip || item.ip} ${item.jtag_cable_serial} ${item.udp_interface}`.toLowerCase()
  return !query.value || haystack.includes(query.value.toLowerCase())
}))
type LinkState = 'pass' | 'warning' | 'fail' | 'info'
interface LinkLayer {
  key: string
  label: string
  state: LinkState
  summary: string
  detail: string
}
function tagType(state: LinkState) {
  return state === 'pass' ? 'success' : state === 'fail' ? 'danger' : state
}
function nicFor(board: BoardProfile): NetworkInterfaceInfo | null {
  return boards.interfaces.find((item) => item.name === board.udp_interface) || null
}
function statusFor(board: BoardProfile): BoardStatus | null {
  return boards.statusById(board.id)
}
function scanFor(board: BoardProfile, stage?: BoardScanResult['stage']): BoardScanResult | null {
  const matches = scanResults.value.filter((item) => {
    const sameBoard = item.board_id === board.id || (!!item.device_uid && item.device_uid === board.device_uid)
    return sameBoard && (!stage || item.stage === stage)
  })
  return matches[matches.length - 1] || null
}
function linkLayers(board: BoardProfile): LinkLayer[] {
  const nic = nicFor(board)
  const status = statusFor(board)
  const expectedSource = board.udp_source_ip
  const hostOk = Boolean(nic?.present && nic?.carrier && (!expectedSource || nic.ipv4_addresses.includes(expectedSource)))
  const hostDetail = nic
    ? `${nic.message}${expectedSource && !nic.ipv4_addresses.includes(expectedSource) ? '；缺少源 IP ' + expectedSource : ''}`
    : `服务器未枚举 ${board.udp_interface}`
  const discoveryScan = scanFor(board, 'discovery')
  const networkScan = scanFor(board, 'network_apply')
  const rfScan = scanFor(board, 'rfctrl2')
  const networkApplied = board.network_apply_status === 'applied'
  const playbackState = status?.playback_running ? 'RUNNING'
    : status?.playback_prepared ? 'PREPARED'
      : status?.playback_armed ? 'ARMED'
        : stateLabel(status?.state)
  return [
    {
      key: 'host',
      label: 'Host NIC',
      state: hostOk ? 'pass' : 'fail',
      summary: hostOk ? `${board.udp_interface} ready` : '网卡未就绪',
      detail: hostDetail,
    },
    {
      key: 'discovery',
      label: 'Discovery',
      state: board.device_uid ? 'pass' : (discoveryScan ? 'fail' : 'warning'),
      summary: board.device_uid ? board.device_uid : '未发现 device_uid',
      detail: board.last_seen_at
        ? `最近发现 ${formatTime(board.last_seen_at)}`
        : (discoveryScan?.message || '等待 RFCTRL2 NETWORK_GET 响应'),
    },
    {
      key: 'network',
      label: 'Network Apply',
      state: networkApplied ? 'pass' : board.network_apply_status === 'failed' ? 'fail' : 'warning',
      summary: networkApplied ? `${board.active_ip || board.ip} applied` : board.network_apply_status,
      detail: board.network_apply_error || networkScan?.message || `desired ${board.desired_ip || board.ip} / active ${board.active_ip || '-'}`,
    },
    {
      key: 'rfctrl2',
      label: 'RFCTRL2',
      state: status?.online && status.protocol_version === 2 ? 'pass' : (rfScan ? 'fail' : 'warning'),
      summary: status?.online ? `RFCTRL${status.protocol_version}` : 'UDP 控制未响应',
      detail: status?.message || rfScan?.message || `target ${board.active_ip || board.ip}:${board.port}`,
    },
    {
      key: 'playback',
      label: 'Playback',
      state: status?.rfdc_ready === true ? 'pass' : status?.rfdc_ready === false ? 'fail' : 'warning',
      summary: status?.rfdc_ready === true ? `RFDC ready · ${playbackState}` : status?.rfdc_ready === false ? 'RFDC not ready' : '等待状态读取',
      detail: status
        ? `cfg=0x${status.rfdc_config_valid_mask.toString(16).padStart(2, '0')} play=0x${status.play_config_channel_mask.toString(16).padStart(2, '0')} fifo=0x${status.play_fifo_valid_mask.toString(16).padStart(2, '0')}/0x${status.play_fifo_ready_mask.toString(16).padStart(2, '0')} exec=0x${status.play_executor_state.toString(16).padStart(2, '0')}`
        : '尚未读取 RFCTRL2 status',
    },
  ]
}
function resetForm() {
  Object.assign(form, {
    name: '',
    udp_interface: '',
    jtag_cable_serial: '',
    serial_path: '',
    baud_rate: 115200,
    location: '',
    notes: '',
    enabled: true,
  })
}
function edit(board?: BoardProfile) {
  resetForm()
  editingId.value = board?.id || ''
  if (board) Object.assign(form, {
    name: board.name,
    udp_interface: board.udp_interface,
    jtag_cable_serial: board.jtag_cable_serial,
    serial_path: board.serial_path,
    baud_rate: board.baud_rate,
    location: board.location,
    notes: board.notes,
    enabled: board.enabled,
  })
  drawer.value = true
}
function savePayload() {
  const board = editingBoard.value
  if (!board) throw new Error('板卡库存只能通过 RFCTRL2 扫描加入')
  return {
    name: form.name,
    model: board.model,
    ip: board.ip,
    port: board.port,
    mac: board.mac,
    bootstrap_ip: board.bootstrap_ip,
    desired_ip: board.desired_ip,
    active_ip: board.active_ip,
    desired_mac: board.desired_mac,
    active_mac: board.active_mac,
    device_uid: board.device_uid,
    network_revision: board.network_revision,
    network_apply_status: board.network_apply_status,
    network_apply_error: board.network_apply_error,
    udp_interface: board.udp_interface,
    udp_source_ip: board.udp_source_ip,
    clock_source: board.clock_source,
    target_profile: board.target_profile,
    jtag_cable_serial: form.jtag_cable_serial.trim(),
    serial_path: form.serial_path,
    baud_rate: form.baud_rate,
    location: form.location,
    notes: form.notes,
    enabled: form.enabled,
  }
}
async function save() {
  try {
    if (!editingId.value) throw new Error('板卡库存只能通过 RFCTRL2 扫描加入')
    const result = await api<BoardProfile>('/api/admin/boards/' + editingId.value, {
      method: 'PATCH',
      body: savePayload(),
    })
    boards.upsertBoard(result)
    drawer.value = false
    ElMessage.success('板卡档案已保存')
  } catch (error) { ElMessage.error(errorMessage(error)) }
}
async function scan() {
  scanning.value = true
  try {
    const network = await api<BoardScanResponse>('/api/boards/scan', { method: 'POST' })
    scanResults.value = network.results
    await api<InventoryScanResult>('/api/admin/discovery/scan', { method: 'POST' })
    capabilities.value = await api<CapabilityReport>('/api/admin/system/capabilities')
    await boards.fetchAll(true)
    serialPorts.value = await api<SerialPortInfo[]>('/api/serial/ports')
    const failures = network.results.filter((item) => !item.ok)
    ElMessage.success(network.boards.length ? `已加入 ${network.boards.length} 块 FPGA 板卡` : `服务器资源扫描完成，未发现可连接 FPGA（${failures.length} 条诊断）`)
  } catch (error) { ElMessage.error(errorMessage(error)) }
  finally { scanning.value = false }
}
async function loadCapabilities() {
  try { capabilities.value = await api<CapabilityReport>('/api/admin/system/capabilities') }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function refreshBoard(board: BoardProfile) {
  refreshingId.value = board.id
  try {
    await boards.refreshStatus(board.id, true)
    await boards.fetchAll(false)
  } catch (error) { ElMessage.error(errorMessage(error)) }
  finally { refreshingId.value = '' }
}
onMounted(async () => {
  await Promise.all([
    boards.fetchAll(false),
    loadCapabilities(),
  ])
  serialPorts.value = await api<SerialPortInfo[]>('/api/serial/ports')
})
</script>
<template>
  <div class="page-stack">
    <header class="page-heading">
      <div>
        <span class="eyebrow">管理中心</span>
        <h1>FPGA 板卡 Link</h1>
        <p>工作区库存只来自 RFCTRL2 discovery。管理员可扫描服务器并编辑已发现板卡的诊断信息。</p>
      </div>
      <el-button type="primary" :icon="Cable" :loading="scanning" @click="scan">扫描服务器</el-button>
    </header>
    <section class="work-surface admin-tabs">
      <el-tabs v-model="activeTab">
        <el-tab-pane label="板卡" name="profiles">
          <div class="filter-bar">
            <el-input v-model="query" :prefix-icon="Search" clearable placeholder="搜索名称、JTAG、网口或自动 IP" />
            <div class="filter-spacer"></div>
            <el-button :icon="RefreshCw" @click="boards.fetchAll(true)">刷新状态</el-button>
          </div>
          <el-table :data="filtered" height="calc(100vh - 330px)">
            <el-table-column type="expand" width="44">
              <template #default="{ row }">
                <div class="link-pipeline">
                  <div v-for="layer in linkLayers(row)" :key="layer.key" :class="['link-stage', layer.state]">
                    <div class="link-stage-head">
                      <i />
                      <span>{{ layer.label }}</span>
                      <el-tag size="small" :type="tagType(layer.state)">{{ layer.state }}</el-tag>
                    </div>
                    <strong>{{ layer.summary }}</strong>
                    <small>{{ layer.detail }}</small>
                  </div>
                </div>
              </template>
            </el-table-column>
            <el-table-column prop="name" label="板卡" min-width="190">
              <template #default="{ row }"><strong>{{ row.name }}</strong><small class="table-subtitle">{{ row.id }}</small></template>
            </el-table-column>
            <el-table-column label="自动 IP / 网口" min-width="250">
              <template #default="{ row }">{{ row.desired_ip || row.ip }}<small class="table-subtitle">{{ row.udp_interface }}</small></template>
            </el-table-column>
            <el-table-column label="JTAG / UART" min-width="240">
              <template #default="{ row }">{{ row.jtag_cable_serial || '未登记 JTAG' }}<small class="table-subtitle">{{ row.serial_path || '未绑定 UART' }}</small></template>
            </el-table-column>
            <el-table-column label="运行状态" width="140">
              <template #default="{ row }"><el-tag :type="stateType(boards.statusById(row.id)?.state)">{{ stateLabel(boards.statusById(row.id)?.state) }}</el-tag></template>
            </el-table-column>
            <el-table-column label="使用权" width="130"><template #default="{ row }">{{ row.lease?.username || '空闲' }}</template></el-table-column>
            <el-table-column label="启用" width="90"><template #default="{ row }"><el-tag :type="row.enabled ? 'success' : 'info'">{{ row.enabled ? '启用' : '停用' }}</el-tag></template></el-table-column>
            <el-table-column label="操作" width="210">
              <template #default="{ row }">
                <el-button :icon="Edit3" size="small" @click="edit(row)">编辑</el-button>
                <el-button :icon="RefreshCw" size="small" type="primary" :loading="refreshingId === row.id" @click="refreshBoard(row)">读取状态</el-button>
              </template>
            </el-table-column>
          </el-table>
          <div v-if="!filtered.length" class="empty-panel"><Cable :size="32" /><h2>尚未发现 FPGA 板卡</h2><p>先扫描服务器网口。只有收到 RFCTRL2 device_uid 的板卡才会加入工作区。</p><el-button type="primary" :icon="Cable" :loading="scanning" @click="scan">扫描服务器</el-button></div>
        </el-tab-pane>
        <el-tab-pane label="服务器资源" name="resources">
          <div class="resource-toolbar"><div><h2>服务器资源</h2><p>这里用于确认服务器是否看见 10G 网口、JTAG cable 和可选 UART。</p></div><el-button type="primary" :icon="Cable" :loading="scanning" @click="scan">扫描服务器</el-button></div>
          <h3 class="table-heading">后端权限</h3>
          <div class="capability-panel">
            <div><span>自动配置网卡</span><el-tag :type="capabilities?.ok ? 'success' : 'danger'">{{ capabilities?.ok ? '可用' : '缺权限' }}</el-tag></div>
            <div><span>需要</span><strong>{{ capabilities?.required.join(', ') || 'CAP_NET_ADMIN, CAP_NET_RAW' }}</strong></div>
            <div><span>当前 effective</span><strong>{{ capabilities?.effective.join(', ') || '无' }}</strong></div>
            <div><span>缺失</span><strong>{{ capabilities?.missing.join(', ') || '无' }}</strong></div>
          </div>
          <h3 class="table-heading">FPGA Link 网口</h3>
          <el-table :data="linkInterfaces"><el-table-column prop="name" label="接口" width="150" /><el-table-column label="载波" width="120"><template #default="{ row }"><el-tag :type="row.carrier ? 'success' : 'warning'">{{ row.carrier ? '已连接' : '无载波' }}</el-tag></template></el-table-column><el-table-column label="IPv4"><template #default="{ row }">{{ row.ipv4_addresses.join(', ') || '未配置' }}</template></el-table-column><el-table-column prop="message" label="状态" /></el-table>
          <h3 class="table-heading">最近一次 UDP Link 扫描</h3>
          <el-table :data="scanResults">
            <el-table-column prop="interface" label="接口" width="150" />
            <el-table-column prop="stage" label="层级" width="150" />
            <el-table-column label="结果" width="110"><template #default="{ row }"><el-tag :type="row.ok ? 'success' : 'danger'">{{ row.ok ? '通过' : '失败' }}</el-tag></template></el-table-column>
            <el-table-column prop="target" label="目标" width="180" />
            <el-table-column prop="device_uid" label="device_uid" width="190" />
            <el-table-column prop="message" label="诊断" />
          </el-table>
          <h3 class="table-heading">JTAG / USB</h3>
          <el-table :data="boards.discoveries"><el-table-column prop="kind" label="类型" width="100" /><el-table-column prop="label" label="设备" /><el-table-column label="Cable serial"><template #default="{ row }">{{ row.details.cable_serial || '-' }}</template></el-table-column><el-table-column prop="board_id" label="绑定板卡"><template #default="{ row }">{{ row.board_id || '待登记' }}</template></el-table-column><el-table-column label="最近发现"><template #default="{ row }">{{ formatTime(row.last_seen_at) }}</template></el-table-column></el-table>
          <h3 class="table-heading">可选 UART</h3>
          <el-table :data="serialPorts"><el-table-column prop="path" label="端口" /><el-table-column prop="stable_path" label="稳定路径" /><el-table-column prop="serial_number" label="序列号" /><el-table-column prop="bound_board_id" label="绑定板卡"><template #default="{ row }">{{ row.bound_board_id || '未绑定' }}</template></el-table-column></el-table>
        </el-tab-pane>
      </el-tabs>
    </section>
    <el-drawer v-model="drawer" title="编辑 FPGA 板卡" size="560px">
      <el-form label-position="top" class="admin-form">
        <div class="form-section-title">Link 必填</div>
        <div class="form-grid">
          <el-form-item label="板卡名称"><el-input v-model="form.name" /></el-form-item>
          <el-form-item label="JTAG cable serial"><el-input v-model="form.jtag_cable_serial" placeholder="例如 210512180082" /></el-form-item>
          <el-form-item label="服务器 10G 网口"><el-input :model-value="editingBoard?.udp_interface || '-'" disabled /></el-form-item>
          <el-form-item label="启用"><el-switch v-model="form.enabled" active-text="启用" inactive-text="停用" /></el-form-item>
        </div>
        <div class="auto-link-summary">
          <div><span>目标 IP</span><strong>{{ editingBoard?.desired_ip || editingBoard?.ip || '-' }}</strong></div>
          <div><span>构建配置</span><strong>{{ editingBoard?.target_profile || '-' }}</strong></div>
          <div><span>端口状态</span><strong>{{ selectedInterface?.message || '等待扫描' }}</strong></div>
        </div>
        <div class="form-section-title">可选诊断</div>
        <div class="form-grid">
          <el-form-item label="UART 端口"><el-select v-model="form.serial_path" clearable filterable><el-option v-for="port in serialPorts" :key="port.stable_path || port.path" :label="port.stable_path || port.path" :value="port.stable_path || port.path" /></el-select></el-form-item>
          <el-form-item label="波特率"><el-input-number v-model="form.baud_rate" :min="300" :max="4000000" controls-position="right" /></el-form-item>
          <el-form-item label="位置"><el-input v-model="form.location" /></el-form-item>
        </div>
        <el-form-item label="备注"><el-input v-model="form.notes" type="textarea" :rows="4" /></el-form-item>
      </el-form>
      <template #footer><el-button @click="drawer = false">取消</el-button><el-button v-if="editingBoard" :icon="RefreshCw" @click="refreshBoard(editingBoard)">读取状态</el-button><el-button type="primary" @click="save">保存</el-button></template>
    </el-drawer>
  </div>
</template>
