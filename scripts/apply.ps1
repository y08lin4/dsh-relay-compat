# dsh-relay-compat / apply.ps1
# 一键把 supportsDeveloperRole 补丁打进 dsh-llm-pi-ai：
#   定位（npx 缓存 / 项目 node_modules）→ 打补丁 → 校验 → 检查设置 → 提示重启。
# 幂等：已打过的安装会跳过；可重复安全运行。
#
# 用法：  powershell -File apply.ps1 [ -Target <index.js 完整路径> ]

param(
    [string]$Target = ''
)

$ErrorActionPreference = 'Stop'
$Patch = Join-Path $PSScriptRoot '..\patch\dsh-llm-pi-ai-supportsDeveloperRole.patch'
$Marker = 'supportsDeveloperRole'
$RequiredMarkers = 5   # 补丁在文件里留下 5 处 supportsDeveloperRole

function Find-IndexFiles {
    $found = @()

    # 1) npx 缓存安装（npx @deepseek-ai/dsh 的典型位置）
    $npxRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if (Test-Path $npxRoot) {
        $found += Get-ChildItem $npxRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh-llm-pi-ai\lib\index.js'
        } | Where-Object { Test-Path $_ }
    }

    # 2) 当前目录树里的项目安装
    $found += Get-ChildItem -Path (Get-Location) -Recurse -Depth 7 -Filter 'index.js' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*\node_modules\@deepseek-ai\dsh-llm-pi-ai\lib\index.js' }

    return @($found | Select-Object -Unique)
}

function Get-MarkerCount([string]$File) {
    return ([regex]::Matches((Get-Content -Raw $File), $Marker)).Count
}

# ── 定位 ────────────────────────────────────────────────────────────────
$files = if ($Target) { @($Target) } else { @(Find-IndexFiles) }
if ($files.Count -eq 0) {
    Write-Host '[apply] 未找到 dsh-llm-pi-ai 的 lib/index.js。' -ForegroundColor Red
    Write-Host '       若你的安装位置特殊，用 -Target 指定完整路径重跑。' -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $Patch)) {
    Write-Host "[apply] 找不到补丁文件: $Patch" -ForegroundColor Red
    exit 1
}

# ── 逐个安装打补丁 ──────────────────────────────────────────────────────
foreach ($f in $files) {
    $count = Get-MarkerCount $f
    if ($count -ge $RequiredMarkers) {
        Write-Host "[apply] 已打过补丁，跳过: $f" -ForegroundColor Green
        continue
    }
    $pkgRoot = Split-Path (Split-Path $f)
    Write-Host "[apply] 打补丁: $f" -ForegroundColor Cyan
    Push-Location $pkgRoot
    try {
        git -c core.autocrlf=false apply -p1 $Patch
        if ($LASTEXITCODE -ne 0) { throw "git apply 失败（退出码 $LASTEXITCODE）" }
    }
    finally {
        Pop-Location
    }
    $count = Get-MarkerCount $f
    if ($count -lt $RequiredMarkers) {
        Write-Host "[apply] 校验失败: $f 只有 $count 处标记（预期 $RequiredMarkers）" -ForegroundColor Red
        exit 1
    }
    Write-Host "[apply] 补丁生效，校验通过: $f" -ForegroundColor Green
}

# ── 检查 settings 开关（补丁 + 开关缺一不可） ──────────────────────────
$settings = Join-Path $HOME '.dsh\settings.yaml'
if (Test-Path $settings) {
    if ((Get-Content -Raw $settings) -notmatch $Marker) {
        Write-Host '' -ForegroundColor Yellow
        Write-Host '[apply] ⚠ 注意：settings.yaml 里没有 supportsDeveloperRole 开关。' -ForegroundColor Yellow
        Write-Host '        补丁让开关「可被读取」，但开关本身必须显式写 false 才会把 role 变成 system。' -ForegroundColor Yellow
        Write-Host '        请把 settings/lyai-snippet.yaml 的内容合并进 ~/.dsh/settings.yaml（compat 段）。' -ForegroundColor Yellow
    }
    else {
        Write-Host '[apply] settings.yaml 含 supportsDeveloperRole 开关。' -ForegroundColor Green
    }
}
else {
    Write-Host '[apply] 未找到 ~/.dsh/settings.yaml（尚未初始化？）。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '[apply] 完成。重启 DSH 后生效。' -ForegroundColor Green
