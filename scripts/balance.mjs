#!/usr/bin/env node
/**
 * deepseek-balance —— DeepSeek 余额 / 今日消耗查询（Codex 插件 deepseek-balance）
 *
 * 逻辑移植自 DSH 小鲸鱼余额挂件宿主侧（lib/index.js）：
 *   - 余额：GET https://api.deepseek.com/user/balance，选币规则与挂件一致
 *   - 今日已用：ledger（余额差值本地记账）/ token（平台用量接口 + 峰谷定价）
 *
 * 零第三方依赖，要求 Node >= 18（使用全局 fetch 与 AbortSignal.timeout）。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'

const BALANCE_URL = 'https://api.deepseek.com/user/balance'
const USAGE_URL = 'https://platform.deepseek.com/api/v0/usage/by_api_key/amount'
const BALANCE_TIMEOUT_MS = 20000
const USAGE_TIMEOUT_MS = 15000
const RETRY_DELAY_MS = 500
const HISTORY_KEEP_DAYS = 30
const HOURLY_KEEP_HOURS = 48
const LEDGER_VERSION = 2

/* ------------------------------------------------------------------ *
 * 定价表：DeepSeek CNY 每百万 token 单价 [空闲时段, 高峰时段]
 * 高峰时段：工作日 9:00-12:00 与 14:00-18:00（北京时间）；
 * 2026-08-23 起（北京时间）周末全天按谷价。DeepSeek 调价时改这里。
 * ------------------------------------------------------------------ */
const PEAK_HOURS = [
  [9, 12],
  [14, 18],
]
const BASE_PRICE = { hit: [0.05, 0.1], miss: [1.5, 3.0], out: [4.5, 9.0] }
const PRO_PRICE = { hit: [0.15, 0.3], miss: [4.5, 9.0], out: [13.5, 27.0] }
const PRICING = {
  'deepseek-v4-flash-vision-exp': BASE_PRICE,
  'deepseek-v4-flash': BASE_PRICE,
  'deepseek-v4-pro': PRO_PRICE,
  'deepseek-chat': BASE_PRICE,
  'deepseek-reasoner': BASE_PRICE,
  _default: BASE_PRICE,
}
const WEEKEND_VALLEY_FROM_SEC = Math.floor(Date.UTC(2026, 7, 22, 16, 0, 0) / 1000)

function priceFor(model) {
  const m = String(model || '').toLowerCase()
  for (const key of Object.keys(PRICING)) {
    if (key === '_default') continue
    if (m.indexOf(key) !== -1) return PRICING[key]
  }
  return PRICING._default
}

function isPeakTime(timeSec) {
  if (!Number.isFinite(Number(timeSec))) return false
  const n = Number(timeSec)
  const bj = new Date(n * 1000 + 8 * 3600 * 1000)
  if (n >= WEEKEND_VALLEY_FROM_SEC) {
    const dow = bj.getUTCDay()
    if (dow === 0 || dow === 6) return false
  }
  const hour = bj.getUTCHours()
  for (const [start, end] of PEAK_HOURS) {
    if (hour >= start && hour < end) return true
  }
  return false
}

const PEAK_BOUNDARY_HOURS = [9, 12, 14, 18]

/** 下一次峰谷切换：在 9/12/14/18 点这些边界上试探，状态发生变化的那一刻即为切换点 */
function nextPeakChange(now = new Date()) {
  const nowSec = Math.floor(now.getTime() / 1000)
  const currentPeak = isPeakTime(nowSec)
  for (let dayOffset = 0; dayOffset <= 8; dayOffset++) {
    for (const hour of PEAK_BOUNDARY_HOURS) {
      const candidate = new Date(now.getFullYear(), now.getMonth(), now.getDate() + dayOffset, hour, 0, 0, 0)
      const sec = Math.floor(candidate.getTime() / 1000)
      if (sec <= nowSec + 1) continue
      const after = isPeakTime(sec)
      if (after !== currentPeak) return { at: candidate, isPeak: after }
    }
  }
  return null
}

function peakInfo(now = new Date()) {
  const isPeak = isPeakTime(Math.floor(now.getTime() / 1000))
  const change = nextPeakChange(now)
  return {
    isPeak,
    nextChangeAt: change ? localIso(change.at) : null,
    nextChangeAtSec: change ? Math.floor(change.at.getTime() / 1000) : null,
    nextIsPeak: change ? change.isPeak : null,
  }
}

