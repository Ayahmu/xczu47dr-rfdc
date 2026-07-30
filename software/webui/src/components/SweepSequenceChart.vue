<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { init, type ECharts } from '../utils/charting'

const props = defineProps<{ values: number[]; current: number; unit: string; states?: string[] }>()
const element = ref<HTMLElement | null>(null)
let chart: ECharts | null = null
function draw() {
  if (!chart) return
  chart.setOption({
    animation: false, grid: { left: 58, right: 20, top: 24, bottom: 42 }, tooltip: { trigger: 'axis' },
    xAxis: { type: 'category', name: '点位', data: props.values.map((_, index) => index + 1), boundaryGap: false },
    yAxis: { type: 'value', name: props.unit || '值', splitLine: { lineStyle: { color: '#e6ebf0' } } },
    series: [{ type: 'line', step: 'end', showSymbol: true, symbolSize: 7,
      lineStyle: { width: 2, color: '#1f6feb' }, itemStyle: { color: (params: { dataIndex: number }) => {
        const state = props.states?.[params.dataIndex]
        if (state === 'FAILED') return '#c93c37'
        if (['READY', 'MEASURED'].includes(state || '')) return '#168a62'
        return params.dataIndex === props.current ? '#d17a00' : '#1f6feb'
      } }, data: props.values,
      markPoint: props.current < props.values.length ? { symbolSize: 38, data: [{ coord: [props.current, props.values[props.current]], value: '当前' }] } : undefined }],
  }, { notMerge: true })
}
function resize() { chart?.resize() }
onMounted(async () => { await nextTick(); if (element.value) chart = init(element.value); window.addEventListener('resize', resize); draw() })
watch(() => [props.values, props.current, props.states], draw, { deep: true })
onBeforeUnmount(() => { window.removeEventListener('resize', resize); chart?.dispose() })
</script>
<template><div ref="element" class="sweep-chart"></div></template>
