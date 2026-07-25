<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { RefreshCw, RotateCcw, Search } from 'lucide-vue-next'
import { ElMessage } from 'element-plus'
import { useBoardsStore } from '../stores/boards'
import { useRunsStore } from '../stores/runs'
import type { RunRecord } from '../types'
import { errorMessage } from '../api/client'
import { formatTime, stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const runs = useRunsStore()
const router = useRouter()
const filter = ref({ board: '', state: '', query: '' })
const drawer = ref(false)
const selected = ref<RunRecord | null>(null)
const filtered = computed(() => runs.items.filter((item) => (!filter.value.board || item.board_ids.includes(filter.value.board)) && (!filter.value.state || item.state === filter.value.state) && (!filter.value.query || (item.name + item.id).toLowerCase().includes(filter.value.query.toLowerCase()))))
async function open(row: RunRecord) { selected.value = row; drawer.value = true; try { await runs.fetchEvents(row.id) } catch (error) { ElMessage.error(errorMessage(error)) } }
function resend() { if (selected.value?.board_ids[0]) router.push('/boards/' + selected.value.board_ids[0] + '/output') }
onMounted(async () => { await Promise.all([boards.fetchAll(false), runs.fetchAll()]) })
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">记录中心</span><h1>发波任务</h1><p>查看一键发送阶段、错误与参数产物；再次发送会重新执行租约和预检。</p></div><el-button :icon="RefreshCw" @click="runs.fetchAll">刷新</el-button></header>
    <section class="work-surface">
      <div class="filter-bar">
        <el-select v-model="filter.board" clearable placeholder="全部板卡"><el-option v-for="board in boards.boards" :key="board.id" :label="board.name" :value="board.id" /></el-select>
        <el-select v-model="filter.state" clearable placeholder="全部状态"><el-option v-for="state in ['DONE','RUNNING','FAULT','ABORTED','UPLOADING']" :key="state" :label="stateLabel(state)" :value="state" /></el-select>
        <el-input v-model="filter.query" clearable :prefix-icon="Search" placeholder="任务名称或 ID" />
      </div>
      <el-table :data="filtered" height="calc(100vh - 290px)" @row-click="open">
        <el-table-column prop="name" label="任务名称" min-width="220" /><el-table-column label="板卡" width="160"><template #default="{ row }">{{ boards.byId(row.board_ids[0])?.name || row.board_ids[0] }}</template></el-table-column>
        <el-table-column prop="state" label="状态" width="120"><template #default="{ row }"><el-tag :type="stateType(row.state)">{{ stateLabel(row.state) }}</el-tag></template></el-table-column>
        <el-table-column label="模式" width="130"><template #default="{ row }">{{ row.dry_run ? '生成校验' : row.completion_mode === 'one_shot' ? '自动静音' : '仅上传' }}</template></el-table-column>
        <el-table-column label="进度" width="150"><template #default="{ row }"><el-progress :percentage="Math.round(row.progress * 100)" :stroke-width="8" /></template></el-table-column>
        <el-table-column label="创建时间" width="190"><template #default="{ row }">{{ formatTime(row.created_at) }}</template></el-table-column>
        <el-table-column prop="error" label="错误" min-width="220" show-overflow-tooltip />
      </el-table>
    </section>
    <el-drawer v-model="drawer" title="发波任务详情" size="680px">
      <template v-if="selected">
        <div class="record-title"><div><h2>{{ selected.name }}</h2><code>{{ selected.id }}</code></div><el-tag :type="stateType(selected.state)">{{ stateLabel(selected.state) }}</el-tag></div>
        <dl class="detail-grid record-details"><div><dt>目标板卡</dt><dd>{{ boards.byId(selected.board_ids[0])?.name || selected.board_ids[0] }}</dd></div><div><dt>完成策略</dt><dd>{{ selected.completion_mode }}</dd></div><div><dt>创建</dt><dd>{{ formatTime(selected.created_at) }}</dd></div><div><dt>更新</dt><dd>{{ formatTime(selected.updated_at) }}</dd></div></dl>
        <el-alert v-if="selected.error" type="error" show-icon :closable="false" :title="selected.error" />
        <div class="drawer-actions"><el-button type="primary" :icon="RotateCcw" @click="resend">返回配置并再次发送</el-button></div>
        <h3 class="drawer-section-title">运行事件</h3>
        <div class="event-timeline"><div v-for="event in runs.events[selected.id] || []" :key="event.timestamp + event.message" :class="event.level"><time>{{ formatTime(event.timestamp) }}</time><span>{{ event.message }}</span></div></div>
        <el-collapse class="expert-collapse"><el-collapse-item title="专家信息"><dl class="detail-grid"><div><dt>Artifact</dt><dd>{{ selected.artifact_dir }}</dd></div><div><dt>执行模式</dt><dd>{{ selected.execution_mode }}</dd></div><div><dt>波形已加载</dt><dd>{{ selected.loaded ? '是' : '否' }}</dd></div></dl></el-collapse-item></el-collapse>
      </template>
    </el-drawer>
  </div>
</template>