/* ------------------------------ 小工具 ------------------------------ */

const pad2 = (n) => String(n).padStart(2, '0')

function localStamp(date = new Date()) {
  const tzMin = -date.getTimezoneOffset()
  const sign = tzMin >= 0 ? '+' : '-'
  const abs = Math.abs(tzMin)
  return (
    `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())} ` +
    `${sign}${pad2(Math.floor(abs / 60))}:${pad2(abs % 60)}`
  )
}

function todayKey(date = new Date()) {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`
}

function hourKey(date = new Date()) {
  return `${todayKey(date)}T${pad2(date.getHours())}`
}

function localIso(date) {
  const tzMin = -date.getTimezoneOffset()
  const sign = tzMin >= 0 ? '+' : '-'
  const abs = Math.abs(tzMin)
  return (
    `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}T` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}` +
    `${sign}${pad2(Math.floor(abs / 60))}:${pad2(abs % 60)}`
  )
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function toAmount(value) {
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function money(value) {
  const n = toAmount(value)
  return n === null ? '--' : n.toFixed(2)
}

function codexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), '.codex')
}

/* --------------------------- 凭据解析 --------------------------- */

function parseTomlSections(text) {
  const sections = new Map([['', []]])
  let current = ''
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/#.*$/, '').trim()
    if (!line) continue
    const header = /^\[(.+?)\]$/.exec(line)
    if (header) {
      current = header[1].trim()
      if (!sections.has(current)) sections.set(current, [])
      continue
    }
    sections.get(current).push(line)
  }
  return sections
}

function tomlValue(lines, key) {
  const re = new RegExp('^' + key + '\\s*=\\s*(.+)$')
  for (const line of lines || []) {
    const match = re.exec(line)
    if (!match) continue
    const raw = match[1].trim()
    const quoted = /^"([\s\S]*)"$/.exec(raw) || /^'([\s\S]*)'$/.exec(raw)
    return quoted ? quoted[1] : raw
  }
  return null
}

function deepseekProvidersFromCodexConfig() {
  const file = path.join(codexHome(), 'config.toml')
  let text
  try {
    text = fs.readFileSync(file, 'utf8')
  } catch (err) {
    return []
  }
  const sections = parseTomlSections(text)
  const preferred = tomlValue(sections.get('') || [], 'model_provider')
  const found = []
  for (const [section, lines] of sections) {
    const header = /^model_providers\.(.+)$/.exec(section)
    if (!header) continue
    const provider = header[1]
    const baseUrl = tomlValue(lines, 'base_url') || ''
    if (baseUrl.indexOf('api.deepseek.com') === -1) continue
    const token =
      tomlValue(lines, 'experimental_bearer_token') ||
      tomlValue(lines, 'api_key') ||
      tomlValue(lines, 'bearer_token')
    if (!token) continue
    found.push({ provider, token, file, preferred: provider === preferred })
  }
  found.sort((a, b) => Number(b.preferred) - Number(a.preferred))
  return found
}

function resolveApiKey() {
  const fromEnv = String(process.env.DEEPSEEK_API_KEY || '').trim()
  if (fromEnv) return { key: fromEnv, source: 'env:DEEPSEEK_API_KEY' }
  const providers = deepseekProvidersFromCodexConfig()
  if (providers.length > 0) {
    return {
      key: providers[0].token,
      source: `codex-config:model_providers.${providers[0].provider}`,
      configFile: providers[0].file,
    }
  }
  return null
}

function resolvePlatformToken() {
  const raw = String(process.env.DEEPSEEK_PLATFORM_TOKEN || '').trim()
  if (!raw) return null
  return raw.replace(/^Bearer\s+/i, '')
}

/* --------------------------- 账本（ledger） --------------------------- */

function resolveStateDir(cliValue) {
  const explicit = String(cliValue || '').trim()
  if (explicit) return path.resolve(explicit)
  const fromEnv = String(process.env.DEEPSEEK_BALANCE_STATE_DIR || '').trim()
  if (fromEnv) return path.resolve(fromEnv)
  return path.join(codexHome(), 'deepseek-balance')
}

