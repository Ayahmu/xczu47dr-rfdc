import { createRouter, createWebHistory } from 'vue-router'
import { useSessionStore } from './stores/session'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('./views/LoginView.vue'), meta: { public: true, title: '登录' } },
    { path: '/', component: () => import('./layouts/ConsoleLayout.vue'), children: [
      { path: '', redirect: '/boards' },
      { path: 'boards', name: 'boards', component: () => import('./views/BoardsView.vue'), meta: { title: '板卡列表' } },
      { path: 'sync', name: 'sync', component: () => import('./views/SyncControlView.vue'), meta: { title: '双板同步' } },
      { path: 'boards/:boardId/output', name: 'board-output', component: () => import('./views/BoardOutputView.vue'), meta: { title: '输出控制' } },
      { path: 'boards/:boardId/sweep', name: 'board-sweep', component: () => import('./views/BoardSweepView.vue'), meta: { title: '参数扫描' } },
      { path: 'boards/:boardId/max-length', name: 'board-max-length', component: () => import('./views/BoardMaxLengthView.vue'), meta: { title: '极限长度' } },
      { path: 'boards/:boardId/diagnostics', name: 'board-diagnostics', component: () => import('./views/BoardDiagnosticsView.vue'), meta: { title: '诊断与串口' } },
      { path: 'records/runs', name: 'run-records', component: () => import('./views/RunRecordsView.vue'), meta: { title: '发波任务' } },
      { path: 'records/tests', name: 'test-records', component: () => import('./views/TestRecordsView.vue'), meta: { title: '性能测试' } },
      { path: 'admin/boards', name: 'admin-boards', component: () => import('./views/AdminBoardsView.vue'), meta: { title: '板卡与资源', admin: true } },
      { path: 'admin/deployments', name: 'admin-deployments', component: () => import('./views/AdminDeploymentsView.vue'), meta: { title: 'JTAG 部署', admin: true } },
      { path: 'admin/users', name: 'admin-users', component: () => import('./views/AdminUsersView.vue'), meta: { title: '用户管理', admin: true } },
      { path: 'admin/audit', name: 'admin-audit', component: () => import('./views/AdminAuditView.vue'), meta: { title: '审计记录', admin: true } },
    ] },
    { path: '/:pathMatch(.*)*', redirect: '/boards' },
  ],
})

router.beforeEach(async (to) => {
  const session = useSessionStore()
  await session.restore()
  if (to.meta.public) return session.user ? '/boards' : true
  if (!session.user) return { path: '/login', query: { redirect: to.fullPath } }
  if (to.meta.admin && !session.isAdmin) return '/boards'
  return true
})

export default router
