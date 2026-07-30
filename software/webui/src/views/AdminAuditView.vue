<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { RefreshCw, Search, ShieldCheck } from 'lucide-vue-next'
import { api } from '../api/client'
import type { AuditEvent } from '../types'
import { formatTime } from '../utils/format'

const events = ref<AuditEvent[]>([])
const query = ref('')
const filtered = computed(() => events.value.filter((item) => !query.value || (item.type + item.message + (item.username || '') + (item.board_id || '')).toLowerCase().includes(query.value.toLowerCase())))
async function load() { events.value = await api<AuditEvent[]>('/api/audit') }
onMounted(load)
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">管理中心</span><h1>审计记录</h1><p>追踪租约、发波、RFDC 配置、部署和账号管理操作。</p></div><el-button :icon="RefreshCw" @click="load">刷新</el-button></header>
    <section class="work-surface">
      <div class="filter-bar"><el-input v-model="query" clearable :prefix-icon="Search" placeholder="搜索事件、用户、板卡或内容" /></div>
      <el-table :data="filtered" height="calc(100vh - 305px)">
        <el-table-column label="时间" width="190"><template #default="{ row }">{{ formatTime(row.created_at) }}</template></el-table-column>
        <el-table-column prop="username" label="用户" width="140" /><el-table-column prop="board_id" label="板卡" width="150" />
        <el-table-column prop="type" label="事件类型" width="210"><template #default="{ row }"><div class="audit-type"><ShieldCheck :size="16" />{{ row.type }}</div></template></el-table-column>
        <el-table-column prop="message" label="内容" min-width="320" /><el-table-column label="元数据" min-width="240"><template #default="{ row }"><span class="json-summary">{{ JSON.stringify(row.metadata) }}</span></template></el-table-column>
      </el-table>
    </section>
  </div>
</template>