function readLedger(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (parsed && typeof parsed === 'object') {
      // v1 -> v2：补齐 hourly 分桶，历史日数据保持原样
      parsed.history = parsed.history && typeof parsed.history === 'object' ? parsed.history : {}
      parsed.hourly = parsed.hourly && typeof parsed.hourly === 'object' ? parsed.hourly : {}
      return parsed
    }
  } catch (err) {
    /* 文件不存在或损坏：按空账本处理 */
  }
  return {
    version: LEDGER_VERSION,
    date: todayKey(),
    lastBalance: null,
    lastCurrency: null,
    todayUsage: 0,
    lastSeenAt: null,
    history: {},
    hourly: {},
  }
}

function writeLedger(file, ledger) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, JSON.stringify(ledger, null, 2), 'utf8')
    return { ok: true }
  } catch (err) {
    return { ok: false, error: String((err && err.message) || err) }
  }
}

/**
 * 记账：每次观测到余额后，用余额下降的差值累计当天用量（跨天归零并归档）。
 * 币种感知：观测币种与上次不同时只重置基准、不记差值，避免币种切换被记成消费。
 */
function recordLedgerUsage(ledger, currentBalance, currency, now = new Date()) {
  const key = todayKey(now)
  const cur = String(currency || '')
  const currencyChanged =
    typeof ledger.lastCurrency === 'string' &&
    ledger.lastCurrency !== '' &&
    cur !== '' &&
    ledger.lastCurrency !== cur

  if (ledger.date !== key) {
    if (ledger.date && typeof ledger.todayUsage === 'number') {
      ledger.history = ledger.history || {}
      ledger.history[ledger.date] = ledger.todayUsage
    }
    ledger.date = key
    ledger.lastBalance = currentBalance
    ledger.lastCurrency = cur
    ledger.todayUsage = 0
  } else if (currencyChanged) {
    ledger.lastBalance = currentBalance
    ledger.lastCurrency = cur
  } else {
    const prev = typeof ledger.lastBalance === 'number' ? ledger.lastBalance : currentBalance
    if (typeof prev === 'number' && typeof currentBalance === 'number' && currentBalance < prev) {
      const delta = prev - currentBalance
      ledger.todayUsage = (typeof ledger.todayUsage === 'number' ? ledger.todayUsage : 0) + delta
      // 小时分桶：本次观测到的消耗记到当前小时，供续航预估使用
      ledger.hourly = ledger.hourly && typeof ledger.hourly === 'object' ? ledger.hourly : {}
      const key = hourKey(now)
      const bucket = Number(ledger.hourly[key])
      ledger.hourly[key] = (Number.isFinite(bucket) ? bucket : 0) + delta
    }
    ledger.lastBalance = currentBalance
    ledger.lastCurrency = cur
  }

  ledger.version = LEDGER_VERSION
  ledger.lastSeenAt = now.toISOString()

  const keys = Object.keys(ledger.history || {}).sort()
  while (keys.length > HISTORY_KEEP_DAYS) {
    delete ledger.history[keys.shift()]
  }
  ledger.hourly = ledger.hourly && typeof ledger.hourly === 'object' ? ledger.hourly : {}
  const hourKeys = Object.keys(ledger.hourly).sort()
  while (hourKeys.length > HOURLY_KEEP_HOURS) {
    delete ledger.hourly[hourKeys.shift()]
  }
  return ledger
}

/* --------------------------- 余额接口 --------------------------- */

function pickBalanceInfo(infos) {
  if (!Array.isArray(infos) || infos.length === 0) return { info: null, pickedBy: null }
  const num = (x) => (x && x.total_balance !== undefined ? Number(x.total_balance) : NaN)
  const cnyPositive = infos.find((x) => x && x.currency === 'CNY' && num(x) > 0)
  if (cnyPositive) return { info: cnyPositive, pickedBy: 'cny-positive' }
  const anyPositive = infos.find((x) => num(x) > 0)
  if (anyPositive) return { info: anyPositive, pickedBy: 'any-positive' }
  const cny = infos.find((x) => x && x.currency === 'CNY')
  if (cny) return { info: cny, pickedBy: 'cny' }
  return { info: infos[0], pickedBy: 'first' }
}

function normalizeBalanceInfo(info) {
  return {
    currency: String((info && info.currency) || 'CNY'),
    totalBalance: toAmount(info && info.total_balance),
    grantedBalance: toAmount(info && info.granted_balance),
    toppedUpBalance: toAmount(info && info.topped_up_balance),
  }
}

