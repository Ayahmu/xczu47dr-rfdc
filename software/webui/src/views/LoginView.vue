<script setup lang="ts">
import { reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { RadioTower } from 'lucide-vue-next'
import { ElMessage } from 'element-plus/es/components/message/index'
import { useSessionStore } from '../stores/session'
import { errorMessage } from '../api/client'

const form = reactive({ username: 'admin', password: '' })
const busy = ref(false)
const session = useSessionStore()
const route = useRoute()
const router = useRouter()
async function submit() {
  busy.value = true
  try {
    await session.login(form.username, form.password)
    await router.replace(String(route.query.redirect || '/boards'))
  } catch (error) { ElMessage.error('登录失败：' + errorMessage(error)) }
  finally { busy.value = false }
}
</script>
<template>
  <div class="login-page">
    <form class="login-card" @submit.prevent="submit">
      <div class="login-product"><div class="brand-symbol"><RadioTower :size="24" /></div><div><h1>XCZU47DR RFDC</h1><p>实验室板卡控制台</p></div></div>
      <div class="login-title"><h2>登录控制台</h2><p>使用实验室账号访问板卡与运行记录</p></div>
      <el-form label-position="top">
        <el-form-item label="用户名"><el-input v-model="form.username" size="large" autocomplete="username" /></el-form-item>
        <el-form-item label="密码"><el-input v-model="form.password" size="large" type="password" show-password autocomplete="current-password" @keyup.enter="submit" /></el-form-item>
      </el-form>
      <el-button native-type="submit" type="primary" size="large" :loading="busy">登录</el-button>
    </form>
  </div>
</template>
