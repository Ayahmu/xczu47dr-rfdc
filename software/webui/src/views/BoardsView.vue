<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ArrowRight, Cable, KeyRound, Network, Radar, RefreshCw } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import { useSessionStore } from '../stores/session'
import { stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const session = useSessionStore()
const router = useRouter()
const scanning = ref(false)
const enabledBoards = computed(() => boards.boards.filter((item) => item.enabled))
function detected(board: { device_uid: string; last_seen_at: string }) { return Boolean(board.device_uid && board.last_seen_at) }
async function scanNetwork() {
  scanning.value = true
  try {
    const result = await boards.scanNetwork()
    const count = result.boards.length
    ElMessage.success(count ? `已发现 ${count} 块 FPGA 板卡` : '扫描完成，未发现可连接板卡')
  } catch (error) { ElMessage.error(errorMessage(error)) }
  finally { scanning.value = false }
}
</script>
<template>
  <div class="page-stack">
    <header class="page-heading">
      <div><span class="eyebrow">板卡工作区</span><h1>扫描网口并选择板卡</h1><p>工作区只显示已经通过 RFCTRL2 发现并加入的 FPGA。</p></div>
      <div class="heading-actions">
        <el-button :icon="Radar" type="primary" :loading="scanning" @click="scanNetwork">扫描网口</el-button>
        <el-button :icon="RefreshCw" :loading="boards.loading" @click="boards.fetchAll(true)">刷新状态</el-button>
      </div>
    </header>
    <div class="board-list-grid">
      <article v-for="board in enabledBoards" :key="board.id" class="board-workspace-card">
        <header><div><h2>{{ board.name }}</h2><p>{{ board.model }} · {{ board.location || '未填写位置' }}</p></div><el-tag :type="stateType(boards.statusById(board.id)?.state)">{{ stateLabel(boards.statusById(board.id)?.state) }}</el-tag></header>
        <dl>
          <div><dt>控制地址</dt><dd>{{ board.ip }}:{{ board.port }}</dd></div>
          <div><dt>服务器网卡</dt><dd>{{ board.udp_interface }}</dd></div>
          <div><dt>设备发现</dt><dd><Cable :size="16" />{{ detected(board) ? '已发现' : '未发现' }}</dd></div>
          <div><dt>RFCTRL2</dt><dd><Network :size="16" />{{ boards.statusById(board.id)?.online ? '已连接' : '未响应' }}</dd></div>
          <div><dt>RFDC</dt><dd>{{ boards.statusById(board.id)?.rfdc_ready === true ? '已就绪' : boards.statusById(board.id)?.rfdc_ready === false ? '未就绪' : '无法确认' }}</dd></div>
          <div><dt>使用权</dt><dd><KeyRound :size="16" />{{ board.lease ? (board.lease.user_id === session.user?.id ? '由我持有' : board.lease.username) : '未申请' }}</dd></div>
        </dl>
        <p v-if="boards.statusById(board.id)?.message" class="card-message">{{ boards.statusById(board.id)?.message }}</p>
        <footer><el-button type="primary" :icon="ArrowRight" @click="router.push('/boards/' + board.id + '/output')">进入工作区</el-button></footer>
      </article>
      <div v-if="!enabledBoards.length" class="empty-panel"><Cable :size="32" /><h2>工作区还没有 FPGA 板卡</h2><p>请先扫描服务器 10G 网口，收到 RFCTRL2 响应后会自动加入工作区。</p><el-button type="primary" :icon="Radar" :loading="scanning" @click="scanNetwork">扫描网口</el-button></div>
    </div>
  </div>
</template>
