<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { Download, RefreshCw, Search } from 'lucide-vue-next'
import { useBoardsStore } from '../stores/boards'
import { useTestsStore } from '../stores/tests'
import type { PerformanceTestRecord } from '../types'
import { formatTime, stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const tests = useTestsStore()
const router = useRouter()
const filter = ref({ board: '', state: '', query: '' })
const selected = ref<PerformanceTestRecord | null>(null)
const drawer = ref(false)
const filtered = computed(() => tests.items.filter((item) => (!filter.value.board || item.board_id === filter.value.board) && (!filter.value.state || item.state === filter.value.state) && (!filter.value.query || item.name.toLowerCase().includes(filter.value.query.toLowerCase()))))
async function open(row: PerformanceTestRecord) { selected.value = row; drawer.value = true; await tests.fetchPoints(row.id) }
function resume() { if (selected.value) router.push({ path: '/boards/' + selected.value.board_id + '/sweep', query: { test: selected.value.id } }) }
function exportSelected(extension: 'csv' | 'json') { if (selected.value) window.location.href = '/api/tests/' + selected.value.id + '/export.' + extension }
onMounted(async () => { await Promise.all([boards.fetchAll(false), tests.fetchAll()]) })
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">记录中心</span><h1>性能测试</h1><p>查看扫描点位、结构化测量结果和测试环境快照。</p></div><el-button :icon="RefreshCw" @click="tests.fetchAll">刷新</el-button></header>
    <section class="work-surface">
      <div class="filter-bar"><el-select v-model="filter.board" clearable placeholder="全部板卡"><el-option v-for="board in boards.boards" :key="board.id" :label="board.name" :value="board.id" /></el-select><el-select v-model="filter.state" clearable placeholder="全部状态"><el-option v-for="state in ['DRAFT','RUNNING','PAUSED','COMPLETED','ABORTED','FAILED']" :key="state" :label="stateLabel(state)" :value="state" /></el-select><el-input v-model="filter.query" clearable :prefix-icon="Search" placeholder="测试名称" /></div>
      <el-table :data="filtered" height="calc(100vh - 290px)" @row-click="open">
        <el-table-column prop="name" label="测试名称" min-width="220" /><el-table-column label="板卡" width="160"><template #default="{ row }">{{ boards.byId(row.board_id)?.name || row.board_id }}</template></el-table-column>
        <el-table-column prop="scan_axis" label="扫描参数" width="180" /><el-table-column label="范围" width="220"><template #default="{ row }">{{ row.scan_start }} → {{ row.scan_stop }} / {{ row.scan_step }} {{ row.scan_unit }}</template></el-table-column>
        <el-table-column label="进度" width="180"><template #default="{ row }"><el-progress :percentage="row.total_points ? Math.round(row.current_point / row.total_points * 100) : 0" :stroke-width="8" /></template></el-table-column>
        <el-table-column prop="state" label="状态" width="120"><template #default="{ row }"><el-tag :type="stateType(row.state)">{{ stateLabel(row.state) }}</el-tag></template></el-table-column>
        <el-table-column label="更新时间" width="190"><template #default="{ row }">{{ formatTime(row.updated_at) }}</template></el-table-column>
      </el-table>
    </section>
    <el-drawer v-model="drawer" title="性能测试详情" size="800px">
      <template v-if="selected">
        <div class="record-title"><div><h2>{{ selected.name }}</h2><code>{{ selected.id }}</code></div><el-tag :type="stateType(selected.state)">{{ stateLabel(selected.state) }}</el-tag></div>
        <div class="drawer-actions"><el-button v-if="!['COMPLETED','ABORTED','FAILED'].includes(selected.state)" type="primary" @click="resume">继续测试</el-button><el-button :icon="Download" @click="exportSelected('csv')">CSV</el-button><el-button :icon="Download" @click="exportSelected('json')">JSON</el-button></div>
        <el-table :data="tests.points[selected.id] || []" height="460"><el-table-column prop="index" label="#" width="60" /><el-table-column label="设定"><template #default="{ row }">{{ row.parameters.scan_value }} {{ row.parameters.scan_unit }}</template></el-table-column><el-table-column prop="state" label="状态" width="110"><template #default="{ row }"><el-tag :type="stateType(row.state)">{{ stateLabel(row.state) }}</el-tag></template></el-table-column><el-table-column label="测量结果" min-width="240"><template #default="{ row }"><span class="json-summary">{{ Object.keys(row.measurement || {}).length ? JSON.stringify(row.measurement) : '未录入' }}</span></template></el-table-column></el-table>
        <el-collapse class="expert-collapse"><el-collapse-item title="测试环境快照"><pre class="json-view">{{ JSON.stringify(selected.environment, null, 2) }}</pre></el-collapse-item></el-collapse>
      </template>
    </el-drawer>
  </div>
</template>
