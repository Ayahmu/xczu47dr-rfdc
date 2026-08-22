<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { AlertTriangle, CheckCircle2, Radio, RefreshCw, Send, Square } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import { useDraftsStore, outputOverride, outputRfdc, outputWaveform } from '../stores/drafts'
import { useRunsStore } from '../stores/runs'
import { useSessionStore } from '../stores/session'
import type { BoardRfdcConfig, PhaseCalibrationRecord, SyncResult } from '../types'
import { stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const drafts = useDraftsStore()
const runs = useRunsStore()
const session = useSessionStore()

const masterId = ref('')
const slaveId = ref('')
const syncBusy = ref(false)
const sendBusy = ref(false)
const lastSync = ref<SyncResult | null>(null)
const currentRunId = ref('')
const rfdcs = reactive<Record<string, BoardRfdcConfig | null>>({})
const calibrations = reactive<Record<string, PhaseCalibrationRecord[]>>({})
let pollTimer: number | undefined

const candidates = computed(() => boards.boards.filter((board) => board.enabled && board.network_apply_status === 'applied' && board.target_profile !== 'custom_xczu47dr_bw'))
const masterOptions = computed(() => candidates.value.filter((board) => board.target_profile === 'custom_xczu47dr' || board.target_profile === 'custom_xczu47dr_master'))
const slaveOptions = computed(() => candidates.value.filter((board) => board.target_profile === 'custom_xczu47dr_slave'))
const master = computed(() => boards.byId(masterId.value))
const slave = computed(() => boards.byId(slaveId.value))
const currentRun = computed(() => runs.byId(currentRunId.value))
const statusOf = (boardId: string) => boards.statusById(boardId)
const bothLeased = computed(() => Boolean(
  master.value && slave.value
  && master.value.lease?.user_id === session.user?.id
  && slave.value.lease?.user_id === session.user?.id,
))
const runTitle = computed(() => {
  if (currentRun.value?.state === 'DONE') return '双板同步发波完成'
  if (currentRun.value?.state === 'FAULT') return '双板同步发波失败'
  if (currentRun.value?.state === 'ABORTED') return '已停止并静音'
  return '正在执行双板同步发波'
})

async function loadBoard(boardId: string) {
  if (!boardId) return
  rfdcs[boardId] = await boards.rfdc(boardId, false)
  calibrations[boardId] = await boards.phaseCalibrations(boardId)
  drafts.setUser(session.user?.username || '')
  drafts.output(boardId, rfdcs[boardId], calibrations[boardId])
  if (rfdcs[boardId]) drafts.syncFromServer(boardId, rfdcs[boardId]!, calibrations[boardId])
}

async function load() {
  await boards.fetchAll(true)
  if (!masterId.value && masterOptions.value.length) masterId.value = masterOptions.value[0].id
  if (!slaveId.value && slaveOptions.value.length) slaveId.value = slaveOptions.value[0].id
  await Promise.all([loadBoard(masterId.value), loadBoard(slaveId.value)])
}

async function syncNow() {
  if (!masterId.value || !slaveId.value) return ElMessage.warning('请先选择主卡和从卡')
  if (!bothLeased.value) return ElMessage.warning('请先申请两块板卡的使用权')
  syncBusy.value = true
  try {
    lastSync.value = await boards.syncTwoBoards(masterId.value, slaveId.value)
    await boards.fetchAll(true)
    ElMessage.success('两板同步完成：' + lastSync.value.message)
  } catch (error) {
    ElMessage.error('同步失败：' + errorMessage(error))
  } finally {
    syncBusy.value = false
  }
}

async function sendSynchronized() {
  if (!masterId.value || !slaveId.value) return ElMessage.warning('请先选择主卡和从卡')
  if (!bothLeased.value) return ElMessage.warning('请先申请两块板卡的使用权')
  if (!rfdcs[masterId.value] || !rfdcs[slaveId.value]) return ElMessage.warning('RFDC 配置仍在加载，请稍候')
  sendBusy.value = true
  try {
    const jobs = [masterId.value, slaveId.value].map((boardId) => {
      const draft = drafts.output(boardId, rfdcs[boardId], calibrations[boardId])
      return {
        board_id: boardId,
        waveform: outputWaveform(draft),
        override: outputOverride(boardId, draft),
        rfdc_config: outputRfdc(boardId, draft, rfdcs[boardId]!),
      }
    })
    const record = await runs.create({
      jobs,
      dry_run: false,
      execution_mode: 'synchronized',
      completion_mode: 'one_shot',
      playback_mode: 'single',
      one_shot_duration_ms: 1000,
    })
    currentRunId.value = record.id
    startPolling()
    ElMessage.success('双板同步发波任务已创建')
  } catch (error) {
    ElMessage.error('创建任务失败：' + errorMessage(error))
  } finally {
    sendBusy.value = false
  }
}

async function stopAll() {
  for (const boardId of [masterId.value, slaveId.value]) {
    if (!boardId) continue
    try { await boards.abort(boardId) } catch { /* best effort */ }
  }
  ElMessage.success('两板已停止并静音')
}

function startPolling() {
  stopPolling()
  pollTimer = window.setInterval(async () => { await runs.fetchAll() }, 1000)
}

function stopPolling() {
  if (pollTimer) {
    window.clearInterval(pollTimer)
    pollTimer = undefined
  }
}

watch(currentRun, (record) => {
  if (record && ['DONE', 'FAULT', 'ABORTED'].includes(record.state)) stopPolling()
})
watch([masterId, slaveId], () => {
  Promise.all([loadBoard(masterId.value), loadBoard(slaveId.value)]).catch((error) => ElMessage.error(errorMessage(error)))
})
onMounted(() => { load().catch((error) => ElMessage.error(errorMessage(error))) })
onBeforeUnmount(stopPolling)
</script>

<template>
  <div class="page-stack">
    <section class="work-surface compact-surface">
      <div class="config-section-head">
        <div><h2>双板同步</h2><p>选择主卡与从卡后，先执行 HMC7044/SYSREF 同步并等待 DAC MTS，再使用两板当前草稿同步发波。</p></div>
        <el-button :icon="RefreshCw" :loading="syncBusy" @click="syncNow">一键同步</el-button>
      </div>
      <div class="sync-selector-grid">
        <label><span>主卡（SYNC_EPOCH 发起方）</span>
          <el-select v-model="masterId" filterable placeholder="选择主卡">
            <el-option v-for="board in masterOptions" :key="board.id" :label="board.name + ' · ' + board.ip" :value="board.id" />
          </el-select>
        </label>
        <label><span>从卡（Type-C SYNC 接收方）</span>
          <el-select v-model="slaveId" filterable placeholder="选择从卡">
            <el-option v-for="board in slaveOptions" :key="board.id" :label="board.name + ' · ' + board.ip" :value="board.id" />
          </el-select>
        </label>
      </div>
      <div class="sync-board-grid">
        <div v-for="boardId in [masterId, slaveId].filter(Boolean)" :key="boardId" class="sync-board-card">
          <div><strong>{{ boards.byId(boardId)?.name || boardId }}</strong><span>{{ boards.byId(boardId)?.ip }}</span></div>
          <dl class="detail-grid">
            <div><dt>MTS</dt><dd>{{ statusOf(boardId)?.dac_mts_ready ? 'READY' : 'PENDING' }}<small>tiles=0x{{ (statusOf(boardId)?.dac_mts_tile_mask || 0).toString(16) }}</small></dd></div>
            <div><dt>NCO</dt><dd>{{ statusOf(boardId)?.nco_sync_ready ? 'READY' : 'PENDING' }}<small>epoch={{ statusOf(boardId)?.nco_sync_epoch }}</small></dd></div>
            <div><dt>状态</dt><dd><el-tag :type="stateType(statusOf(boardId)?.state)">{{ stateLabel(statusOf(boardId)?.state) }}</el-tag></dd></div>
          </dl>
        </div>
      </div>
      <div v-if="lastSync" class="sync-summary-grid">
        <div><dt>同步结果</dt><dd><CheckCircle2 :size="18" /> {{ lastSync.message }}</dd></div>
        <div v-for="item in lastSync.boards" :key="item.board_id"><dt>{{ item.board_id }}</dt><dd>HMC {{ item.hmc_done ? 'OK' : 'NO' }} · SYNC {{ item.sync_done ? 'OK' : 'NO' }} · MTS {{ item.dac_mts_ready ? 'OK' : 'NO' }}</dd></div>
      </div>
    </section>

    <section v-if="currentRun" class="run-progress-panel" :class="{ completed: currentRun.state === 'DONE', failed: currentRun.state === 'FAULT' || currentRun.state === 'ABORTED' }">
      <div class="run-progress-title">
        <component :is="currentRun.state === 'DONE' ? CheckCircle2 : currentRun.state === 'FAULT' || currentRun.state === 'ABORTED' ? AlertTriangle : Radio" :size="24" />
        <div><strong>{{ runTitle }}</strong><span>{{ currentRun.error || stateLabel(currentRun.state) + ' · ' + Math.round(currentRun.progress * 100) + '%' }}</span></div>
        <el-tag :type="stateType(currentRun.state)">{{ stateLabel(currentRun.state) }}</el-tag>
      </div>
    </section>

    <div class="fixed-command-bar">
      <div><strong>双板同步发波</strong><span>主卡 {{ master?.name || '-' }} · 从卡 {{ slave?.name || '-' }}</span></div>
      <el-button type="primary" size="large" :icon="Send" :disabled="!bothLeased || Boolean(sendBusy)" :loading="sendBusy" @click="sendSynchronized">同步并发送波形</el-button>
      <el-button type="danger" plain size="large" :icon="Square" @click="stopAll">两板停止并静音</el-button>
    </div>
  </div>
</template>
