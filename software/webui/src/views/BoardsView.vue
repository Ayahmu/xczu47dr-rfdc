<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { ArrowRight, Cable, KeyRound, Network, RefreshCw } from 'lucide-vue-next'
import { useBoardsStore } from '../stores/boards'
import { useSessionStore } from '../stores/session'
import { stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const session = useSessionStore()
const router = useRouter()
const enabledBoards = computed(() => boards.boards.filter((item) => item.enabled))
function detected(serial: string) { return Boolean(serial && boards.discoveries.some((item) => item.kind === 'jtag' && String(item.details.cable_serial || '') === serial)) }
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">板卡工作区</span><h1>选择一块板卡开始操作</h1><p>使用权、控制链路和设备发现分别显示，不再合并为单一 ONLINE 状态。</p></div><el-button :icon="RefreshCw" :loading="boards.loading" @click="boards.fetchAll(true)">刷新状态</el-button></header>
    <div class="board-list-grid">
      <article v-for="board in enabledBoards" :key="board.id" class="board-workspace-card">
        <header><div><h2>{{ board.name }}</h2><p>{{ board.model }} · {{ board.location || '未填写位置' }}</p></div><el-tag :type="stateType(boards.statusById(board.id)?.state)">{{ stateLabel(boards.statusById(board.id)?.state) }}</el-tag></header>
        <dl>
          <div><dt>控制地址</dt><dd>{{ board.ip }}:{{ board.port }}</dd></div>
          <div><dt>服务器网卡</dt><dd>{{ board.udp_interface }}</dd></div>
          <div><dt>设备发现</dt><dd><Cable :size="16" />{{ detected(board.jtag_cable_serial) ? '已发现' : '未发现' }}</dd></div>
          <div><dt>RFCTRL2</dt><dd><Network :size="16" />{{ boards.statusById(board.id)?.online ? '已连接' : '未响应' }}</dd></div>
          <div><dt>RFDC</dt><dd>{{ boards.statusById(board.id)?.rfdc_ready === true ? '已就绪' : boards.statusById(board.id)?.rfdc_ready === false ? '未就绪' : '无法确认' }}</dd></div>
          <div><dt>使用权</dt><dd><KeyRound :size="16" />{{ board.lease ? (board.lease.user_id === session.user?.id ? '由我持有' : board.lease.username) : '未申请' }}</dd></div>
        </dl>
        <p v-if="boards.statusById(board.id)?.message" class="card-message">{{ boards.statusById(board.id)?.message }}</p>
        <footer><el-button type="primary" :icon="ArrowRight" @click="router.push('/boards/' + board.id + '/output')">进入工作区</el-button></footer>
      </article>
      <div v-if="!enabledBoards.length" class="empty-panel"><Cable :size="32" /><h2>没有已登记板卡</h2><p>请管理员先在管理中心登记板卡档案。</p></div>
    </div>
  </div>
</template>
