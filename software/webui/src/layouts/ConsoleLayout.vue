<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Activity, BookOpen, Boxes, ChevronDown, CircleUserRound, Cpu, FileClock, Gauge, LogOut, RadioTower, Shield, Square, Users, Waves } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { ElMessageBox } from 'element-plus/es/components/message-box/index'
import { useSessionStore } from '../stores/session'
import { useBoardsStore } from '../stores/boards'
import { useRunsStore } from '../stores/runs'
import { useTestsStore } from '../stores/tests'
import { useEventsStore } from '../stores/events'
import { errorMessage } from '../api/client'

const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const boards = useBoardsStore()
const runs = useRunsStore()
const tests = useTestsStore()
const events = useEventsStore()

const boardId = computed(() => String(route.params.boardId || ''))
const currentBoard = computed(() => boards.byId(boardId.value))
const breadcrumb = computed(() => {
  const parts = ['RFDC 控制台']
  if (currentBoard.value) parts.push(currentBoard.value.name)
  if (route.meta.title) parts.push(String(route.meta.title))
  return parts
})
const workspacePath = computed(() => boardId.value ? '/boards/' + boardId.value + '/output' : '/boards')

const groups = computed(() => [
  { label: '操作', items: [
    { label: '板卡工作区', path: workspacePath.value, icon: Gauge, prefix: '/boards' },
  ] },
  { label: '记录', items: [
    { label: '发波任务', path: '/records/runs', icon: FileClock },
    { label: '性能测试', path: '/records/tests', icon: Activity },
  ] },
  ...(session.isAdmin ? [{ label: '管理', items: [
    { label: '板卡与资源', path: '/admin/boards', icon: Boxes },
    { label: 'JTAG 部署', path: '/admin/deployments', icon: Cpu },
    { label: '用户管理', path: '/admin/users', icon: Users },
    { label: '审计记录', path: '/admin/audit', icon: Shield },
  ] }] : []),
])

function active(item: { path: string; prefix?: string }) {
  return item.prefix ? route.path.startsWith(item.prefix) : route.path === item.path
}
async function emergencyMute() {
  if (!currentBoard.value) return
  try {
    await ElMessageBox.confirm(
      '目标板卡：' + currentBoard.value.name + '（' + currentBoard.value.ip + '）。此操作会立即终止当前输出并静音。',
      '确认停止并静音', { type: 'warning', confirmButtonText: '停止并静音', cancelButtonText: '取消' },
    )
    await boards.abort(currentBoard.value.id)
    ElMessage.success('板卡已停止并静音')
  } catch (error) {
    if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error))
  }
}
async function logout() {
  events.disconnect()
  await session.logout()
  await router.replace('/login')
}

onMounted(async () => {
  await Promise.all([boards.fetchAll(false), runs.fetchAll(), tests.fetchAll()])
  events.connect()
})
onBeforeUnmount(() => events.disconnect())
</script>

<template>
  <div class="console-shell">
    <aside class="console-sidebar">
      <div class="console-brand">
        <div class="brand-symbol"><RadioTower :size="22" /></div>
        <div><strong>XCZU47DR</strong><span>RFDC 控制台</span></div>
      </div>
      <nav class="console-nav">
        <section v-for="group in groups" :key="group.label">
          <div class="nav-group-label">{{ group.label }}</div>
          <router-link v-for="item in group.items" :key="item.path" :to="item.path" class="nav-item" :class="{ active: active(item) }">
            <component :is="item.icon" :size="19" /><span>{{ item.label }}</span>
          </router-link>
        </section>
      </nav>
      <div class="sidebar-version"><BookOpen :size="15" /><span>单板运行模式</span></div>
    </aside>
    <div class="console-workspace">
      <header class="console-topbar">
        <el-breadcrumb separator="/">
          <el-breadcrumb-item v-for="(part, index) in breadcrumb" :key="part + index">{{ part }}</el-breadcrumb-item>
        </el-breadcrumb>
        <div class="topbar-actions">
          <span class="socket-state" :class="events.state"><i></i>{{ events.state === 'connected' ? '实时连接正常' : events.state === 'connecting' ? '正在连接' : '实时连接断开' }}</span>
          <el-button v-if="currentBoard" type="danger" plain :icon="Square" @click="emergencyMute">停止并静音</el-button>
          <el-dropdown trigger="click">
            <button class="user-menu"><CircleUserRound :size="20" /><span>{{ session.user?.username }}</span><small>{{ session.isAdmin ? '管理员' : '用户' }}</small><ChevronDown :size="15" /></button>
            <template #dropdown><el-dropdown-menu><el-dropdown-item :icon="LogOut" @click="logout">退出登录</el-dropdown-item></el-dropdown-menu></template>
          </el-dropdown>
        </div>
      </header>
      <main class="console-main"><router-view /></main>
    </div>
  </div>
</template>
