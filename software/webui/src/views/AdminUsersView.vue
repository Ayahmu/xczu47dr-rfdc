<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { KeyRound, Plus, UserCog } from 'lucide-vue-next'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api, errorMessage } from '../api/client'
import type { UserRecord } from '../types'
import { formatTime } from '../utils/format'

const users = ref<UserRecord[]>([])
const createOpen = ref(false)
const resetOpen = ref(false)
const selected = ref<UserRecord | null>(null)
const createForm = reactive({ username: '', password: '', role: 'user' as 'admin' | 'user', enabled: true })
const password = ref('')
async function load() { users.value = await api<UserRecord[]>('/api/admin/users') }
async function create() { try { await api('/api/admin/users', { method: 'POST', body: { ...createForm } }); createOpen.value = false; Object.assign(createForm, { username: '', password: '', role: 'user', enabled: true }); await load(); ElMessage.success('用户已创建') } catch (error) { ElMessage.error(errorMessage(error)) } }
async function update(user: UserRecord) {
  try {
    if (!user.enabled) await ElMessageBox.confirm('将停用用户 ' + user.username + '，其后续请求会被拒绝。', '确认停用用户', { type: 'warning' })
    await api('/api/admin/users/' + user.id, { method: 'PATCH', body: { role: user.role, enabled: user.enabled, password: null } }); await load()
  } catch (error) { await load(); if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error)) }
}
function openReset(user: UserRecord) { selected.value = user; password.value = ''; resetOpen.value = true }
async function resetPassword() { if (!selected.value) return; try { await api('/api/admin/users/' + selected.value.id, { method: 'PATCH', body: { role: selected.value.role, enabled: selected.value.enabled, password: password.value } }); resetOpen.value = false; ElMessage.success('密码已重置') } catch (error) { ElMessage.error(errorMessage(error)) } }
onMounted(load)
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">管理中心</span><h1>用户管理</h1><p>账号角色、启停和密码重置均写入审计记录。</p></div><el-button type="primary" :icon="Plus" @click="createOpen = true">创建用户</el-button></header>
    <section class="work-surface">
      <el-table :data="users" height="calc(100vh - 255px)">
        <el-table-column prop="username" label="用户" min-width="220"><template #default="{ row }"><div class="user-cell"><UserCog :size="19" /><strong>{{ row.username }}</strong></div></template></el-table-column>
        <el-table-column label="角色" width="180"><template #default="{ row }"><el-select v-model="row.role" @change="update(row)"><el-option label="普通用户" value="user" /><el-option label="管理员" value="admin" /></el-select></template></el-table-column>
        <el-table-column label="状态" width="150"><template #default="{ row }"><el-switch v-model="row.enabled" active-text="启用" inactive-text="停用" @change="update(row)" /></template></el-table-column>
        <el-table-column label="创建时间"><template #default="{ row }">{{ formatTime(row.created_at) }}</template></el-table-column>
        <el-table-column label="操作" width="150"><template #default="{ row }"><el-button :icon="KeyRound" @click="openReset(row)">重置密码</el-button></template></el-table-column>
      </el-table>
    </section>
    <el-dialog v-model="createOpen" title="创建用户" width="520px"><el-form label-position="top"><el-form-item label="用户名"><el-input v-model="createForm.username" /></el-form-item><el-form-item label="初始密码"><el-input v-model="createForm.password" type="password" show-password /><small>至少 8 位</small></el-form-item><el-form-item label="角色"><el-select v-model="createForm.role"><el-option label="普通用户" value="user" /><el-option label="管理员" value="admin" /></el-select></el-form-item></el-form><template #footer><el-button @click="createOpen=false">取消</el-button><el-button type="primary" :disabled="createForm.password.length < 8" @click="create">创建</el-button></template></el-dialog>
    <el-dialog v-model="resetOpen" :title="'重置 ' + selected?.username + ' 的密码'" width="520px"><el-alert type="warning" show-icon :closable="false" title="重置后旧密码立即失效。" /><el-input v-model="password" class="dialog-password" type="password" show-password placeholder="输入至少 8 位新密码" /><template #footer><el-button @click="resetOpen=false">取消</el-button><el-button type="primary" :disabled="password.length < 8" @click="resetPassword">确认重置</el-button></template></el-dialog>
  </div>
</template>