async function fetchBalance(apiKey) {
  let lastError = null
  for (let attempt = 0; attempt < 2; attempt++) {
    let response
    try {
      response = await fetch(BALANCE_URL, {
        headers: { Authorization: 'Bearer ' + apiKey, Accept: 'application/json' },
        signal: AbortSignal.timeout(BALANCE_TIMEOUT_MS),
      })
    } catch (err) {
      lastError = err
      if (attempt === 0) await sleep(RETRY_DELAY_MS)
      continue
    }
    if (!response.ok) {
      lastError = new Error('HTTP ' + response.status)
      lastError.status = response.status
      if (response.status < 500) break
      if (attempt === 0) await sleep(RETRY_DELAY_MS)
      continue
    }
    let data
    try {
      data = await response.json()
    } catch (err) {
      return { ok: false, code: 'parse', error: '余额接口返回不是合法 JSON' }
    }
    const { info, pickedBy } = pickBalanceInfo(data && data.balance_infos)
    if (!info || info.total_balance === undefined) {
      return { ok: false, code: 'shape', error: '余额接口返回结构异常（缺少 balance_infos[].total_balance）' }
    }
    const picked = normalizeBalanceInfo(info)
    return {
      ok: true,
      isAvailable: data.is_available !== false,
      balance: { ...picked, pickedBy },
      balanceInfos: (data.balance_infos || []).map(normalizeBalanceInfo),
    }
  }
  const status = lastError && lastError.status
  if (status && status >= 400 && status < 500) {
    return { ok: false, code: 'http_4xx', error: `余额接口返回 HTTP ${status}（密钥无效或无权限）` }
  }
  return {
    ok: false,
    code: status ? 'http_5xx' : 'network',
    error: '余额接口请求失败: ' + String((lastError && lastError.message) || lastError).slice(0, 200),
  }
}

/* --------------------------- 平台用量接口 --------------------------- */

function computeUsageFromSeries(data) {
  let payload = data
  if (payload && payload.data && payload.data.biz_data && Array.isArray(payload.data.biz_data.series)) {
    payload = payload.data.biz_data
  } else if (payload && payload.data && Array.isArray(payload.data.series)) {
    payload = payload.data
  }
  const series = payload && Array.isArray(payload.series) ? payload.series : null
  if (!series || series.length === 0) return null

  let cost = 0
  let tokens = 0
  let found = false
  for (const entry of series) {
    if (!entry || typeof entry !== 'object') continue
    const price = priceFor(entry.model)
    const buckets = Array.isArray(entry.buckets) ? entry.buckets : []
    for (const bucket of buckets) {
      const usage = bucket && bucket.usage
      if (!usage || typeof usage !== 'object') continue
      const hit = Number(usage.PROMPT_CACHE_HIT_TOKEN) || 0
      const miss = Number(usage.PROMPT_CACHE_MISS_TOKEN) || 0
      const out = Number(usage.RESPONSE_TOKEN) || 0
      if (hit + miss + out === 0) continue
      found = true
      tokens += hit + miss + out
      const peakIndex = isPeakTime(bucket.time) ? 1 : 0
      cost +=
        (hit / 1e6) * price.hit[peakIndex] +
        (miss / 1e6) * price.miss[peakIndex] +
        (out / 1e6) * price.out[peakIndex]
    }
  }
  return found ? { amount: cost, tokens } : null
}

async function fetchPlatformUsage(token, now = new Date()) {
  const tz = -now.getTimezoneOffset() * 60
  const start = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000)
  const end = start + 86400
  const url = `${USAGE_URL}?start=${start}&end=${end}&tz=${tz}`
  try {
    const response = await fetch(url, {
      headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' },
      signal: AbortSignal.timeout(USAGE_TIMEOUT_MS),
    })
    if (!response.ok) return { ok: false, code: 'http_4xx', error: `平台用量接口返回 HTTP ${response.status}` }
    const data = await response.json()
    const usage = computeUsageFromSeries(data)
    if (!usage || !Number.isFinite(usage.amount)) {
      return { ok: false, code: 'no_usage', error: '平台用量接口未返回可换算的用量分桶' }
    }
    return { ok: true, amount: usage.amount, tokens: usage.tokens }
  } catch (err) {
    return { ok: false, code: 'network', error: '平台用量接口请求失败: ' + String((err && err.message) || err).slice(0, 200) }
  }
}

/* --------------------------- 命令实现 --------------------------- */

