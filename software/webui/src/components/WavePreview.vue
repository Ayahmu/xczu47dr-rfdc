<script setup lang="ts">
import * as echarts from 'echarts'
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { PreviewResponse } from '../types'

const props = defineProps<{ preview: PreviewResponse | null }>()

const timeElement = ref<HTMLElement | null>(null)
const fftElement = ref<HTMLElement | null>(null)
let timeChart: echarts.ECharts | null = null
let fftChart: echarts.ECharts | null = null

const palette = ['#1677ff', '#d84a32', '#00a870', '#b67900', '#7c4dff', '#007f87', '#c2386b', '#596780']
const series = computed(() => props.preview?.series ?? [])

function draw() {
  if (!timeChart || !fftChart) return
  const preview = props.preview
  if (!preview) {
    timeChart.clear()
    fftChart.clear()
    return
  }
  timeChart.setOption({
    animation: false,
    color: palette,
    grid: { left: 54, right: 20, top: 34, bottom: 42 },
    tooltip: { trigger: 'axis' },
    legend: { top: 2, textStyle: { color: '#697386' }, itemWidth: 12 },
    xAxis: { type: 'value', name: 'ns', nameLocation: 'middle', nameGap: 28, nameTextStyle: { color: '#697386' }, axisLabel: { color: '#697386' }, splitLine: { lineStyle: { color: '#e8edf3' } } },
    yAxis: { type: 'value', name: 'I code', nameTextStyle: { color: '#697386' }, axisLabel: { color: '#697386' }, splitLine: { lineStyle: { color: '#e8edf3' } } },
    series: preview.series.map((channel) => ({
      name: `CH${channel.channel}`,
      type: 'line',
      showSymbol: false,
      lineStyle: { width: 1.2 },
      data: channel.time_ns.map((value, index) => [value, channel.i[index]]),
    })),
  }, { notMerge: true })
  fftChart.setOption({
    animation: false,
    color: ['#1677ff'],
    grid: { left: 54, right: 20, top: 26, bottom: 42 },
    tooltip: { trigger: 'axis' },
    xAxis: { type: 'value', name: 'MHz', nameLocation: 'middle', nameGap: 28, nameTextStyle: { color: '#697386' }, axisLabel: { color: '#697386' }, splitLine: { lineStyle: { color: '#e8edf3' } } },
    yAxis: { type: 'value', name: 'dBc', nameTextStyle: { color: '#697386' }, axisLabel: { color: '#697386' }, splitLine: { lineStyle: { color: '#e8edf3' } } },
    series: [{
      type: 'line',
      showSymbol: false,
      lineStyle: { width: 1.25 },
      data: preview.fft_frequency_mhz.map((value, index) => [value, preview.fft_db[index]]),
    }],
  }, { notMerge: true })
}

function resize() {
  timeChart?.resize()
  fftChart?.resize()
}

onMounted(async () => {
  await nextTick()
  if (timeElement.value) timeChart = echarts.init(timeElement.value)
  if (fftElement.value) fftChart = echarts.init(fftElement.value)
  window.addEventListener('resize', resize)
  draw()
})

watch(() => props.preview, draw, { deep: true })

onBeforeUnmount(() => {
  window.removeEventListener('resize', resize)
  timeChart?.dispose()
  fftChart?.dispose()
})
</script>

<template>
  <div class="preview-stack">
    <div class="chart-title"><span>8 通道 I 波形</span><small v-if="preview">{{ (preview.sample_rate_hz / 1e6).toFixed(0) }} MS/s</small></div>
    <div ref="timeElement" class="chart-canvas"></div>
    <div class="chart-title"><span>CH{{ preview?.fft_channel ?? 1 }} 频谱</span><small v-if="preview">{{ preview.bytes_per_channel }} B / CH</small></div>
    <div ref="fftElement" class="chart-canvas chart-canvas-small"></div>
  </div>
</template>
