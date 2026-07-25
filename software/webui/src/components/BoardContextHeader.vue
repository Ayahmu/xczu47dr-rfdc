<script setup lang="ts">
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Cable, Cpu, KeyRound, Network, Radio, RefreshCw, ShieldCheck, Square } from 'lucide-vue-next'
import { ElMessage, ElMessageBox } from 'element-plus'
import { useBoardsStore } from '../stores/boards'
import { useSessionStore } from '../stores/session'
import { errorMessage } from '../api/client'
import { stateLabel, stateType } from '../utils/format'

const props = defineProps<{ boardId: string }>()
const boards = useBoardsStore()
const session = useSessionStore()
const route = useRoute()
const router = useRouter()
const board = computed(() => boards.byId(props.boardId))
const status = computed(() => boards.statusById(props.boardId))
const ownsLease = computed(() => board.value?.lease?.user_id === session.user?.id)
const detected = computed(() => {
  const serial = board.value?.jtag_cable_serial
  return Boolean(serial && boards.discoveries.some((item) => item.kind === 'jtag' && String(item.details.cable_serial || '') === serial))
})
const tabs = computed(() => [
  { label: '输出控制', path: '/boards/' + props.boardId + '/output' },
  { label: '参数扫描', path: '/boards/' + props.boardId + '/sweep' },
  { label: '诊断与串口', path: '/boards/' + props.boardId + '/diagnostics' },
])
async function leaseAction() {
  if (!board.value) return
  const acquiring = !board.value.lease
  try {
    if (!board.value.lease) await boards.acquire(props.boardId)
    else if (ownsLease.value) await boards.release(props.boardId)
    else if (session.isAdmin) {
      await ElMessageBox.confirm('当前使用者：' + board.value.lease.username + '。强制释放会先停止相关运行并静音。', '强制释放使用权', { type: 'warning', confirmButtonText: '强制释放' })
      await boards.forceRelease(props.boardId)
    }
    ElMessage.success(acquiring ? '已取得板卡使用权' : '使用权已释放')
  } catch (error) { if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error)) }
}
</script>
<template>
  <section v-if="board" class="board-context">
    <div class="board-context-main">
      <div>
        <button class="back-link" @click="router.push('/boards')">板卡列表 /</button>
        <h1>{{ board.name }}</h1>
        <p>{{ board.model }} · {{ board.location || '未填写位置' }} · {{ board.ip }}:{{ board.port }}</p>
      </div>
      <div class="board-context-actions">
        <el-button :icon="RefreshCw" @click="boards.refreshStatus(boardId, true)">刷新 PL</el-button>
        <el-button :type="ownsLease ? 'default' : 'primary'" :icon="KeyRound" @click="leaseAction">
          {{ !board.lease ? '申请使用权' : ownsLease ? '释放使用权' : session.isAdmin ? '强制释放' : board.lease.username + ' 使用中' }}
        </el-button>
      </div>
    </div>
    <div class="status-rail">
      <div><Cable :size="18" /><span>设备发现<small>USB / JTAG</small></span><el-tag :type="detected ? 'success' : 'info'">{{ detected ? '已发现' : '未发现' }}</el-tag></div>
      <div><Network :size="18" /><span>控制链路<small>RFCTRL2 UDP</small></span><el-tag :type="status?.online ? 'success' : 'danger'">{{ status?.online ? '已连接' : '未响应' }}</el-tag></div>
      <div><Cpu :size="18" /><span>RFDC<small>Tile / PLL</small></span><el-tag :type="status?.rfdc_ready === true ? 'success' : status?.rfdc_ready === false ? 'warning' : 'info'">{{ status?.rfdc_ready === true ? '已就绪' : status?.rfdc_ready === false ? '未就绪' : '无法确认' }}</el-tag></div>
      <div><Radio :size="18" /><span>播放状态<small>PL datapath</small></span><el-tag :type="stateType(status?.state)">{{ stateLabel(status?.state) }}</el-tag></div>
      <div><ShieldCheck :size="18" /><span>使用权<small>控制互斥</small></span><el-tag :type="ownsLease ? 'success' : board.lease ? 'warning' : 'info'">{{ ownsLease ? '由我持有' : board.lease ? board.lease.username : '未申请' }}</el-tag></div>
    </div>
    <nav class="workspace-tabs"><router-link v-for="tab in tabs" :key="tab.path" :to="tab.path" :class="{ active: route.path === tab.path }">{{ tab.label }}</router-link></nav>
  </section>
</template>