function todayUsageFromLedger(ledger, now = new Date()) {
  const key = todayKey(now)
  if (ledger && ledger.date === key && Number.isFinite(Number(ledger.todayUsage))) {
    return Number(ledger.todayUsage)
  }
  return 0
}

/**
 * 续航预估：优先用最近的小时分桶算平均速率（样本 ≥2 小时），
 * 样本不足时退回「今日已用 ÷ 今日已过小时」。
 * ratePerHour 为 null 表示暂时无法估算。
 */
function computeRuntime(ledger, balance, now = new Date()) {
  const hourly = ledger && ledger.hourly && typeof ledger.hourly === 'object' ? ledger.hourly : {}
  const currentHour = hourKey(now)
  const cutoffHour = hourKey(new Date(now.getTime() - 24 * 3600 * 1000))
  const recent = Object.keys(hourly)
    .filter((key) => key < currentHour && key >= cutoffHour)
    .sort()

  let basis = null
  let ratePerHour = null
  let sampleHours = 0

  if (recent.length >= 2) {
    let sum = 0
    for (const key of recent) {
      const value = Number(hourly[key])
      if (Number.isFinite(value) && value > 0) sum += value
    }
    // 按时间跨度平均：没有落键的小时按"零消耗"计，避免只在有消耗的小时上求平均而高估速率
    const parts = recent[0].split(/[-T]/).map(Number)
    const firstAt = new Date(parts[0], parts[1] - 1, parts[2], parts[3], 0, 0, 0)
    const spanHours = Math.min(24, Math.max(2, (now.getTime() - firstAt.getTime()) / 3600000))
    ratePerHour = sum / spanHours
    sampleHours = Math.round(spanHours * 10) / 10
    basis = 'hourly'
  } else {
    const hoursToday = now.getHours() + now.getMinutes() / 60 + now.getSeconds() / 3600
    const todayUsage = todayUsageFromLedger(ledger, now)
    if (hoursToday >= 0.5 && Number.isFinite(todayUsage) && todayUsage > 0) {
      ratePerHour = todayUsage / hoursToday
      sampleHours = Math.round(hoursToday * 10) / 10
      basis = 'today'
    }
  }

  const total = Number(balance)
  let estimatedHours = null
  if (basis && Number.isFinite(total) && total > 0 && ratePerHour > 0) {
    estimatedHours = Math.round((total / ratePerHour) * 10) / 10
  }
  return {
    basis,
    ratePerHour: Number.isFinite(ratePerHour) ? Math.round(ratePerHour * 10000) / 10000 : null,
    sampleHours,
    estimatedHours,
  }
}

async function computeTodayUsage({ mode, ledger, ledgerFilePath, ledgerWritable, warnings }) {
  const effectiveMode = mode === 'token' ? 'token' : 'ledger'
  if (effectiveMode === 'ledger') {
    return {
      mode: 'ledger',
      amount: todayUsageFromLedger(ledger),
      tokens: null,
      date: todayKey(),
      fallback: false,
      ledgerWritable,
    }
  }

  const token = resolvePlatformToken()
  if (!token) {
    warnings.push('未配置 DEEPSEEK_PLATFORM_TOKEN，已回落小鲸鱼记账模式')
    return {
      mode: 'ledger',
      amount: todayUsageFromLedger(ledger),
      tokens: null,
      date: todayKey(),
      fallback: true,
      ledgerWritable,
    }
  }

  const usage = await fetchPlatformUsage(token)
  if (!usage.ok) {
    warnings.push(`平台用量接口不可用（${usage.code}：${usage.error}），已回落小鲸鱼记账模式`)
    return {
      mode: 'ledger',
      amount: todayUsageFromLedger(ledger),
      tokens: null,
      date: todayKey(),
      fallback: true,
      ledgerWritable,
    }
  }
  return {
    mode: 'token',
    amount: usage.amount,
    tokens: usage.tokens,
    date: todayKey(),
    fallback: false,
    ledgerWritable,
  }
}

function baseResult(stateFile) {
  const now = new Date()
  return {
    ok: true,
    code: 'ok',
    updatedAt: now.toISOString(),
    updatedAtLocal: localStamp(now),
    isPeak: isPeakTime(Math.floor(now.getTime() / 1000)),
    peak: peakInfo(now),
    stateFile,
    warnings: [],
  }
}

