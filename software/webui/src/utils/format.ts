import type { BoardState, RunState } from '../types'

export const channelColors = ['#1f6feb', '#d94841', '#168a62', '#b26a00', '#7656c9', '#007f87', '#bd3b70', '#526276']

export function stateLabel(state?: BoardState | RunState | string) {
  const labels: Record<string, string> = {
    OFFLINE: '控制链路未响应', IDLE: '空闲', READY: '准备就绪', ARMED: '已布防', RUNNING: '正在输出',
    DONE: '已完成', FAULT: '故障', MUTED: '已静音', QUEUED: '等待中', GENERATING: '生成中',
    UPLOADING: '上传中', ABORTED: '已终止', DRAFT: '草稿', PAUSED: '已暂停', COMPLETED: '已完成', FAILED: '失败',
  }
  return labels[state || ''] || state || '未知'
}

export function stateType(state?: string): 'success' | 'warning' | 'danger' | 'info' | 'primary' {
  if (['DONE', 'COMPLETED', 'IDLE', 'MUTED'].includes(state || '')) return 'success'
  if (['FAULT', 'FAILED', 'OFFLINE', 'ABORTED'].includes(state || '')) return 'danger'
  if (['ARMED', 'READY', 'PAUSED'].includes(state || '')) return 'warning'
  if (['RUNNING', 'UPLOADING', 'GENERATING'].includes(state || '')) return 'primary'
  return 'info'
}

export function formatTime(value?: string | null) {
  return value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '-'
}

export function maskHex(mask: number) {
  return '0x' + mask.toString(16).toUpperCase().padStart(2, '0')
}
