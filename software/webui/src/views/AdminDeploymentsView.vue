<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Check, Copy, Cpu, Download, RefreshCw, Upload } from 'lucide-vue-next'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api, errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import type { ArtifactRecord, BoardPreflight, ProgramJob, SerialLogLine } from '../types'
import { formatTime, stateType } from '../utils/format'

const boards = useBoardsStore()
const artifacts = ref<ArtifactRecord[]>([])
const jobs = ref<ProgramJob[]>([])
const logs = ref<SerialLogLine[]>([])
const selectedJob = ref('')
const step = ref(0)
const targetBoardId = ref('')
const artifactId = ref('')
const preflight = ref<BoardPreflight | null>(null)
const running = ref(false)
const uploadOpen = ref(false)
const uploadForm = reactive({ label: '', target_profile: 'custom_xczu47dr', bit: null as File | null, elf: null as File | null })
const targetBoard = computed(() => boards.byId(targetBoardId.value))
const artifact = computed(() => artifacts.value.find((item) => item.id === artifactId.value))
const activeRun = computed(() => targetBoard.value && boards.statusById(targetBoard.value.id)?.playback_running)
const deploymentReady = computed(() => {
  const required = ['enabled', 'artifact', 'jtag', 'run']
  return Boolean(preflight.value && required.every((key) => preflight.value!.checks.find((item) => item.key === key)?.state === 'pass') && !targetBoard.value?.lease && !activeRun.value)
})
async function load() { [artifacts.value, jobs.value] = await Promise.all([api<ArtifactRecord[]>('/api/artifacts'), api<ProgramJob[]>('/api/programs')]); await boards.fetchAll(false) }
async function runPreflight() {
  if (!targetBoardId.value || !artifactId.value) return ElMessage.warning('请先选择板卡和发布版本')
  try { preflight.value = await api<BoardPreflight>('/api/boards/' + targetBoardId.value + '/preflight?refresh=true&artifact_id=' + encodeURIComponent(artifactId.value)); step.value = 2 }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function deploy() {
  if (!targetBoard.value || !artifact.value) return
  try {
    await ElMessageBox.confirm(
      '目标板卡：' + targetBoard.value.name + '（JTAG ' + (targetBoard.value.jtag_cable_serial || '未绑定') + '）\n发布：' + artifact.value.label + '\n将复位 PS、加载 bitstream 与 firmware。',
      '最终部署确认', { type: 'warning', confirmButtonText: '确认部署', cancelButtonText: '取消', dangerouslyUseHTMLString: false },
    )
    running.value = true
    const job = await api<ProgramJob>('/api/admin/boards/' + targetBoardId.value + '/programs', { method: 'POST', body: { artifact_id: artifactId.value } })
    jobs.value.unshift(job); selectedJob.value = job.id; step.value = 3; await selectJob(job)
  } catch (error) { if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error)) }
  finally { running.value = false }
}
async function clearTargetUse() {
  if (!targetBoard.value) return
  try {
    await ElMessageBox.confirm('目标板卡：' + targetBoard.value.name + '。将停止当前输出、静音并强制释放现有租约，然后重新预检。', '清理板卡占用', { type: 'warning', confirmButtonText: '停止并强制释放' })
    if (activeRun.value) await boards.abort(targetBoard.value.id)
    if (targetBoard.value.lease) await boards.forceRelease(targetBoard.value.id)
    await boards.fetchAll(true); await runPreflight()
  } catch (error) { if (error !== 'cancel' && error !== 'close') ElMessage.error(errorMessage(error)) }
}
function choose(event: Event, kind: 'bit' | 'elf') { const file = (event.target as HTMLInputElement).files?.[0] || null; uploadForm[kind] = file }
async function upload() {
  if (!uploadForm.label || !uploadForm.bit || !uploadForm.elf) return ElMessage.warning('请填写名称并选择 .bit 与 .elf')
  const body = new FormData(); body.append('label', uploadForm.label); body.append('target_profile', uploadForm.target_profile); body.append('bitstream', uploadForm.bit); body.append('firmware', uploadForm.elf)
  try { await api('/api/admin/artifacts', { method: 'POST', body }); uploadOpen.value = false; artifacts.value = await api('/api/artifacts'); ElMessage.success('发布版本已上传') }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function selectJob(job: ProgramJob) { selectedJob.value = job.id; logs.value = await api<SerialLogLine[]>('/api/programs/' + job.id + '/logs') }
function logText() { return logs.value.map((item) => formatTime(item.created_at) + ' ' + item.line).join('\n') }
async function copyLogs() { await navigator.clipboard.writeText(logText()); ElMessage.success('部署日志已复制') }
onMounted(load)
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">管理中心</span><h1>JTAG 临时部署</h1><p>严格按目标板卡、不可变发布、预检、确认和执行的顺序操作。</p></div><el-button :icon="Upload" @click="uploadOpen = true">上传发布版本</el-button></header>
    <section class="work-surface deployment-wizard">
      <el-steps :active="step" finish-status="success"><el-step title="选择目标" description="板卡与发布版本" /><el-step title="执行预检" description="租约、任务、JTAG、工具" /><el-step title="确认影响" description="核对唯一目标" /><el-step title="部署" description="查看 XSCT 日志" /></el-steps>
      <div v-if="step <= 1" class="wizard-selection">
        <label><span>目标板卡</span><el-select v-model="targetBoardId" placeholder="选择唯一目标板卡" @change="preflight = null"><el-option v-for="board in boards.boards.filter(item => item.enabled)" :key="board.id" :label="board.name + ' · ' + board.jtag_cable_serial" :value="board.id" /></el-select></label>
        <label><span>发布版本</span><el-select v-model="artifactId" placeholder="选择已校验发布" @change="preflight = null"><el-option v-for="item in artifacts" :key="item.id" :label="item.label + ' · ' + item.target_profile" :value="item.id" /></el-select></label>
        <div v-if="targetBoard && artifact" class="deployment-target"><Cpu :size="28" /><div><strong>{{ targetBoard.name }} → {{ artifact.label }}</strong><span>{{ targetBoard.ip }} · JTAG {{ targetBoard.jtag_cable_serial || '未绑定' }} · {{ artifact.target_profile }}</span></div></div>
        <el-button type="primary" :disabled="!targetBoardId || !artifactId" @click="runPreflight">执行部署预检</el-button>
      </div>
      <div v-if="step === 2" class="wizard-preflight">
        <div class="check-list"><div v-for="check in preflight?.checks || []" :key="check.key" :class="['check-row', check.state]"><Check :size="18" /><div><strong>{{ check.label }}</strong><span>{{ check.message }}</span></div></div></div>
        <el-alert v-if="targetBoard?.lease" type="error" show-icon :closable="false" :title="'当前租约：' + targetBoard.lease.username + '。部署前必须释放。'" />
        <el-alert v-if="activeRun" type="error" show-icon :closable="false" title="目标板卡正在输出，部署前必须停止并静音。" />
        <el-alert type="info" show-icon :closable="false" title="部署不要求持有租约，也不以 RFCTRL2 在线作为烧写前提；JTAG、发布兼容性、无租约和无运行任务是阻断条件。" />
        <div class="wizard-actions"><el-button @click="step = 0">返回修改</el-button><el-button v-if="targetBoard?.lease || activeRun" type="warning" @click="clearTargetUse">停止并强制释放</el-button><el-button type="danger" :disabled="!deploymentReady" :loading="running" @click="deploy">核对后部署</el-button></div>
      </div>
      <div v-if="step === 3" class="wizard-running">
        <el-alert type="info" show-icon :closable="false" title="部署任务已提交。JTAG 全局串行执行，请等待状态完成。" />
        <el-table :data="jobs" @row-click="selectJob"><el-table-column prop="id" label="任务" min-width="240" /><el-table-column prop="board_id" label="板卡" /><el-table-column prop="state" label="状态"><template #default="{ row }"><el-tag :type="stateType(row.state)">{{ row.state }}</el-tag></template></el-table-column><el-table-column label="进度"><template #default="{ row }"><el-progress :percentage="Math.round(row.progress * 100)" /></template></el-table-column><el-table-column prop="error" label="错误" /></el-table>
      </div>
    </section>
    <section v-if="selectedJob" class="work-surface">
      <div class="config-section-head"><div><h2>XSCT 原始日志</h2><p>{{ selectedJob }}</p></div><div class="inline-actions"><el-button :icon="RefreshCw" @click="selectJob(jobs.find(item => item.id === selectedJob)!)">刷新</el-button><el-button :icon="Copy" @click="copyLogs">复制</el-button></div></div>
      <pre class="terminal-view deployment-log"><span v-for="(line, index) in logs" :key="line.created_at + index"><time>{{ new Date(line.created_at).toLocaleTimeString('zh-CN', { hour12: false }) }}</time> {{ line.line }}</span></pre>
    </section>
    <el-dialog v-model="uploadOpen" title="上传不可变发布版本" width="680px">
      <el-form label-position="top"><el-form-item label="发布名称"><el-input v-model="uploadForm.label" /></el-form-item><el-form-item label="目标配置"><el-select v-model="uploadForm.target_profile"><el-option label="custom_xczu47dr" value="custom_xczu47dr" /><el-option label="custom_xczu47dr_b" value="custom_xczu47dr_b" /><el-option label="custom_xczu47dr_bw" value="custom_xczu47dr_bw" /></el-select></el-form-item><el-form-item label="Bitstream (.bit)"><input type="file" accept=".bit" @change="choose($event, 'bit')" /></el-form-item><el-form-item label="Firmware (.elf)"><input type="file" accept=".elf" @change="choose($event, 'elf')" /></el-form-item></el-form>
      <template #footer><el-button @click="uploadOpen = false">取消</el-button><el-button type="primary" @click="upload">上传并计算 SHA-256</el-button></template>
    </el-dialog>
  </div>
</template>