async function commandBalance(options) {
  const result = baseResult(options.stateFile)
  const warnings = result.warnings

  const credential = resolveApiKey()
  if (!credential) {
    return {
      ok: false,
      code: 'no_api_key',
      error:
        '未找到 DeepSeek API key：请设置环境变量 DEEPSEEK_API_KEY，或在 ~/.codex/config.toml 的 [model_providers.*] 中配置 api.deepseek.com 与 token。',
    }
  }
  result.credentialSource = credential.source

  const fetched = await fetchBalance(credential.key)
  if (!fetched.ok) return fetched

  const ledger = readLedger(options.ledgerFile)
  recordLedgerUsage(ledger, fetched.balance.totalBalance, fetched.balance.currency)
  const written = writeLedger(options.ledgerFile, ledger)
  if (!written.ok) {
    warnings.push(
      `账本写入失败（${written.error}）：今日已用可能不准确；可用 DEEPSEEK_BALANCE_STATE_DIR 或 --state-dir 指定可写目录`,
    )
  }

  result.balance = {
    totalBalance: fetched.balance.totalBalance,
    currency: fetched.balance.currency,
    isAvailable: fetched.isAvailable,
    grantedBalance: fetched.balance.grantedBalance,
    toppedUpBalance: fetched.balance.toppedUpBalance,
    pickedBy: fetched.balance.pickedBy,
  }
  result.balanceInfos = fetched.balanceInfos
  result.todayUsage = await computeTodayUsage({
    mode: options.mode,
    ledger,
    ledgerFilePath: options.ledgerFile,
    ledgerWritable: written.ok,
    warnings,
  })
  result.runtime = computeRuntime(ledger, fetched.balance.totalBalance)
  return result
}

async function commandToday(options) {
  const result = baseResult(options.stateFile)
  const warnings = result.warnings
  const ledger = readLedger(options.ledgerFile)
  result.todayUsage = await computeTodayUsage({
    mode: options.mode,
    ledger,
    ledgerFilePath: options.ledgerFile,
    ledgerWritable: null,
    warnings,
  })
  result.todayUsage.observation = ledger.lastSeenAt || null
  result.runtime = computeRuntime(
    ledger,
    ledger && Number.isFinite(Number(ledger.lastBalance)) ? Number(ledger.lastBalance) : null,
  )
  return result
}

/* --------------------------- 输出与入口 --------------------------- */

function formatRuntime(runtime) {
  if (!runtime || !runtime.ratePerHour) return '样本不足，暂不估算'
  const label = runtime.basis === 'hourly' ? `最近 ${runtime.sampleHours} 小时` : '今日均值'
  const hours = runtime.estimatedHours
  let remain = '未知'
  if (Number.isFinite(hours)) {
    if (hours >= 24 * 365) remain = '一年以上'
    else if (hours >= 48) remain = `约 ${Math.floor(hours / 24)} 天`
    else remain = `约 ${Math.max(1, Math.round(hours))} 小时`
  }
  return `${remain}（按${label} ¥${money(runtime.ratePerHour)}/小时）`
}

function printHuman(result, command) {
  const warnings = result.warnings || []
  if (!result.ok) {
    console.error(`查询失败（${result.code}）：${result.error}`)
    return
  }
  if (command === 'balance') {
    const balance = result.balance || {}
    console.log(
      `DeepSeek 余额：¥${money(balance.totalBalance)} ${balance.currency}` +
        (balance.isAvailable === false ? '（账户不可用）' : ''),
    )
    const usage = result.todayUsage || {}
    console.log(
      `今日已用：¥${money(usage.amount)}（${usage.mode === 'token' ? '令牌模式' : '小鲸鱼记账'}` +
        (usage.fallback ? '，已回落' : '') +
        `｜截至 ${result.updatedAtLocal}）`,
    )
    if (result.peak) {
      const next = result.peak.nextChangeAt
        ? `，下一次切换 ${result.peak.nextChangeAt}（转为${result.peak.nextIsPeak ? '高峰' : '谷价'}）`
        : ''
      console.log(`峰谷：${result.peak.isPeak ? '高峰时段' : '谷价时段'}${next}`)
    }
    if (result.runtime) console.log(`续航预估：${formatRuntime(result.runtime)}`)
    if (result.balanceInfos && result.balanceInfos.length > 1) {
      const detail = result.balanceInfos
        .map((info) => `${info.currency} 总额 ${money(info.totalBalance)}/充值 ${money(info.toppedUpBalance)}/赠送 ${money(info.grantedBalance)}`)
        .join('；')
      console.log(`币种明细：${detail}`)
    }
  } else {
    const usage = result.todayUsage || {}
    const tokens = usage.tokens === null || usage.tokens === undefined ? '' : `｜tokens ${usage.tokens}`
    console.log(
      `今日已用：¥${money(usage.amount)}（${usage.mode === 'token' ? '令牌模式' : '小鲸鱼记账'}` +
        (usage.fallback ? '，已回落' : '') +
        `${tokens}）`,
    )
    if (usage.observation) console.log(`最近余额观测：${usage.observation}`)
  }
  for (const warning of warnings) console.error(`[warn] ${warning}`)
}

