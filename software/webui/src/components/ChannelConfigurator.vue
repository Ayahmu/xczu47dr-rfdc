<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { Copy, Settings2 } from 'lucide-vue-next'
import { channelColors } from '../utils/format'
import { ncoPlan, type OutputDraft } from '../stores/drafts'

const props = defineProps<{ draft: OutputDraft; readbackRevision?: number; validMask?: number }>()
const emit = defineEmits<{ dirty: [] }>()
const advanced = ref(false)
const bulkOpen = ref(false)
const bulk = reactive({ targets: [] as number[], fields: ['dataAmplitude', 'dataPhaseDeg', 'dataOffsetMhz'] as string[] })
const active = computed(() => props.draft.channels[props.draft.activeChannel - 1])
const currentRange = computed(() => active.value.channel === 5 || active.value.channel === 6 ? { min: 6.4, max: 32 } : { min: 2.25, max: 40.5 })
const fieldOptions = [
  ['waveform', '波形类型'], ['format', 'IQ / Real'], ['targetRfGhz', '最终 RF'], ['dataAmplitude', '幅值'], ['dataPhaseDeg', '数据相位'],
  ['dataOffsetMhz', '基带偏移'], ['channelDurationNs', '通道波形长度'], ['delayNs', '延迟'], ['dacCurrentMa', 'DAC 输出电流'],
  ['ncoMode', 'NCO 模式'], ['ncoMhz', 'NCO 频率'], ['ncoPhaseDeg', 'NCO 相位'], ['nyquistZone', 'Nyquist zone'],
]
function touch() { emit('dirty') }
function selectChannel(channel: number, event?: MouseEvent) {
  props.draft.activeChannel = channel
  if (event?.ctrlKey || event?.metaKey) {
    const selected = new Set(props.draft.selectedChannels)
    selected.has(channel) ? selected.delete(channel) : selected.add(channel)
    props.draft.selectedChannels = [...selected].sort()
  } else props.draft.selectedChannels = [channel]
}
function updateAutoNco() {
  if (active.value.ncoMode === 'auto') Object.assign(active.value, ncoPlan(active.value.targetRfGhz))
  touch()
}
function openBulk() { bulk.targets = [...props.draft.selectedChannels]; bulkOpen.value = true }
function applyBulk() {
  const source = active.value as unknown as Record<string, unknown>
  for (const target of bulk.targets) {
    if (target === active.value.channel) continue
    const destination = props.draft.channels[target - 1] as unknown as Record<string, unknown>
    for (const field of bulk.fields) destination[field] = source[field]
  }
  bulkOpen.value = false; touch()
}
watch(() => active.value.ncoMode, updateAutoNco)
</script>
<template>
  <div class="channel-configurator">
    <div class="config-section-head">
      <div><h2>通道配置</h2><p>点击编辑单个通道；按住 Ctrl 点击可多选后批量应用。</p></div>
      <el-button :icon="Copy" :disabled="draft.selectedChannels.length < 2" @click="openBulk">批量应用到 {{ draft.selectedChannels.length }} 路</el-button>
    </div>
    <div class="channel-strip">
      <button v-for="channel in draft.channels" :key="channel.channel" :class="{ active: channel.channel === draft.activeChannel, selected: draft.selectedChannels.includes(channel.channel), disabled: !channel.enabled }" @click="selectChannel(channel.channel, $event)">
        <i :style="{ background: channelColors[channel.channel - 1] }"></i>
        <span>CH{{ channel.channel }}<small>{{ channel.channel <= 4 ? 'XY' : channel.channel <= 6 ? 'Z' : 'RO' }}</small></span>
        <strong>{{ channel.targetRfGhz.toFixed(3) }} GHz</strong>
        <em>{{ channel.dataAmplitude.toFixed(3) }}</em>
      </button>
    </div>
    <div class="channel-editor">
      <div class="editor-title">
        <div><i :style="{ background: channelColors[active.channel - 1] }"></i><strong>CH{{ active.channel }}</strong><span>{{ active.channel === 5 || active.channel === 6 ? 'DC coupling' : 'AC coupling' }}</span></div>
        <el-switch v-model="active.enabled" active-text="启用输出" @change="touch" />
      </div>
      <div class="form-grid basic-grid">
        <label><span>波形类型</span><el-select v-model="active.waveform" @change="touch"><el-option label="正弦" value="sine" /><el-option label="XY" value="xy" /><el-option label="Readout" value="readout" /><el-option label="Z" value="z" /></el-select></label>
        <label><span>数据格式</span><el-segmented v-model="active.format" :options="[{ label: 'IQ', value: 'iq' }, { label: 'Real', value: 'real' }]" @change="touch" /></label>
        <label><span>最终 RF <small>GHz</small></span><el-input-number v-model="active.targetRfGhz" :min="0" :max="6.4" :step="0.001" :precision="6" controls-position="right" @change="updateAutoNco" /></label>
        <label><span>数据幅值 <small>-1 .. 1</small></span><el-input-number v-model="active.dataAmplitude" :min="-1" :max="1" :step="0.01" :precision="4" controls-position="right" @change="touch" /></label>
        <label><span>数据相位 <small>deg</small></span><el-input-number v-model="active.dataPhaseDeg" :min="-3600" :max="3600" :step="1" controls-position="right" @change="touch" /></label>
        <label><span>通道波形长度 <small>ns</small></span><el-input-number v-model="active.channelDurationNs" :min="1" :max="draft.recordDurationNs" :step="10" controls-position="right" @change="touch" /></label>
        <label><span>延迟 <small>ns</small></span><el-input-number v-model="active.delayNs" :min="0" :max="draft.recordDurationNs" :step="10" controls-position="right" @change="touch" /></label>
        <label><span>DAC 输出电流 <small>mA，不是 dBm</small></span><el-input-number v-model="active.dacCurrentMa" :min="currentRange.min" :max="currentRange.max" :step="0.05" :precision="2" controls-position="right" @change="touch" /></label>
      </div>
      <button class="advanced-toggle" @click="advanced = !advanced"><Settings2 :size="17" /><span>{{ advanced ? '收起高级参数' : '展开高级参数' }}</span></button>
      <div v-if="advanced" class="advanced-panel">
        <div class="form-grid">
          <label><span>基带偏移 <small>MHz</small></span><el-input-number v-model="active.dataOffsetMhz" :min="-160" :max="160" :step="0.1" :precision="6" controls-position="right" @change="touch" /></label>
          <label><span>NCO 控制</span><el-segmented v-model="active.ncoMode" :options="[{ label: '自动', value: 'auto' }, { label: '手动', value: 'manual' }]" @change="touch" /></label>
          <label><span>NCO 频率 <small>MHz</small></span><el-input-number v-model="active.ncoMhz" :disabled="active.ncoMode === 'auto'" :min="-3200" :max="3200" :step="0.1" :precision="6" controls-position="right" @change="touch" /></label>
          <label><span>NCO 相位 <small>deg</small></span><el-input-number v-model="active.ncoPhaseDeg" :min="-3600" :max="3600" :step="1" controls-position="right" @change="touch" /></label>
          <label><span>Nyquist zone</span><el-select v-model="active.nyquistZone" :disabled="active.ncoMode === 'auto'" @change="touch"><el-option label="Zone 1" :value="1" /><el-option label="Zone 2" :value="2" /></el-select></label>
          <label><span>相位校准偏移 <small>deg</small></span><el-input-number v-model="active.calibrationPhaseDeg" :step="0.1" :precision="3" controls-position="right" @change="touch" /></label>
          <label><span>NCO 校准偏移 <small>MHz</small></span><el-input-number v-model="active.calibrationNcoMhz" :step="0.001" :precision="6" controls-position="right" @change="touch" /></label>
          <div class="readback-box"><span>PL 回读</span><strong>revision {{ readbackRevision || 0 }}</strong><small>有效通道 0x{{ (validMask || 0).toString(16).toUpperCase().padStart(2, '0') }}</small></div>
        </div>
      </div>
    </div>
    <el-dialog v-model="bulkOpen" title="确认批量覆盖" width="620px">
      <el-alert type="warning" :closable="false" show-icon title="仅覆盖下方勾选字段；未勾选字段保持各通道原值。" />
      <div class="bulk-dialog-row"><span>来源</span><strong>CH{{ active.channel }}</strong></div>
      <div class="bulk-dialog-row"><span>目标通道</span><el-checkbox-group v-model="bulk.targets"><el-checkbox v-for="channel in draft.channels" :key="channel.channel" :value="channel.channel" :disabled="channel.channel === active.channel">CH{{ channel.channel }}</el-checkbox></el-checkbox-group></div>
      <div class="bulk-dialog-row"><span>覆盖字段</span><el-checkbox-group v-model="bulk.fields"><el-checkbox v-for="item in fieldOptions" :key="item[0]" :value="item[0]">{{ item[1] }}</el-checkbox></el-checkbox-group></div>
      <template #footer><el-button @click="bulkOpen = false">取消</el-button><el-button type="primary" :disabled="!bulk.targets.length || !bulk.fields.length" @click="applyBulk">确认覆盖</el-button></template>
    </el-dialog>
  </div>
</template>
