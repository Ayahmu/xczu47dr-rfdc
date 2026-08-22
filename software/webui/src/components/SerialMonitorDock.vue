<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { Clipboard, Download, Pause, Play, Trash2, TerminalSquare, X, Type } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { useRoute } from 'vue-router'
import { useBoardsStore } from '../stores/boards'
import { useEventsStore } from '../stores/events'
import { formatTime } from '../utils/format'
import type { BoardProfile } from '../types'

const route = useRoute()
const boards = useBoardsStore()
const events = useEventsStore()
const open = ref(false)
const paused = ref(false)
const fontSize = ref(Number(localStorage.getItem('rfsoc.serial.fontSize') || 15))
const showTimestamp = ref(localStorage.getItem('rfsoc.serial.timestamp') !== 'false')
const dockHeight = ref(Number(localStorage.getItem('rfsoc.serial.height') || 320))
const resizing = ref(false)
const selectedId = ref('')
const terminal = ref<HTMLElement | null>(null)

const enabledBoards = computed(() => boards.boards.filter((board) => board.enabled))
const selected = computed(() => selectedId.value || String(route.params.boardId || '') || enabledBoards.value[0]?.id || '')
const lines = computed(() => events.serial[selected.value] || [])
const totalLines = computed(() => Object.values(events.serial).reduce((sum, value) => sum + value.length, 0))
const hasUnread = computed(() => totalLines.value > 0 && !open.value)

function serialLabel(board: BoardProfile | null) {
  const path = board?.serial_path || ''
  const match = path.match(/ttyUSB\d+/)
  return match?.[0] || path.split('/').pop() || '未绑定串口'
}
function text() { return lines.value.map((item) => `${formatTime(item.created_at)} ${item.line}`).join('\n') }
async function copy() { await navigator.clipboard.writeText(text()); ElMessage.success('已复制当前串口日志') }
function download() {
  const url = URL.createObjectURL(new Blob([text()], { type: 'text/plain;charset=utf-8' }))
  const link = document.createElement('a'); link.href = url; link.download = `${serialLabel(boards.byId(selected.value))}-uart.log`; link.click(); URL.revokeObjectURL(url)
}
function clear() { events.clearSerial(selected.value) }
function setFontSize(value: number) { fontSize.value = Math.max(12, Math.min(22, value)); localStorage.setItem('rfsoc.serial.fontSize', String(fontSize.value)) }
function toggleTimestamp() { showTimestamp.value = !showTimestamp.value; localStorage.setItem('rfsoc.serial.timestamp', String(showTimestamp.value)) }
function startResize(event: PointerEvent) {
  if (!open.value) return
  resizing.value = true
  const startY = event.clientY
  const startHeight = dockHeight.value
  const move = (current: PointerEvent) => {
    dockHeight.value = Math.max(190, Math.min(window.innerHeight - 96, startHeight + (startY - current.clientY)))
  }
  const end = () => {
    resizing.value = false
    localStorage.setItem('rfsoc.serial.height', String(Math.round(dockHeight.value)))
    window.removeEventListener('pointermove', move)
    window.removeEventListener('pointerup', end)
  }
  window.addEventListener('pointermove', move)
  window.addEventListener('pointerup', end)
}
function toggle() { open.value = !open.value; if (open.value) nextTick(scrollToEnd) }
function scrollToEnd() { if (terminal.value && !paused.value) terminal.value.scrollTop = terminal.value.scrollHeight }
watch(lines, () => nextTick(scrollToEnd), { deep: true })
watch(() => route.params.boardId, (id) => { if (id) selectedId.value = String(id) })
</script>

<template>
  <section class="serial-dock" :class="{ open, resizing }" :style="open ? { height: dockHeight + 'px' } : undefined">
    <button v-if="open" class="serial-dock-resize-handle" type="button" title="拖动调整串口窗口高度" aria-label="调整串口窗口高度" @pointerdown.prevent="startResize"><span /></button>
    <header class="serial-dock-bar">
      <button class="serial-dock-title" type="button" @click="toggle"><TerminalSquare :size="18" /><strong>串口监视台</strong><span v-if="selected">{{ serialLabel(boards.byId(selected)) }}</span><i v-if="hasUnread" /></button>
      <div class="serial-dock-actions">
        <span class="serial-dock-count">{{ lines.length }} 行</span>
        <button class="icon-button" title="减小字体" :disabled="fontSize <= 12" @click="setFontSize(fontSize - 1)"><Type :size="14" /><small>-</small></button>
        <button class="icon-button" title="增大字体" :disabled="fontSize >= 22" @click="setFontSize(fontSize + 1)"><Type :size="17" /><small>+</small></button>
        <button class="icon-button" :class="{ selected: showTimestamp }" title="显示/隐藏时间戳" @click="toggleTimestamp">时</button>
        <button class="icon-button" title="清空当前日志" :disabled="!selected || !lines.length" @click="clear"><Trash2 :size="16" /></button>
        <button class="icon-button" title="复制当前日志" :disabled="!lines.length" @click="copy"><Clipboard :size="16" /></button>
        <button class="icon-button" title="下载当前日志" :disabled="!lines.length" @click="download"><Download :size="16" /></button>
        <button class="icon-button" :title="paused ? '继续跟随' : '暂停跟随'" @click="paused = !paused"><Play v-if="paused" :size="16" /><Pause v-else :size="16" /></button>
        <button class="icon-button" title="关闭监视台" @click="open = false"><X :size="17" /></button>
      </div>
    </header>
    <div v-if="open" class="serial-dock-body">
      <nav class="serial-dock-tabs" aria-label="选择串口">
        <button v-for="board in enabledBoards" :key="board.id" type="button" :class="{ active: selected === board.id }" @click="selectedId = board.id"><span>{{ serialLabel(board) }}</span><small>{{ (events.serial[board.id] || []).length }}</small></button>
        <span v-if="!enabledBoards.length" class="serial-dock-empty">暂无已启用板卡</span>
      </nav>
      <div ref="terminal" class="serial-dock-terminal" :style="{ '--serial-font-size': fontSize + 'px' }"><div v-for="(line, index) in lines" :key="line.created_at + index"><time v-if="showTimestamp">{{ formatTime(line.created_at) }}</time><span>{{ line.line }}</span></div><em v-if="!lines.length">等待串口输出...</em></div>
    </div>
  </section>
</template>
