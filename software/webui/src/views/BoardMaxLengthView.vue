<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRoute } from 'vue-router'
import { Play, Square } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import BoardContextHeader from '../components/BoardContextHeader.vue'
import { errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import { useSessionStore } from '../stores/session'
import type { MaxLengthTestRecord } from '../types'
import { stateLabel, stateType } from '../utils/format'

const route = useRoute()
const boards = useBoardsStore()
const session = useSessionStore()
const boardId = computed(() => String(route.params.boardId))
const board = computed(() => boards.byId(boardId.value))
const status = computed(() => boards.statusById(boardId.value))
const ownsLease = computed(() => board.value?.lease?.user_id === session.user?.id)
const tests = ref<MaxLengthTestRecord[]>([])
const selectedId = ref('')
const currentTest = computed(() => tests.value.find((item) => item.id === selectedId.value) || null)
const busy = ref(false)
let pollTimer: number | undefined

const form = reactive({
  name: '通道极限长度测试',
  bytes_per_channel: 0,
  pattern: 'lowfreq-sine' as 'lowfreq-sine' | 'cw-marker',
  sine_freq_hz: 10.0,
  sine_amplitude: 4096,
  beats_per_datagram: 0,
  auto_trigger: true,
  dry_run: false,
})

const activeStates = ['PENDING', 'UPLOADING', 'PLAYING']

async function load() {
  await boards.fetchAll(true)
  tests.value = (await boards.maxLengthTests()).filter((item) => item.board_id === boardId.value)
  if (!selectedId.value && tests.value.length) selectedId.value = tests.value[0].id
}

function formatBytes(value: number) {
  if (!value) return '0 B'
  if (value >= 1024 ** 3) return (value / 1024 ** 3).toFixed(3) + ' GiB'
  if (value >= 1024 ** 2) return (value / 1024 ** 2).toFixed(2) + ' MiB'
  return value.toLocaleString() + ' B'
}

async function start() {
  if (!ownsLease.value) return ElMessage.warning('请先申请当前板卡使用权')
  if (!status.value?.online) return ElMessage.warning('RFCTRL2 UDP 控制链路未响应')
  if (status.value?.dac_mts_ready === false) return ElMessage.warning('DAC MTS 未就绪，请先执行一键同步')
  busy.value = true
  try {
    const record = await boards.startMaxLength(boardId.value, { ...form })
    tests.value.unshift(record)
    selectedId.value = record.id
    startPolling()
    ElMessage.success('极限长度测试已开始')
  } catch (error) {
    ElMessage.error('启动失败：' + errorMessage(error))
  } finally {
    busy.value = false
  }
}

async function abortCurrent() {
  if (!currentTest.value) return
  try {
    await boards.abortMaxLength(currentTest.value.id)
    await load()
    ElMessage.success('测试已终止')
  } catch (error) {
    ElMessage.error(errorMessage(error))
  }
}

function startPolling() {
  stopPolling()
  pollTimer = window.setInterval(async () => {
    tests.value = (await boards.maxLengthTests()).filter((item) => item.board_id === boardId.value)
    const active = tests.value.find((item) => activeStates.includes(item.state))
    if (!active) stopPolling()
  }, 1000)
}

function stopPolling() {
  if (pollTimer) {
    window.clearInterval(pollTimer)
    pollTimer = undefined
  }
}

onMounted(() => { load().catch((error) => ElMessage.error(errorMessage(error))) })
onBeforeUnmount(stopPolling)
</script>

<template>
  <div class="page-stack">
    <BoardContextHeader :board-id="boardId" />
    <section class="work-surface compact-surface">
      <div class="config-section-head">
        <div><h2>通道极限长度测试</h2><p>用低频率正弦波写满 DDR 可用区，上传后触发一次完整播放，统计极限长度、上传吞吐和播放时长。</p></div>
      </div>
      <div class="max-length-form-grid">
        <label><span>测试名称</span><el-input v-model="form.name" /></label>
        <label><span>每通道字节数 <small>0 = 满 DDR</small></span><el-input-number v-model="form.bytes_per_channel" :min="0" :step="1024 * 1024" controls-position="right" /></label>
        <label><span>数据模式</span><el-select v-model="form.pattern"><el-option label="低频正弦" value="lowfreq-sine" /><el-option label="CW 标记" value="cw-marker" /></el-select></label>
        <label><span>正弦频率 <small>Hz</small></span><el-input-number v-model="form.sine_freq_hz" :min="0" :max="1_000_000" controls-position="right" /></label>
        <label><span>正弦幅值 <small>code</small></span><el-input-number v-model="form.sine_amplitude" :min="0" :max="32767" controls-position="right" /></label>
        <label><span>每包 beats <small>0 = 安全上限</small></span><el-input-number v-model="form.beats_per_datagram" :min="0" :step="64" controls-position="right" /></label>
        <el-checkbox v-model="form.auto_trigger">上传后自动触发播放</el-checkbox>
        <el-checkbox v-model="form.dry_run">仅生成元数据（dry run）</el-checkbox>
      </div>
      <div class="sync-actions">
        <el-button type="primary" :icon="Play" :loading="busy" @click="start">开始测试</el-button>
        <el-button type="danger" plain :icon="Square" :disabled="!currentTest || !activeStates.includes(currentTest.state)" @click="abortCurrent">终止当前测试</el-button>
      </div>
    </section>

    <section class="work-surface">
      <div class="config-section-head">
        <div><h2>测试记录</h2><p>{{ tests.length }} 条记录，选择一条查看结果。</p></div>
        <el-select :model-value="selectedId" placeholder="选择测试记录" style="width: 420px" @change="selectedId = $event">
          <el-option v-for="item in tests" :key="item.id" :label="item.name + ' · ' + stateLabel(item.state) + ' · ' + formatBytes(item.bytes_per_channel)" :value="item.id" />
        </el-select>
      </div>
      <template v-if="currentTest">
        <div class="metric-strip">
          <div><dt>状态</dt><dd><el-tag :type="stateType(currentTest.state)">{{ stateLabel(currentTest.state) }}</el-tag></dd></div>
          <div><dt>每通道长度</dt><dd>{{ formatBytes(currentTest.bytes_per_channel) }}</dd></div>
          <div><dt>DDR 总量</dt><dd>{{ formatBytes(currentTest.physical_bytes) }}</dd></div>
          <div><dt>理论播放时长</dt><dd>{{ currentTest.theoretical_duration_s.toFixed(6) }} s</dd></div>
          <div><dt>实测播放时长</dt><dd>{{ currentTest.play_elapsed_s ? currentTest.play_elapsed_s.toFixed(6) + ' s' : '-' }}</dd></div>
          <div><dt>上传速率</dt><dd>{{ currentTest.upload_mbps ? currentTest.upload_mbps.toFixed(1) + ' MB/s' : '-' }}</dd></div>
          <div><dt>上传耗时</dt><dd>{{ currentTest.upload_elapsed_s ? currentTest.upload_elapsed_s.toFixed(2) + ' s' : '-' }}</dd></div>
          <div><dt>错误</dt><dd>{{ currentTest.error || '无' }}</dd></div>
        </div>
        <div class="progress-bar"><el-progress :percentage="Math.round(currentTest.progress * 100)" :status="currentTest.state === 'FAILED' ? 'exception' : currentTest.state === 'COMPLETED' ? 'success' : undefined" /></div>
        <el-alert v-if="currentTest.error" type="error" :closable="false" show-icon :title="currentTest.error" />
      </template>
    </section>
  </div>
</template>