function parseArgs(argv) {
  const options = {
    command: 'balance',
    json: false,
    mode: String(process.env.DEEPSEEK_BALANCE_MODE || 'ledger').toLowerCase(),
    stateDir: null,
    help: false,
  }
  const rest = []
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--json') options.json = true
    else if (arg === '--help' || arg === '-h') options.help = true
    else if (arg === '--mode') options.mode = String(argv[++i] || '').toLowerCase()
    else if (arg.startsWith('--mode=')) options.mode = arg.slice('--mode='.length).toLowerCase()
    else if (arg === '--state-dir') options.stateDir = argv[++i] || null
    else if (arg.startsWith('--state-dir=')) options.stateDir = arg.slice('--state-dir='.length)
    else rest.push(arg)
  }
  if (rest.length > 0) options.command = rest[0]
  return options
}

const HELP = `deepseek-balance —— 查询 DeepSeek 余额与今日消耗

用法：
  node balance.mjs balance [--json] [--mode ledger|token] [--state-dir <目录>]
  node balance.mjs today   [--json] [--mode ledger|token] [--state-dir <目录>]

子命令：
  balance   余额 + 今日已用（同时把本次余额观测记入账本），默认子命令
  today     只输出今日已用

参数：
  --json              输出机器可读 JSON
  --mode <模式>       ledger（默认，免令牌）或 token（需 DEEPSEEK_PLATFORM_TOKEN）
  --state-dir <目录>  覆盖账本目录（等价于环境变量 DEEPSEEK_BALANCE_STATE_DIR）
  -h, --help          显示本帮助

环境变量：
  DEEPSEEK_API_KEY             余额接口密钥；缺省时回落到 ~/.codex/config.toml
  DEEPSEEK_PLATFORM_TOKEN      令牌模式所需（平台网页会话令牌）
  DEEPSEEK_BALANCE_MODE        默认用量模式
  DEEPSEEK_BALANCE_STATE_DIR   账本目录
  CODEX_HOME                   读取 config.toml 的目录，默认 ~/.codex

JSON 输出（--json）：
  在余额/今日已用之外，另含：
    peak.isPeak / peak.nextChangeAt / peak.nextChangeAtSec / peak.nextIsPeak
        当前是否高峰，以及下一次峰谷切换的本地时间与切换后的状态
    runtime.basis / runtime.ratePerHour / runtime.sampleHours / runtime.estimatedHours
        续航预估：basis 为 hourly（最近小时分桶，样本 ≥2 小时）或 today（今日均值），
        ratePerHour 为 null 表示样本不足暂时无法估算
 `

async function main() {
  const options = parseArgs(process.argv.slice(2))
  if (options.help) {
    process.stdout.write(HELP)
    return 0
  }
  if (options.command !== 'balance' && options.command !== 'today') {
    console.error(`未知子命令：${options.command}\n`)
    process.stderr.write(HELP)
    return 2
  }

  const stateDir = resolveStateDir(options.stateDir)
  options.stateFile = path.join(stateDir, 'usage.json')
  options.ledgerFile = options.stateFile

  const result =
    options.command === 'balance' ? await commandBalance(options) : await commandToday(options)

  if (options.json) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n')
  } else {
    printHuman(result, options.command)
  }
  return result.ok ? 0 : 1
}

main()
  .then((code) => {
    process.exitCode = code
  })
  .catch((err) => {
    const message = String((err && err.stack) || err)
    if (process.argv.includes('--json')) {
      process.stdout.write(JSON.stringify({ ok: false, code: 'internal', error: message }, null, 2) + '\n')
    } else {
      console.error('内部错误：' + message)
    }
    process.exitCode = 1
  })
