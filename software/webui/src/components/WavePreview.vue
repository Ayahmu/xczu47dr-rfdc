<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { PreviewResponse } from '../types'
import { channelColors } from '../utils/format'
import { init, type ECharts } from '../utils/charting'

const props = withDefaults(defineProps<{ preview: PreviewResponse | null; channels?: number[] }>(), { channels: () => [] })
const timeElement = ref<HTMLElement | null>(null)
const fftElement = ref<HTMLElement | null>(null)
let timeChart: ECharts | null = null
let fftChart: ECharts | null = null
const visibleSeries = computed(() => (props.preview?.series || []).filter((item) => !props.channels.length || props.channels.includes(item.channel)))

function draw() {
  if (!timeChart || !fftChart) return
  if (!props.preview) { timeChart.clear(); fftChart.clear(); return }
  const lines = []
  for (const channel of visibleSeries.value) {
    lines.push({ name: 'CH' + channel.channel + ' · ' + channel.domain.toUpperCase(), type: 'line', showSymbol: false, lineStyle: { width: 1.5, color: channelColors[channel.channel - 1] }, data: channel.time_ns.map((value, index) => [value, channel.value[index]]) })
  }
  timeChart.setOption({ animation: false, grid: { left: 64, right: 20, top: 42, bottom: 46 }, tooltip: { trigger: 'axis' }, legend: { top: 4, type: 'scroll' },
    xAxis: { type: 'value', name: '时间 / ns', nameLocation: 'middle', nameGap: 31 }, yAxis: { type: 'value', name: 'int16 code', splitLine: { lineStyle: { color: '#e8edf3' } } }, series: lines }, { notMerge: true })
  fftChart.setOption({ animation: false, grid: { left: 64, right: 20, top: 24, bottom: 46 }, tooltip: { trigger: 'axis' },
    xAxis: { type: 'value', name: '频率 / MHz', nameLocation: 'middle', nameGap: 31 }, yAxis: { type: 'value', name: 'dBc', splitLine: { lineStyle: { color: '#e8edf3' } } },
    series: [{ type: 'line', showSymbol: false, lineStyle: { width: 1.5, color: channelColors[(props.preview.fft_channel || 1) - 1] }, areaStyle: { opacity: .04 },
      data: props.preview.fft_frequency_mhz.map((value, index) => [value, props.preview!.fft_db[index]]) }] }, { notMerge: true })
}
function resize() { timeChart?.resize(); fftChart?.resize() }
onMounted(async () => { await nextTick(); if (timeElement.value) timeChart = init(timeElement.value); if (fftElement.value) fftChart = init(fftElement.value); window.addEventListener('resize', resize); draw() })
watch([() => props.preview, () => props.channels], draw, { deep: true })
onBeforeUnmount(() => { window.removeEventListener('resize', resize); timeChart?.dispose(); fftChart?.dispose() })
</script>
<template>
  <div class="preview-stack">
    <div class="chart-title"><span>最终时域波形</span><small v-if="preview">DAC {{ (preview.sample_rate_hz / 1e6).toFixed(0) }} MS/s · IQ 已按 NCO 合成 / Real 直接输出</small></div>
    <div ref="timeElement" class="chart-canvas"></div>
    <div class="chart-title"><span>CH{{ preview?.fft_channel || 1 }} 频谱</span><small v-if="preview">{{ preview.series.length }} 路数据</small></div>
    <div ref="fftElement" class="chart-canvas chart-canvas-small"></div>
  </div>
</template>
