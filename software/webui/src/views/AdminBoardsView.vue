<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Cable, Edit3, Plus, RefreshCw, Search } from 'lucide-vue-next'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '../api/client'
import { useBoardsStore } from '../stores/boards'
import type { BoardProfile, InventoryScanResult, NetworkConfigSnapshot, SerialPortInfo, UdpInterface } from '../types'
import { formatTime, stateLabel, stateType } from '../utils/format'

const boards = useBoardsStore()
const activeTab = ref('profiles')
const drawer = ref(false)
const editingId = ref('')
const scanning = ref(false)
const serialPorts = ref<SerialPortInfo[]>([])
const network = ref<NetworkConfigSnapshot | null>(null)
const query = ref('')
const form = reactive({
  name: '', model: 'XCZU47DR RFDC', role: 'master' as 'master' | 'follower', ip: '192.168.1.128', port: 1234, mac: '',
  bootstrap_ip: '192.168.254.254', desired_ip: '', active_ip: '', desired_mac: '', active_mac: '', device_uid: '',
  network_revision: 0, network_apply_status: 'unknown', network_apply_error: '',
  udp_interface: 'enp225s0f0' as UdpInterface, udp_source_ip: '192.168.1.10', clock_source: 'onboard' as 'onboard' | 'master-10mhz',
  target_profile: 'custom_xczu47dr', sync_group: '', jtag_cable_serial: '', serial_path: '', baud_rate: 115200, location: '', notes: '', enabled: true,
})
const filtered = computed(() => boards.boards.filter((item) => !query.value || (item.name + item.id + item.ip).toLowerCase().includes(query.value.toLowerCase())))
function resetForm() { Object.assign(form, { name: '', model: 'XCZU47DR RFDC', role: 'master', ip: '192.168.1.128', port: 1234, mac: '', bootstrap_ip: '192.168.254.254', desired_ip: '', active_ip: '', desired_mac: '', active_mac: '', device_uid: '', network_revision: 0, network_apply_status: 'unknown', network_apply_error: '', udp_interface: 'enp225s0f0', udp_source_ip: '192.168.1.10', clock_source: 'onboard', target_profile: 'custom_xczu47dr', sync_group: '', jtag_cable_serial: '', serial_path: '', baud_rate: 115200, location: '', notes: '', enabled: true }) }
function edit(board?: BoardProfile) {
  resetForm(); editingId.value = board?.id || ''
  if (board) Object.assign(form, { name: board.name, model: board.model, role: board.role, ip: board.ip, port: board.port, mac: board.mac, bootstrap_ip: board.bootstrap_ip, desired_ip: board.desired_ip, active_ip: board.active_ip, desired_mac: board.desired_mac, active_mac: board.active_mac, device_uid: board.device_uid, network_revision: board.network_revision, network_apply_status: board.network_apply_status, network_apply_error: board.network_apply_error, udp_interface: board.udp_interface, udp_source_ip: board.udp_source_ip, clock_source: board.clock_source, target_profile: board.target_profile, sync_group: board.sync_group, jtag_cable_serial: board.jtag_cable_serial, serial_path: board.serial_path, baud_rate: board.baud_rate, location: board.location, notes: board.notes, enabled: board.enabled })
  drawer.value = true
}
async function save() {
  try {
    const result = await api<BoardProfile>(editingId.value ? '/api/admin/boards/' + editingId.value : '/api/admin/boards', { method: editingId.value ? 'PATCH' : 'POST', body: { ...form } })
    boards.upsertBoard(result); drawer.value = false; ElMessage.success('板卡档案已保存')
  } catch (error) { ElMessage.error(errorMessage(error)) }
}
async function scan() {
  scanning.value = true
  try { await api<InventoryScanResult>('/api/admin/discovery/scan', { method: 'POST' }); await boards.fetchAll(true); serialPorts.value = await api<SerialPortInfo[]>('/api/serial/ports'); ElMessage.success('服务器资源扫描完成') }
  catch (error) { ElMessage.error(errorMessage(error)) }
  finally { scanning.value = false }
}
async function inspectNetwork(board: BoardProfile) {
  try { network.value = await boards.network(board.id, true); editingId.value = board.id; edit(board) }
  catch (error) { ElMessage.error(errorMessage(error)) }
}
async function applyNetwork() {
  if (!network.value) return
  try {
    network.value = await boards.applyNetwork(network.value.board_id, {
      revision: network.value.revision + 1, ip: network.value.desired_ip, mac: network.value.desired_mac,
      subnet_mask: network.value.subnet_mask, gateway: network.value.gateway, port: network.value.port,
    })
    ElMessage.success('PL 网络身份已应用')
  } catch (error) { ElMessage.error(errorMessage(error)) }
}
onMounted(async () => { await boards.fetchAll(false); serialPorts.value = await api<SerialPortInfo[]>('/api/serial/ports') })
</script>
<template>
  <div class="page-stack">
    <header class="page-heading"><div><span class="eyebrow">管理中心</span><h1>板卡与资源</h1><p>维护控制网络、JTAG 和 ttyUSB 映射；同步字段仅为后续功能预留。</p></div><el-button type="primary" :icon="Plus" @click="edit()">登记板卡</el-button></header>
    <section class="work-surface admin-tabs">
      <el-tabs v-model="activeTab">
        <el-tab-pane label="板卡档案" name="profiles">
          <div class="filter-bar"><el-input v-model="query" :prefix-icon="Search" clearable placeholder="搜索名称、ID 或 IP" /><div class="filter-spacer"></div><el-button :icon="RefreshCw" @click="boards.fetchAll(true)">刷新状态</el-button></div>
          <el-table :data="filtered" height="calc(100vh - 330px)">
            <el-table-column prop="name" label="板卡" min-width="180"><template #default="{ row }"><strong>{{ row.name }}</strong><small class="table-subtitle">{{ row.id }} · {{ row.model }}</small></template></el-table-column>
            <el-table-column label="控制网络" min-width="240"><template #default="{ row }">{{ row.active_ip || row.ip }}:{{ row.port }}<small class="table-subtitle">目标 {{ row.desired_ip || row.ip }} · {{ row.udp_interface }}</small></template></el-table-column>
            <el-table-column label="设备 UID" min-width="170"><template #default="{ row }">{{ row.device_uid || '未读取' }}</template></el-table-column>
            <el-table-column label="JTAG / UART" min-width="220"><template #default="{ row }">{{ row.jtag_cable_serial || '未绑定 JTAG' }}<small class="table-subtitle">{{ row.serial_path || '未绑定 ttyUSB' }}</small></template></el-table-column>
            <el-table-column label="运行状态" width="140"><template #default="{ row }"><el-tag :type="stateType(boards.statusById(row.id)?.state)">{{ stateLabel(boards.statusById(row.id)?.state) }}</el-tag></template></el-table-column>
            <el-table-column label="使用权" width="130"><template #default="{ row }">{{ row.lease?.username || '空闲' }}</template></el-table-column>
            <el-table-column label="启用" width="90"><template #default="{ row }"><el-tag :type="row.enabled ? 'success' : 'info'">{{ row.enabled ? '启用' : '停用' }}</el-tag></template></el-table-column>
            <el-table-column label="操作" width="180"><template #default="{ row }"><el-button :icon="Edit3" size="small" @click="edit(row)">编辑</el-button><el-button size="small" @click="inspectNetwork(row)">网络</el-button></template></el-table-column>
          </el-table>
        </el-tab-pane>
        <el-tab-pane label="服务器资源" name="resources">
          <div class="resource-toolbar"><div><h2>USB 与网络资源</h2><p>USB 扫描不打开 Vivado hw_target；ttyUSB 端口单独列出。</p></div><el-button type="primary" :icon="Cable" :loading="scanning" @click="scan">扫描服务器</el-button></div>
          <h3 class="table-heading">UDP 网卡</h3>
          <el-table :data="boards.interfaces"><el-table-column prop="name" label="接口" /><el-table-column label="载波"><template #default="{ row }"><el-tag :type="row.carrier ? 'success' : 'warning'">{{ row.carrier ? '已连接' : '无载波' }}</el-tag></template></el-table-column><el-table-column label="IPv4"><template #default="{ row }">{{ row.ipv4_addresses.join(', ') || '未配置' }}</template></el-table-column><el-table-column prop="message" label="说明" /></el-table>
          <h3 class="table-heading">JTAG / USB 发现</h3>
          <el-table :data="boards.discoveries"><el-table-column prop="kind" label="类型" width="100" /><el-table-column prop="label" label="设备" /><el-table-column label="Cable serial"><template #default="{ row }">{{ row.details.cable_serial || '-' }}</template></el-table-column><el-table-column prop="board_id" label="绑定板卡"><template #default="{ row }">{{ row.board_id || '待登记' }}</template></el-table-column><el-table-column label="最近发现"><template #default="{ row }">{{ formatTime(row.last_seen_at) }}</template></el-table-column></el-table>
          <h3 class="table-heading">ttyUSB 串口</h3>
          <el-table :data="serialPorts"><el-table-column prop="path" label="端口" /><el-table-column prop="manufacturer" label="制造商" /><el-table-column prop="serial_number" label="序列号" /><el-table-column prop="bound_board_id" label="绑定板卡"><template #default="{ row }">{{ row.bound_board_id || '未绑定' }}</template></el-table-column></el-table>
        </el-tab-pane>
      </el-tabs>
    </section>
    <el-drawer v-model="drawer" :title="editingId ? '编辑板卡档案' : '登记板卡'" size="720px">
      <el-form label-position="top" class="admin-form">
        <div class="form-section-title">基本信息</div>
        <div class="form-grid"><el-form-item label="板卡名称"><el-input v-model="form.name" /></el-form-item><el-form-item label="型号"><el-input v-model="form.model" /></el-form-item><el-form-item label="位置"><el-input v-model="form.location" /></el-form-item><el-form-item label="目标配置"><el-select v-model="form.target_profile"><el-option label="custom_xczu47dr（统一正常运行）" value="custom_xczu47dr" /><el-option label="custom_xczu47dr_bw（DDR 带宽测试）" value="custom_xczu47dr_bw" /></el-select></el-form-item></div>
        <div class="form-section-title">控制网络</div>
        <div class="form-grid"><el-form-item label="当前 IP（兼容字段）"><el-input v-model="form.ip" /></el-form-item><el-form-item label="UDP 端口"><el-input-number v-model="form.port" :min="1" :max="65535" controls-position="right" /></el-form-item><el-form-item label="服务器网卡"><el-select v-model="form.udp_interface"><el-option v-for="item in boards.interfaces" :key="item.name" :label="item.name + '（' + item.message + '）'" :value="item.name" /></el-select></el-form-item><el-form-item label="服务器源 IP"><el-input v-model="form.udp_source_ip" /></el-form-item><el-form-item label="当前 MAC"><el-input v-model="form.mac" /></el-form-item></div>
        <div class="form-grid"><el-form-item label="Bootstrap IP"><el-input v-model="form.bootstrap_ip" /></el-form-item><el-form-item label="目标 IP"><el-input v-model="form.desired_ip" /></el-form-item><el-form-item label="目标 MAC"><el-input v-model="form.desired_mac" /></el-form-item><el-form-item label="设备 UID"><el-input v-model="form.device_uid" /></el-form-item></div>
        <el-alert v-if="network" :title="`硬件当前：${network.current_ip} · ${network.current_mac}`" :description="`目标：${network.desired_ip} · ${network.desired_mac}；物理链路：${network.physical_link ? '已连接' : '未连接'}`" type="info" :closable="false" />
        <el-button v-if="network" type="warning" @click="applyNetwork">应用目标网络身份并重启 PL 网络</el-button>
        <div class="form-section-title">硬件映射</div>
        <div class="form-grid"><el-form-item label="JTAG cable serial"><el-input v-model="form.jtag_cable_serial" /></el-form-item><el-form-item label="ttyUSB 端口"><el-select v-model="form.serial_path" clearable filterable><el-option v-for="port in serialPorts" :key="port.path" :label="port.path" :value="port.path" /></el-select></el-form-item><el-form-item label="波特率"><el-input-number v-model="form.baud_rate" :min="300" :max="4000000" controls-position="right" /></el-form-item><el-form-item label="时钟源"><el-select v-model="form.clock_source"><el-option label="板载时钟" value="onboard" /><el-option label="主板 10 MHz" value="master-10mhz" /></el-select></el-form-item></div>
        <div class="form-section-title">同步预留</div>
        <div class="form-grid"><el-form-item label="角色"><el-select v-model="form.role"><el-option label="独立 / 主板" value="master" /><el-option label="从板（预留）" value="follower" /></el-select></el-form-item><el-form-item label="同步组"><el-input v-model="form.sync_group" /></el-form-item></div>
        <el-form-item label="备注"><el-input v-model="form.notes" type="textarea" :rows="4" /></el-form-item><el-switch v-model="form.enabled" active-text="启用板卡" inactive-text="停用板卡" />
      </el-form>
      <template #footer><el-button @click="drawer = false">取消</el-button><el-button type="primary" @click="save">保存档案</el-button></template>
    </el-drawer>
  </div>
</template>
