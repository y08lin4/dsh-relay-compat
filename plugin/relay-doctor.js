/**
 * dsh-relay-compat / relay-doctor
 *
 * 挂载时体检：检查 pi-ai 补丁与 settings 开关，缺什么提前在控制台告警，
 * 而不是等到运行时收到中转的谜之 400（developer role）才暴露。
 *
 * 零依赖（不 import 任何 npm 包）。安装：把本文件作为本地插件行加进
 * 任意 agent 预设（或主机组合）：
 *
 *   - id: relay-doctor
 *     name: ./plugins/relay-doctor.js   # 按实际路径调整
 *
 * 检查项：
 *   1. dsh-llm-pi-ai/lib/index.js 里 supportsDeveloperRole 出现 ≥5 次（补丁在位）；
 *   2. ~/.dsh/settings.yaml 含 supportsDeveloperRole 开关（补丁 + 开关缺一不可）。
 * 检查结果只打日志，不做任何修改。
 */

const fs = process.getBuiltinModule('node:fs')
const os = process.getBuiltinModule('node:os')
const path = process.getBuiltinModule('node:path')

export const name = 'relay-doctor'

const MARKER = 'supportsDeveloperRole'
const REQUIRED_MARKERS = 5

/** 定位所有 dsh-llm-pi-ai 安装：npx 缓存 + 当前目录树。 */
function findIndexFiles() {
  const found = []
  const npxRoot = path.join(os.homedir(), 'AppData', 'Local', 'npm-cache', '_npx')
  try {
    for (const dir of fs.readdirSync(npxRoot)) {
      const f = path.join(npxRoot, dir, 'node_modules', '@deepseek-ai', 'dsh-llm-pi-ai', 'lib', 'index.js')
      if (fs.existsSync(f)) found.push(f)
    }
  } catch {
    /* npx 缓存不存在时忽略 */
  }
  try {
    walk(path.resolve('.'), 7, found)
  } catch {
    /* 目录不可读时忽略 */
  }
  return [...new Set(found)]
}

function walk(dir, depth, acc) {
  if (depth < 0) return
  let entries
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const e of entries) {
    if (e.name === 'node_modules' && e.isDirectory()) continue // 只在下层精确命中，避免全量爬依赖树
    const full = path.join(dir, e.name)
    if (e.isDirectory()) {
      if (e.name === '@deepseek-ai' && depth >= 2) {
        const f = path.join(full, 'dsh-llm-pi-ai', 'lib', 'index.js')
        if (fs.existsSync(f)) acc.push(f)
        continue
      }
      walk(full, depth - 1, acc)
    }
  }
}

function markerCount(file) {
  try {
    const text = fs.readFileSync(file, 'utf8')
    return (text.match(/supportsDeveloperRole/g) || []).length
  } catch {
    return 0
  }
}

function settingsHasFlag() {
  const settings = path.join(os.homedir(), '.dsh', 'settings.yaml')
  try {
    return fs.readFileSync(settings, 'utf8').includes(MARKER)
  } catch {
    return false
  }
}

export function apply(ctx) {
  const files = findIndexFiles()
  const patched = files.filter((f) => markerCount(f) >= REQUIRED_MARKERS)
  const flagOn = settingsHasFlag()

  if (files.length === 0) {
    console.warn('[dsh-relay-compat] ⚠ 本机未发现 dsh-llm-pi-ai 安装；若你在用中转（pi-ai 路由），请先运行 scripts/apply.ps1 打补丁。')
  }
  else if (patched.length === 0) {
    console.warn(`[dsh-relay-compat] ⚠ 发现 ${files.length} 个 dsh-llm-pi-ai 安装但都未打补丁 —— 中转会把 system 发成 developer，报 400。请运行 scripts/apply.ps1 后重启 DSH。`)
  }
  else {
    console.log(`[dsh-relay-compat] ✔ pi-ai 补丁已生效（${patched.length}/${files.length} 个安装）。`)
  }

  if (!flagOn) {
    console.warn('[dsh-relay-compat] ⚠ settings.yaml 未发现 supportsDeveloperRole 开关 —— 即使补丁生效，role 仍会是 developer。请给对应 model 的 compat 加 supportsDeveloperRole: false（见 settings/lyai-snippet.yaml）。')
  }
  else {
    console.log('[dsh-relay-compat] ✔ settings.yaml 含 supportsDeveloperRole 开关。')
  }
}
