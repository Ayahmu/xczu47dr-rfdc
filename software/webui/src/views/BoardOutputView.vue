<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { onBeforeRouteLeave, useRoute } from 'vue-router'
import { AlertTriangle, CheckCircle2, Eye, Radio, RotateCcw, Save, Send, Square } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { ElMessageBox } from 'element-plus/es/components/message-box/index'
import BoardContextHeader from '../components/BoardContextHeader.vue'
import ChannelConfigurator from '../components/ChannelConfigurator.vue'
import WavePreview from '../components/WavePreview.vue'
import { api, errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import { useDraftsStore, outputOverride, outputRfdc, outputWaveform, type PlayMode } from '../stores/drafts'
import { useRunsStore } from '../stores/runs'
import { useSessionStore } from '../stores/session'
import type { BoardPreflight, BoardRfdcConfig, PreviewResponse, RunRecord } from '../types'
import { stateLabel, stateType } from '../utils/format'

const route = useRoute()
const boards = useBoardsStore()
const drafts = useDraftsStore()
const runs = useRunsStore()
const session = useSessionStore()
const boardId = computed(() => String(route.params.boardId))
const board = computed(() => boards.byId(boardId.value))
const status = computed(() => boards.statusById(boardId.value))
const draft = computed(() => drafts.output(boardId.value, rfdc.value))
const rfdc = ref<BoardRfdcConfig | null>(null)
watch(draft, () => drafts.persist(boardId.value), { deep: true })
const preview = ref<PreviewResponse | null>(null)
const previewBusy = ref(false)
const sendBusy = ref(false)
const confirmOpen = ref(false)
const selectedPreviewChannels = ref([1, 2])
const fftChannel = ref(1)
const currentRunId = ref('')
const currentRun = computed(() => runs.byId(currentRunId.value))
const ownsLease = computed(() => board.value?.lease?.user_id === session.user?.id)
const enabledChannels = computed(() => draft.value.channels.filter((item) => item.enabled))
const channelMask = computed(() => enabledChannels.value.reduce((mask, item) => mask | (1 << (item.channel - 1)), 0))
const isContinuous = computed(() => draft.value.playMode === 'continuous_sine')
const modeLabel = computed(() => isContinuous.value ? '连续播放' : '单次输出')
const recordDurationMs = computed(() => Math.max(draft.value.recordDurationNs / 1e6, 0))
const continuousDurationSeconds = computed({
  get: () => Number((draft.value.outputDurationMs / 1000).toFixed(3)),
  set: (value: number | undefined) => { draft.value.outputDurationMs = Math.max(0, Number(value || 0) * 1000) },
})
const runDurationLabel = computed(() => {
  if (isContinuous.value) {
    if (draft.value.outputDurationMs <= 0) return '直到手动停止'
    return `${Number((draft.value.outputDurationMs / 1000).toFixed(3))} s`
  }
  return draft.value.outputDurationMs + ' ms'
})
const runProgressTitle = computed(() => {
  if (currentRun.value?.state === 'DONE') return '发送成功并已自动静音'
  if (currentRun.value?.state === 'FAULT') return '发送失败'
  if (currentRun.value?.state === 'ABORTED') return '已停止并静音'
  if (currentRun.value?.state === 'RUNNING' && currentRun.value?.playback_mode === 'continuous_sine') return '正在连续播放'
  return '正在执行一键发送'
})
const estimatedLoopCount = computed(() => {
  if (!isContinuous.value || recordDurationMs.value <= 0) return 0
  if (draft.value.outputDurationMs <= 0) return null
  return Math.max(1, Math.floor(draft.value.outputDurationMs / recordDurationMs.value))
})
const sendDisabledReason = computed(() => {
  if (!ownsLease.value) return '请先申请当前板卡使用权'
  if (!enabledChannels.value.length) return '请至少启用一个通道'
  if (!status.value?.online) return 'RFCTRL2 UDP 控制链路未响应'
  if (status.value?.rfdc_ready === false) return 'RFDC 尚未就绪'
  if (sendBusy.value) return '任务正在创建'
  return ''
})
const runSteps = computed(() => {
  const state = currentRun.value?.state
  const order = ['预检', '应用 RFDC', '生成', '上传', '准备', '触发', '输出', '静音', '完成']
  let active = 0
  if (state === 'GENERATING') active = 2
  else if (state === 'UPLOADING') active = 3
  else if (state === 'READY' || state === 'ARMED') active = 5
  else if (state === 'RUNNING') active = 6
  else if (state === 'DONE') active = 9
  else if (state === 'FAULT' || state === 'ABORTED') active = 9
  return { order, active }
})

async function load() {
  if (!boards.loaded) await boards.fetchAll(false)
  rfdc.value = await boards.rfdc(boardId.value, false)
  drafts.setUser(session.user?.username || '')
  drafts.output(boardId.value, rfdc.value)
  selectedPreviewChannels.value = enabledChannels.value.map((item) => item.channel)
}
function dirty() { drafts.markDirty(boardId.value) }
function setPlayMode(mode: PlayMode) {
  draft.value.playMode = mode
  draft.value.loop = mode === 'continuous_sine'
  if (draft.value.loop) {
    if (draft.value.outputDurationMs === 100) draft.value.outputDurationMs = 0
  } else if (draft.value.outputDurationMs <= 0) {
    draft.value.outputDurationMs = 100
  }
  dirty()
}
async function generatePreview() {
  previewBusy.value = true
  try {
    preview.value = await api<PreviewResponse>('/api/waveforms/preview', { method: 'POST', body: { waveform: outputWaveform(draft.value), override: outputOverride(boardId.value, draft.value), rfdc_config: outputRfdc(boardId.value, draft.value, rfdc.value!), fft_channel: fftChannel.value } })
    selectedPreviewChannels.value = enabledChannels.value.map((item) => item.channel)
  } catch (error) { ElMessage.error('预览失败：' + errorMessage(error)) }
  finally { previewBusy.value = false }
}
async function openSend() {
  if (sendDisabledReason.value) return ElMessage.warning(sendDisabledReason.value)
  try {
    const check = await boards.preflight(boardId.value, true)
    const blockingKeys = new Set(['enabled', 'protocol', 'hmc', 'rfdc', 'lease', 'run'])
    const hardFailures = check.checks.filter((item) => item.state === 'fail' && blockingKeys.has(item.key))
    if (hardFailures.length) return ElMessage.error('预检未通过：' + hardFailures.map((item) => item.message).join('；'))
    confirmOpen.value = true
  } catch (error) { ElMessage.error('预检失败：' + errorMessage(error)) }
}
async function send() {
  if (!rfdc.value) return
  sendBusy.value = true
  try {
    const waveform = outputWaveform(draft.value)
    const record = await runs.create({ jobs: [{ board_id: boardId.value, waveform, override: outputOverride(boardId.value, draft.value), rfdc_config: outputRfdc(boardId.value, draft.value, rfdc.value) }],
      dry_run: false, execution_mode: 'single', completion_mode: 'one_shot', playback_mode: draft.value.playMode, one_shot_duration_ms: draft.value.outputDurationMs })
    currentRunId.value = record.id
    confirmOpen.value = false
    drafts.save(boardId.value)
    ElMessage.success(isContinuous.value && draft.value.outputDurationMs <= 0 ? '连续播放已启动，点击停止并静音结束输出' : '任务已创建，将自动发送并静音')
  } catch (error) { ElMessage.error('创建任务失败：' + errorMessage(error)) }
  finally { sendBusy.value = false }
}
async function stop() {
  try { await boards.abort(boardId.value); ElMessage.success('板卡已停止并静音') }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function reset() {
  try {
    await ElMessageBox.confirm('将放弃当前板卡未保存的输出配置。', '重置草稿', { type: 'warning' })
    drafts.reset(boardId.value, rfdc.value); preview.value = null
  } catch {}
}
onBeforeRouteLeave(async () => {
  if (!draft.value.dirty) return true
  try {
    await ElMessageBox.confirm('当前板卡配置尚未保存。请选择保存、放弃，或关闭对话框继续编辑。', '未保存的配置', {
      confirmButtonText: '保存并离开', cancelButtonText: '放弃修改', distinguishCancelAndClose: true, type: 'warning',
    })
    drafts.save(boardId.value)
    return true
  } catch (action) {
    if (action === 'cancel') {
      drafts.discard(boardId.value, rfdc.value)
      return true
    }
    return false
  }
})
onMounted(async () => { try { await load(); await generatePreview() } catch (error) { ElMessage.error(errorMessage(error)) } })
watch(boardId, load)
</script>
<template>
  <div class="page-stack">
    <BoardContextHeader :board-id="boardId" />
    <section class="output-workbench">
      <div class="output-config-column">
        <section class="work-surface compact-surface">
          <div class="config-section-head"><div><h2>输出任务</h2><p>连续播放会循环播放 DDR 缓存；每个循环按“延迟 + 波形 + 补零”输出。单次输出只播放记录长度。</p></div><div class="inline-actions"><el-button :icon="RotateCcw" @click="reset">重置</el-button><el-button :icon="Save" @click="drafts.save(boardId)">保存草稿</el-button></div></div>
          <div class="task-form-grid">
            <label><span>任务名称</span><el-input v-model="draft.name" @input="dirty" /></label>
            <label><span>输出模式</span><el-segmented :model-value="draft.playMode" :options="[{ label: '单次输出', value: 'single' }, { label: '连续播放', value: 'continuous_sine' }]" @change="setPlayMode($event as PlayMode)" /></label>
            <label><span>{{ isContinuous ? '循环缓存长度' : '记录长度' }} <small>ns</small></span><el-input-number v-model="draft.recordDurationNs" :min="10" :max="1e9" :step="100" controls-position="right" @change="dirty" /></label>
            <label v-if="isContinuous"><span>连续输出时长 <small>s</small></span><el-input-number v-model="continuousDurationSeconds" :min="0" :max="3600" :step="1" :precision="3" controls-position="right" @change="dirty" /><small class="field-hint">0 = 一直输出，直到点击停止并静音；100 秒请输入 100。</small></label>
            <label v-else><span>触发后静音延迟 <small>ms</small></span><el-input-number v-model="draft.outputDurationMs" :min="1" :max="3600000" :step="10" controls-position="right" @change="dirty" /></label>
          </div>
        </section>
        <section class="work-surface"><ChannelConfigurator :draft="draft" :readback-revision="rfdc?.revision" :valid-mask="rfdc?.config_valid_mask" @dirty="dirty" /></section>
      </div>
      <aside class="preview-column">
        <section class="work-surface preview-surface">
          <div class="config-section-head"><div><h2>波形预览</h2><p>{{ isContinuous ? '显示循环缓存中的最终输出：延迟补零 + 波形 + 尾部补零。' : '预览与实际发送使用同一份板卡草稿。' }}</p></div><el-button type="primary" plain :icon="Eye" :loading="previewBusy" @click="generatePreview">生成预览</el-button></div>
          <div class="preview-toolbar">
            <el-select v-model="selectedPreviewChannels" multiple collapse-tags collapse-tags-tooltip placeholder="显示通道"><el-option v-for="item in draft.channels.filter(channel => channel.enabled)" :key="item.channel" :label="'CH' + item.channel" :value="item.channel" /></el-select>
            <el-select v-model="fftChannel" @change="generatePreview"><el-option v-for="item in draft.channels.filter(channel => channel.enabled)" :key="item.channel" :label="'FFT · CH' + item.channel" :value="item.channel" /></el-select>
          </div>
          <WavePreview :preview="preview" :channels="selectedPreviewChannels" />
          <div v-if="preview" class="preview-metrics">
            <span>采样率<strong>{{ (preview.sample_rate_hz / 1e6).toFixed(0) }} MS/s</strong></span>
            <span>单通道数据<strong>{{ (preview.bytes_per_channel / 1024).toFixed(1) }} KiB</strong></span>
            <span>启用通道<strong>{{ enabledChannels.length }}</strong></span>
            <span>总数据量<strong>{{ (preview.bytes_per_channel * enabledChannels.length / 1024).toFixed(1) }} KiB</strong></span>
            <span v-if="isContinuous">预计循环<strong>{{ estimatedLoopCount === null ? '持续循环' : estimatedLoopCount + ' 次' }}</strong></span>
          </div>
          <el-alert v-for="warning in preview?.warnings || []" :key="warning" type="warning" :closable="false" show-icon :title="warning" />
        </section>
      </aside>
    </section>
    <section v-if="currentRun" class="run-progress-panel" :class="{ completed: currentRun.state === 'DONE', failed: currentRun.state === 'FAULT' || currentRun.state === 'ABORTED' }">
      <div class="run-progress-title">
        <component :is="currentRun.state === 'DONE' ? CheckCircle2 : currentRun.state === 'FAULT' || currentRun.state === 'ABORTED' ? AlertTriangle : Radio" :size="24" />
        <div><strong>{{ runProgressTitle }}</strong><span>{{ currentRun.error || stateLabel(currentRun.state) + ' · ' + Math.round(currentRun.progress * 100) + '%' }}</span></div>
        <el-tag :type="stateType(currentRun.state)">{{ stateLabel(currentRun.state) }}</el-tag>
      </div>
      <el-steps :active="runSteps.active" finish-status="success" process-status="process" simple><el-step v-for="step in runSteps.order" :key="step" :title="step" /></el-steps>
    </section>
    <div class="fixed-command-bar">
      <div><strong>{{ board?.name }}</strong><span>CH {{ enabledChannels.map(item => item.channel).join(', ') || '-' }} · {{ modeLabel }} · {{ runDurationLabel }}</span></div>
      <el-tooltip :content="sendDisabledReason" :disabled="!sendDisabledReason"><span><el-button type="primary" size="large" :icon="Send" :disabled="Boolean(sendDisabledReason)" :loading="sendBusy" @click="openSend">发送波形</el-button></span></el-tooltip>
      <el-button type="danger" plain size="large" :icon="Square" @click="stop">停止并静音</el-button>
    </div>
    <el-dialog v-model="confirmOpen" title="确认发送波形" width="720px">
      <el-alert :title="isContinuous ? '连续播放会上传一段循环缓存；首次 Trigger 后 PL 自动循环，每个循环周期按 延迟+波形+补零 输出；时长为 0 时只会在手动停止时静音。' : '该流程将自动预检、配置 RFDC、上传、触发，并在设定时间后静音。'" type="info" show-icon :closable="false" />
      <dl class="send-summary">
        <div><dt>目标板卡</dt><dd>{{ board?.name }} · {{ board?.ip }}</dd></div><div><dt>输出通道</dt><dd>{{ enabledChannels.map(item => 'CH' + item.channel).join(', ') }}</dd></div>
        <div><dt>目标 RF</dt><dd>{{ enabledChannels.map(item => 'CH' + item.channel + ' ' + item.targetRfGhz.toFixed(3) + ' GHz').join('；') }}</dd></div>
        <div><dt>数据幅值</dt><dd>{{ enabledChannels.map(item => 'CH' + item.channel + ' ' + item.dataAmplitude).join('；') }}</dd></div>
        <div><dt>模式与时长</dt><dd>{{ modeLabel }} · {{ runDurationLabel }}{{ isContinuous && draft.outputDurationMs <= 0 ? '' : ' 后自动静音' }}</dd></div>
        <div><dt>DAC 电流</dt><dd>{{ enabledChannels.map(item => 'CH' + item.channel + ' ' + item.dacCurrentMa + ' mA').join('；') }}</dd></div>
      </dl>
      <template #footer><el-button @click="confirmOpen = false">返回检查</el-button><el-button type="primary" :loading="sendBusy" @click="send">确认并发送</el-button></template>
    </el-dialog>
  </div>
</template>
