<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { Download, Pause, Play, Plus, Save, Send, Square } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import BoardContextHeader from '../components/BoardContextHeader.vue'
import ChannelConfigurator from '../components/ChannelConfigurator.vue'
import SweepSequenceChart from '../components/SweepSequenceChart.vue'
import { errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import { useDraftsStore, outputRfdc, type SweepAxis } from '../stores/drafts'
import { useSessionStore } from '../stores/session'
import { useTestsStore } from '../stores/tests'
import type { BoardRfdcConfig, PerformancePointRecord, PhaseCalibrationRecord } from '../types'
import { stateLabel, stateType } from '../utils/format'

const route = useRoute()
const boards = useBoardsStore()
const drafts = useDraftsStore()
const session = useSessionStore()
const tests = useTestsStore()
const boardId = computed(() => String(route.params.boardId))
const board = computed(() => boards.byId(boardId.value))
const rfdc = ref<BoardRfdcConfig | null>(null)
const calibrations = ref<PhaseCalibrationRecord[]>([])
const output = computed(() => drafts.output(boardId.value, rfdc.value))
const sweep = computed(() => drafts.sweep(boardId.value))
const selectedTestId = ref('')
const selectedTest = computed(() => tests.byId(selectedTestId.value))
const points = computed(() => selectedTestId.value ? tests.points[selectedTestId.value] || [] : [])
const busy = ref(false)
const measurementPoint = ref<PerformancePointRecord | null>(null)
const measurementOpen = ref(false)
const measurement = reactive({ measured_value: null as number | null, measured_frequency_hz: null as number | null, output_power_dbm: null as number | null, measured_phase_deg: null as number | null, reference_shared: false, method: '', instrument: '', notes: '' })
const axes: Array<{ value: SweepAxis; label: string; unit: string; min: number; max: number }> = [
  { value: 'data_amplitude', label: 'IQ 数据幅值', unit: '', min: -1, max: 1 },
  { value: 'data_offset_hz', label: '基带偏移', unit: 'MHz', min: -160, max: 160 },
  { value: 'data_phase_deg', label: '数据相位', unit: 'deg', min: -3600, max: 3600 },
  { value: 'target_rf_hz', label: '最终 RF', unit: 'GHz', min: 0, max: 6.4 },
  { value: 'nco_hz', label: 'NCO 频率', unit: 'MHz', min: -3200, max: 3200 },
  { value: 'nco_phase_deg', label: 'NCO 相位', unit: 'deg', min: -3600, max: 3600 },
  { value: 'dac_output_current_ma', label: 'DAC 输出电流', unit: 'mA', min: 2.25, max: 40.5 },
]
const axisMeta = computed(() => {
  const meta = axes.find((item) => item.value === sweep.value.axis) || axes[0]
  if (meta.value === 'dac_output_current_ma' && output.value.channels.some((item) => item.enabled && [5, 6].includes(item.channel))) return { ...meta, min: 6.4, max: 32 }
  return meta
})
const values = computed(() => {
  const result: number[] = []; const { start, stop, step } = sweep.value
  if (![start, stop, step].every(Number.isFinite) || !step || (stop - start) * step < 0 || start < axisMeta.value.min || start > axisMeta.value.max || stop < axisMeta.value.min || stop > axisMeta.value.max) return result
  for (let index = 0; index < 10000; index += 1) {
    const value = Number((start + step * index).toPrecision(12))
    if ((step > 0 && value > stop + Math.abs(step) * 1e-9) || (step < 0 && value < stop - Math.abs(step) * 1e-9)) break
    result.push(value)
  }
  return result
})
const enabledChannels = computed(() => output.value.channels.filter((item) => item.enabled))
const currentIndex = computed(() => selectedTest.value?.current_point || 0)
const nextPoint = computed(() => points.value.find((item) => item.index === currentIndex.value))
function hardwareValue(value: number) { return sweep.value.axis === 'target_rf_hz' ? value * 1e9 : ['data_offset_hz', 'nco_hz'].includes(sweep.value.axis) ? value * 1e6 : value }
function kind() { return ['data_amplitude', 'dac_output_current_ma'].includes(sweep.value.axis) ? 'amplitude' : ['data_phase_deg', 'nco_phase_deg'].includes(sweep.value.axis) ? 'phase' : 'frequency' }
function makePoints() {
  return values.value.map((value) => {
    const channel_configs: Record<string, Record<string, number>> = {}
    for (const channel of enabledChannels.value) {
      const config: Record<string, number> = { dac_output_current_ma: channel.dacCurrentMa, data_amplitude: channel.dataAmplitude,
        data_offset_hz: channel.dataOffsetMhz * 1e6, data_phase_deg: channel.dataPhaseDeg, target_rf_hz: channel.targetRfGhz * 1e9,
        nco_hz: channel.ncoMhz * 1e6, nco_phase_deg: channel.ncoPhaseDeg, duration_ns: channel.channelDurationNs }
      config[sweep.value.axis] = hardwareValue(value)
      if (sweep.value.axis === 'target_rf_hz') delete config.nco_hz
      channel_configs[String(channel.channel)] = config
    }
    return { scan_axis: sweep.value.axis, scan_value: value, scan_unit: axisMeta.value.unit, channel_configs }
  })
}
async function createSession() {
  if (!enabledChannels.value.length) return ElMessage.warning('请至少启用一个输出通道')
  if (!values.value.length) return ElMessage.warning('扫描范围或步进方向无效')
  busy.value = true
  try {
    const selected = enabledChannels.value.map((item) => item.channel)
    const record = await tests.create({ name: sweep.value.name, board_id: boardId.value, kind: kind(), channel: selected[0], channels: selected,
      mode: sweep.value.mode, points: makePoints(), settle_ms: sweep.value.settleMs, auto_mute: sweep.value.autoMute, dry_run: false,
      scan_axis: sweep.value.axis, scan_start: sweep.value.start, scan_stop: sweep.value.stop, scan_step: sweep.value.step, scan_unit: axisMeta.value.unit })
    selectedTestId.value = record.id; await tests.fetchPoints(record.id); drafts.saveSweep(boardId.value)
    ElMessage.success('扫描会话已创建')
  } catch (error) { ElMessage.error('创建失败：' + errorMessage(error)) }
  finally { busy.value = false }
}
async function startOrContinue() {
  if (!selectedTest.value) return
  try { await tests.action(selectedTest.value.id, 'start'); await tests.fetchPoints(selectedTest.value.id) }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function sendNext() {
  if (!selectedTest.value) return
  busy.value = true
  try {
    if (['DRAFT', 'PAUSED'].includes(selectedTest.value.state)) await tests.action(selectedTest.value.id, 'start')
    const test = tests.byId(selectedTest.value.id)!
    const point = (tests.points[test.id] || []).find((item) => item.index === test.current_point)
    const index = point && ['READY', 'MEASURED'].includes(point.state) ? Math.min(test.current_point + 1, test.total_points - 1) : test.current_point
    await tests.execute(test.id, index)
    const updated = await import('../api/client').then(({ api }) => api<import('../types').PerformanceTestRecord>('/api/tests/' + test.id))
    tests.upsert(updated); await tests.fetchPoints(test.id)
  } catch (error) { ElMessage.error('点位执行失败：' + errorMessage(error)) }
  finally { busy.value = false }
}
async function pause() { if (selectedTest.value) await tests.action(selectedTest.value.id, 'pause') }
async function stop() { if (selectedTest.value) await tests.action(selectedTest.value.id, 'abort') }
function openMeasurement(point: PerformancePointRecord) { measurementPoint.value = point; Object.assign(measurement, { measured_value: null, measured_frequency_hz: null, output_power_dbm: null, measured_phase_deg: null, reference_shared: false, method: '', instrument: '', notes: '' }, point.measurement); measurementOpen.value = true }
async function saveMeasurement() {
  if (!selectedTest.value || !measurementPoint.value) return
  try { await tests.measurement(selectedTest.value.id, measurementPoint.value.index, { ...measurement }); measurementOpen.value = false; ElMessage.success('测量结果已保存') }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function selectTest(id: string) { selectedTestId.value = id; if (id) await tests.fetchPoints(id) }
function exportTest(extension: 'csv' | 'json') { if (selectedTestId.value) window.location.href = '/api/tests/' + selectedTestId.value + '/export.' + extension }
onMounted(async () => {
  drafts.setUser(session.user?.username || '')
  if (!boards.loaded) await boards.fetchAll(false)
  const [nextRfdc, nextCalibrations] = await Promise.all([boards.rfdc(boardId.value, false), boards.phaseCalibrations(boardId.value)])
  rfdc.value = nextRfdc
  calibrations.value = nextCalibrations
  drafts.output(boardId.value, rfdc.value, calibrations.value)
  drafts.syncFromServer(boardId.value, rfdc.value, calibrations.value)
  drafts.sweep(boardId.value)
  await tests.fetchAll()
  const requested = String(route.query.test || '')
  if (requested && tests.byId(requested)?.board_id === boardId.value) await selectTest(requested)
})
watch(() => sweep.value.axis, () => { sweep.value.dirty = true })
</script>
<template>
  <div class="page-stack">
    <BoardContextHeader :board-id="boardId" />
    <section class="sweep-layout">
      <div class="page-stack">
        <section class="work-surface">
          <div class="config-section-head"><div><h2>扫描基线</h2><p>扫描轴只覆盖选定字段，其余参数取下方通道配置。</p></div><el-button :icon="Save" @click="drafts.saveSweep(boardId)">保存扫描草稿</el-button></div>
          <ChannelConfigurator :draft="output" :calibrations="calibrations" :readback-revision="rfdc?.revision" :valid-mask="rfdc?.config_valid_mask" @dirty="drafts.markDirty(boardId)" />
        </section>
      </div>
      <aside class="sweep-control">
        <section class="work-surface sticky-surface">
          <div class="config-section-head"><div><h2>扫描序列</h2><p>范围包含终点，支持正向和反向步进。</p></div></div>
          <div class="vertical-form">
            <label><span>会话名称</span><el-input v-model="sweep.name" /></label>
            <label><span>扫描参数</span><el-select v-model="sweep.axis"><el-option v-for="item in axes" :key="item.value" :label="item.label" :value="item.value" /></el-select></label>
            <div class="range-grid">
              <label><span>起点 <small>{{ axisMeta.unit }}</small></span><el-input-number v-model="sweep.start" :min="axisMeta.min" :max="axisMeta.max" :step="0.05" controls-position="right" /></label>
              <label><span>终点 <small>{{ axisMeta.unit }}</small></span><el-input-number v-model="sweep.stop" :min="axisMeta.min" :max="axisMeta.max" :step="0.05" controls-position="right" /></label>
              <label><span>步进 <small>{{ axisMeta.unit }}</small></span><el-input-number v-model="sweep.step" :step="0.05" controls-position="right" /></label>
            </div>
            <div class="sweep-count"><span>预计点数</span><strong>{{ values.length }}</strong><small v-if="!values.length">请检查步进方向</small></div>
            <label><span>执行模式</span><el-segmented v-model="sweep.mode" :options="[{ label: '逐点手动', value: 'manual' }, { label: '自动连续', value: 'automatic' }]" /></label>
            <label><span>每点稳定等待 <small>ms</small></span><el-input-number v-model="sweep.settleMs" :min="0" :max="60000" controls-position="right" /></label>
            <el-checkbox v-model="sweep.autoMute">每个点执行后自动静音</el-checkbox>
          </div>
          <SweepSequenceChart :values="values" :current="currentIndex" :unit="axisMeta.unit" :states="points.map(item => item.state)" />
          <el-button type="primary" class="full-button" :icon="Plus" :loading="busy" @click="createSession">创建扫描会话</el-button>
        </section>
      </aside>
    </section>
    <section class="work-surface">
      <div class="config-section-head">
        <div><h2>执行会话</h2><p>{{ selectedTest ? selectedTest.name + ' · ' + selectedTest.current_point + ' / ' + selectedTest.total_points : '创建或选择一条扫描会话' }}</p></div>
        <el-select :model-value="selectedTestId" placeholder="选择历史会话" style="width:360px" @change="selectTest"><el-option v-for="item in tests.items.filter(test => test.board_id === boardId)" :key="item.id" :label="item.name + ' · ' + stateLabel(item.state)" :value="item.id" /></el-select>
      </div>
      <div v-if="selectedTest" class="session-command-bar">
        <el-tag :type="stateType(selectedTest.state)">{{ stateLabel(selectedTest.state) }}</el-tag>
        <template v-if="selectedTest.mode === 'manual'"><el-button type="primary" size="large" :icon="Send" :loading="busy" :disabled="['COMPLETED', 'ABORTED', 'FAILED'].includes(selectedTest.state)" @click="sendNext">发送第 {{ Math.min(selectedTest.current_point + 1, selectedTest.total_points) }} 点</el-button></template>
        <template v-else>
          <el-button v-if="['DRAFT', 'PAUSED'].includes(selectedTest.state)" type="primary" :icon="Play" @click="startOrContinue">{{ selectedTest.state === 'PAUSED' ? '继续' : '开始' }}</el-button>
          <el-button v-if="selectedTest.state === 'RUNNING'" :icon="Pause" @click="pause">暂停</el-button>
        </template>
        <el-button type="danger" plain :icon="Square" :disabled="['COMPLETED', 'ABORTED', 'FAILED'].includes(selectedTest.state)" @click="stop">停止</el-button>
        <div class="session-spacer"></div>
        <el-button :icon="Download" @click="exportTest('csv')">CSV</el-button>
        <el-button :icon="Download" @click="exportTest('json')">JSON</el-button>
      </div>
      <el-table v-if="selectedTest" :data="points" height="410">
        <el-table-column prop="index" label="点位" width="80"><template #default="{ row }">#{{ row.index + 1 }}</template></el-table-column>
        <el-table-column label="设定值" width="150"><template #default="{ row }">{{ row.parameters.scan_value }} {{ row.parameters.scan_unit }}</template></el-table-column>
        <el-table-column label="通道"><template #default="{ row }">{{ Object.keys(row.parameters.channel_configs || {}).map(item => 'CH' + item).join(', ') }}</template></el-table-column>
        <el-table-column prop="state" label="状态" width="120"><template #default="{ row }"><el-tag :type="stateType(row.state)">{{ stateLabel(row.state) }}</el-tag></template></el-table-column>
        <el-table-column prop="error" label="错误" min-width="180" />
        <el-table-column label="测量" width="120"><template #default="{ row }"><el-button size="small" @click="openMeasurement(row)">录入结果</el-button></template></el-table-column>
      </el-table>
    </section>
    <el-dialog v-model="measurementOpen" title="录入结构化测量结果" width="760px">
      <div class="measurement-form">
        <label><span>通用测量值</span><el-input-number v-model="measurement.measured_value" controls-position="right" /></label>
        <label><span>实测频率 <small>Hz</small></span><el-input-number v-model="measurement.measured_frequency_hz" :min="0" controls-position="right" /></label>
        <label><span>输出功率 <small>dBm</small></span><el-input-number v-model="measurement.output_power_dbm" :step="0.1" controls-position="right" /></label>
        <label><span>实测相位 <small>deg</small></span><el-input-number v-model="measurement.measured_phase_deg" :step="0.1" controls-position="right" /></label>
        <label><span>测量仪器</span><el-input v-model="measurement.instrument" placeholder="频谱仪 / 示波器 / 功率计" /></label>
        <label><span>测量方法</span><el-input v-model="measurement.method" /></label>
        <el-checkbox v-model="measurement.reference_shared">使用共参考</el-checkbox>
        <label class="full-field"><span>备注</span><el-input v-model="measurement.notes" type="textarea" :rows="3" /></label>
      </div>
      <template #footer><el-button @click="measurementOpen = false">取消</el-button><el-button type="primary" @click="saveMeasurement">保存结果</el-button></template>
    </el-dialog>
  </div>
</template>
