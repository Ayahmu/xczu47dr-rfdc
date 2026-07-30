<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { CircleCheck, CircleX, Copy, Download, Pause, Play, RefreshCw, Settings2, Terminal, TriangleAlert } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { ElMessageBox } from 'element-plus/es/components/message-box/index'
import BoardContextHeader from '../components/BoardContextHeader.vue'
import { api, errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import { useEventsStore } from '../stores/events'
import { useRunsStore } from '../stores/runs'
import { useSessionStore } from '../stores/session'
import type { BoardPreflight, BoardRfdcConfig, RunRecord, SerialLogLine, SerialPortInfo } from '../types'
import { formatTime, maskHex, stateLabel, stateType } from '../utils/format'

const route = useRoute()
const boards = useBoardsStore()
const events = useEventsStore()
const runs = useRunsStore()
const session = useSessionStore()
const boardId = computed(() => String(route.params.boardId))
const board = computed(() => boards.byId(boardId.value))
const status = computed(() => boards.statusById(boardId.value))
const preflight = ref<BoardPreflight | null>(null)
const rfdc = ref<BoardRfdcConfig | null>(null)
const serialPorts = ref<SerialPortInfo[]>([])
const historyLines = ref<SerialLogLine[]>([])
const serialPaused = ref(false)
const expertOpen = ref(false)
const loadedRun = ref<RunRecord | null>(null)
const busy = ref(false)
const serialLines = computed(() => serialPaused.value ? historyLines.value : [...historyLines.value, ...(events.serial[boardId.value] || [])].slice(-5000))
let pollTimer = 0

async function refreshAll() {
  busy.value = true
  try {
    const [nextStatus, nextPreflight, nextRfdc, logs, ports, loaded] = await Promise.all([
      boards.refreshStatus(boardId.value, true), boards.preflight(boardId.value, false),
      boards.rfdc(boardId.value, false), api<SerialLogLine[]>('/api/serial/' + boardId.value + '/logs'),
      api<SerialPortInfo[]>('/api/serial/ports'), api<RunRecord | null>('/api/boards/' + boardId.value + '/loaded-waveform'),
    ])
    boards.upsertStatus(nextStatus); preflight.value = nextPreflight; rfdc.value = nextRfdc
    historyLines.value = logs; serialPorts.value = ports; loadedRun.value = loaded
    events.serial[boardId.value] = []
  } catch (error) { ElMessage.error('诊断刷新失败：' + errorMessage(error)) }
  finally { busy.value = false }
}
function logText() { return serialLines.value.map((item) => formatTime(item.created_at) + ' ' + item.line).join('\n') }
async function copyLog() { await navigator.clipboard.writeText(logText()); ElMessage.success('串口日志已复制') }
function downloadLog() {
  const url = URL.createObjectURL(new Blob([logText()], { type: 'text/plain;charset=utf-8' }))
  const link = document.createElement('a'); link.href = url; link.download = boardId.value + '-uart.log'; link.click(); URL.revokeObjectURL(url)
}
async function bindSerial(path: string) {
  if (!board.value) return
  try {
    await api('/api/admin/boards/' + boardId.value + '/serial', { method: 'POST', body: { path, baud_rate: board.value.baud_rate || 115200 } })
    await boards.fetchAll(false); await refreshAll(); ElMessage.success('串口映射已更新')
  } catch (error) { ElMessage.error(errorMessage(error)) }
}
async function expertAction(action: 'arm' | 'trigger' | 'abort') {
  if (!loadedRun.value && action !== 'abort') return ElMessage.warning('当前板卡没有已加载波形')
  try {
    if (action === 'trigger') await ElMessageBox.confirm('TRIGGER 会立即放行已准备的数据。仅用于定位时序问题。', '专家操作确认', { type: 'warning' })
    if (action === 'abort') await ElMessageBox.confirm('目标板卡：' + board.value?.name + '。将立即停止并静音。', '确认静音', { type: 'warning' })
    const result = await api<RunRecord>('/api/boards/' + boardId.value + '/' + action, { method: 'POST' })
    runs.upsert(result); loadedRun.value = result; await boards.refreshStatus(boardId.value, false)
    ElMessage.success(action === 'arm' ? '已进入准备状态' : action === 'trigger' ? '触发已确认' : '板卡已静音')
  } catch (error) { if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error)) }
}
onMounted(async () => { if (!boards.loaded) await boards.fetchAll(false); await refreshAll(); pollTimer = window.setInterval(() => { if (!serialPaused.value) void boards.refreshStatus(boardId.value, false) }, 5000) })
onBeforeUnmount(() => window.clearInterval(pollTimer))
</script>
<template>
  <div class="page-stack">
    <BoardContextHeader :board-id="boardId" />
    <header class="page-section-heading"><div><h2>状态与预检</h2><p>配置、网络、租约和播放状态按真实来源分别展示。</p></div><div><el-button :icon="Settings2" @click="expertOpen = true">专家诊断</el-button><el-button :icon="RefreshCw" :loading="busy" @click="refreshAll">刷新全部</el-button></div></header>
    <section class="diagnostics-grid">
      <div class="work-surface">
        <div class="config-section-head"><div><h2>运行预检</h2><p>{{ preflight?.checked_at ? '检查于 ' + formatTime(preflight.checked_at) : '尚未检查' }}</p></div><el-tag :type="preflight?.can_start_live ? 'success' : 'danger'">{{ preflight?.can_start_live ? '允许真实发送' : '存在阻断项' }}</el-tag></div>
        <div class="check-list">
          <div v-for="check in preflight?.checks || []" :key="check.key" :class="['check-row', check.state]">
            <component :is="check.state === 'pass' ? CircleCheck : check.state === 'fail' ? CircleX : TriangleAlert" :size="19" />
            <div><strong>{{ check.label }}</strong><span>{{ check.message }}</span></div>
          </div>
        </div>
      </div>
      <div class="work-surface">
        <div class="config-section-head"><div><h2>PL 与 RFDC</h2><p>结构化状态与最近配置回读。</p></div><el-tag :type="stateType(status?.state)">{{ stateLabel(status?.state) }}</el-tag></div>
        <dl class="detail-grid">
          <div><dt>协议版本</dt><dd>{{ status?.protocol_version || '-' }}</dd></div><div><dt>硬件配置</dt><dd>{{ status?.hardware_profile || '-' }}</dd></div>
          <div><dt>采样率</dt><dd>{{ status ? (status.sample_rate_hz / 1e9).toFixed(3) + ' GS/s' : '-' }}</dd></div><div><dt>插值倍数</dt><dd>{{ status?.interpolation || '-' }}x</dd></div>
          <div><dt>HMC 锁定</dt><dd>{{ status?.hmc_locked == null ? '未知' : status.hmc_locked ? '已锁定' : '未锁定' }}</dd></div><div><dt>RFDC 就绪</dt><dd>{{ status?.rfdc_ready == null ? '未知' : status.rfdc_ready ? '是' : '否' }}</dd></div>
          <div><dt>配置 revision</dt><dd>{{ rfdc?.revision || status?.rfdc_last_revision || 0 }}</dd></div><div><dt>有效通道</dt><dd>{{ maskHex(rfdc?.config_valid_mask || 0) }}</dd></div>
          <div><dt>Underflow</dt><dd>{{ maskHex(status?.underflow_mask || 0) }}</dd></div><div><dt>错误计数</dt><dd>{{ status?.error_count || 0 }}</dd></div>
        </dl>
        <el-alert v-if="rfdc?.apply_error" type="error" show-icon :closable="false" :title="rfdc.apply_error" />
      </div>
    </section>
    <section class="work-surface serial-panel">
      <div class="config-section-head">
        <div><h2>只读串口终端</h2><p>{{ board?.serial_path || '未绑定 ttyUSB 串口' }} · 串口不参与 RFDC 配置闭环。</p></div>
        <div class="inline-actions">
          <el-select v-if="session.isAdmin && board" :model-value="board.serial_path" placeholder="绑定 ttyUSB" style="width:220px" @change="bindSerial"><el-option v-for="port in serialPorts" :key="port.path" :label="port.path + (port.bound_board_id ? ' · ' + port.bound_board_id : '')" :value="port.path" :disabled="Boolean(port.bound_board_id && port.bound_board_id !== boardId)" /></el-select>
          <el-button :icon="serialPaused ? Play : Pause" @click="serialPaused = !serialPaused">{{ serialPaused ? '继续' : '暂停' }}</el-button>
          <el-button :icon="Copy" aria-label="复制日志" @click="copyLog" />
          <el-button :icon="Download" aria-label="下载日志" @click="downloadLog" />
        </div>
      </div>
      <pre class="terminal-view"><span v-for="(line, index) in serialLines" :key="line.created_at + index"><time>{{ new Date(line.created_at).toLocaleTimeString('zh-CN', { hour12: false }) }}</time> {{ line.line }}</span><em v-if="!serialLines.length">暂无串口输出</em></pre>
    </section>
    <el-drawer v-model="expertOpen" title="专家播放诊断" size="560px">
      <el-alert type="warning" show-icon :closable="false" title="这些操作跳过普通的一键流程，仅用于 ILA、触发和时序问题定位。" />
      <dl class="expert-status">
        <div><dt>已加载任务</dt><dd>{{ loadedRun?.id || '无' }}</dd></div><div><dt>ARM</dt><dd>{{ status?.playback_armed ? 'TRUE' : 'FALSE' }}</dd></div>
        <div><dt>PREPARED</dt><dd>{{ status?.playback_prepared ? 'TRUE' : 'FALSE' }}</dd></div><div><dt>RUNNING</dt><dd>{{ status?.playback_running ? 'TRUE' : 'FALSE' }}</dd></div>
      </dl>
      <section class="expert-operation"><h3>ARM 本板</h3><p>让 PL 锁存已上传波形和通道掩码，并等待触发。普通发送会自动完成此阶段。</p><el-button :disabled="!loadedRun || Boolean(status?.playback_armed)" @click="expertAction('arm')">手动 ARM</el-button></section>
      <section class="expert-operation"><h3>TRIGGER</h3><p>放行已经在 FIFO 中准备的数据。只在板卡已 ARM/PREPARED 时可用。</p><el-button type="primary" :disabled="!status?.playback_armed" @click="expertAction('trigger')">手动 TRIGGER</el-button></section>
      <section class="expert-operation danger"><h3>MUTE</h3><p>立即停止播放并关闭数据输出，作为诊断退出和紧急操作。</p><el-button type="danger" @click="expertAction('abort')">停止并静音</el-button></section>
    </el-drawer>
  </div>
</template>
