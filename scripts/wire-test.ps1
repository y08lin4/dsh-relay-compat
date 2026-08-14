# wire-test.ps1 — 中转 wire 层全量测试
# 把 DSH 要用的中转按「档位 / 体积 / 角色 / 并发」逐项打一遍，
# 一次复验所有已知坑（developer 400、off 被拒、413、限流）。
#
# 用法（key 从环境变量读，不落盘）：
#   $env:LYAI_API_KEY = '<key>'
#   pwsh -File wire-test.ps1 -Base https://your-relay.example.com/v1 -KeyEnv LYAI_API_KEY
#
# 参数：-Models 模型列表；-Concurrency 并发路数；-SizeKb 体积扫描点。

param(
    [string]$Base = 'https://your-relay.example.com/v1',
    [string]$KeyEnv = 'LYAI_API_KEY',
    [string[]]$Models = @('deepseek-v4-flash', 'deepseek-v4-pro'),
    [int]$Concurrency = 20,
    [int[]]$SizeKb = @(512, 900, 1000, 1024, 1050)
)

$ErrorActionPreference = 'Continue'
$key = [Environment]::GetEnvironmentVariable($KeyEnv)
if (-not $key) { Write-Host "[wire-test] 环境变量 $KeyEnv 未设置" -ForegroundColor Red; exit 1 }
$h = @{ Authorization = "Bearer $key" }

function Probe($model, $effort) {
  $obj = @{ model = $model; messages = @(@{ role = "user"; content = "1+1=?" }); max_tokens = 16 }
  if ($null -ne $effort) { $obj.reasoning_effort = $effort }
  $body = $obj | ConvertTo-Json -Depth 6 -Compress
  try {
    $r = Invoke-WebRequest -Uri "$Base/chat/completions" -Method POST -Headers $h -ContentType "application/json" -Body $body -TimeoutSec 60 -SkipHttpErrorCheck
    $code = [int]$r.StatusCode
    $hasR = ''; $extra = ''
    if ($code -eq 200) {
      $j = $r.Content | ConvertFrom-Json
      $hasR = if ($null -ne $j.choices[0].message.reasoning_content) { 'think=YES' } else { 'think=no' }
      $extra = "out=$($j.usage.completion_tokens)"
    } else {
      $sn = $r.Content; if ($sn.Length -gt 110) { $sn = $sn.Substring(0,110) }
      $extra = $sn -replace '\s+',' '
    }
    "{0,-18} {1,-9} {2,-4} {3,-9} {4}" -f $model, ($(if ($null -eq $effort) {'(default)'} else {$effort})), $code, $hasR, $extra
  } catch {
    "{0,-18} {1,-9} EXC {2}" -f $model, ($(if ($null -eq $effort) {'(default)'} else {$effort})), $_.Exception.Message
  }
}

Write-Output "=== 1) effort matrix ($($Models.Count) models x 9) ==="
foreach ($m in $Models) {
  Probe $m $null
  foreach ($e in @("none","minimal","low","medium","high","xhigh","max","off")) { Probe $m $e }
}

Write-Output ""
Write-Output "=== 2) body size sweep ==="
foreach ($kb in $SizeKb) {
  $pad = 'x' * (($kb * 1024) - 100)
  $obj = @{ model = $Models[0]; messages = @(@{ role = "user"; content = $pad }); max_tokens = 8 } | ConvertTo-Json -Depth 6 -Compress
  try {
    $r = Invoke-WebRequest -Uri "$Base/chat/completions" -Method POST -Headers $h -ContentType "application/json" -Body $obj -TimeoutSec 60 -SkipHttpErrorCheck
    "size={0}KB -> {1}" -f $kb, [int]$r.StatusCode
  } catch {
    "size={0}KB -> EXC {1}" -f $kb, $_.Exception.Message
  }
}

Write-Output ""
Write-Output "=== 3) developer role probe ==="
$obj = @{ model = $Models[0]; messages = @(@{ role = "developer"; content = "you are helpful" }, @{ role = "user"; content = "hi" }); max_tokens = 8 } | ConvertTo-Json -Depth 6 -Compress
try {
  $r = Invoke-WebRequest -Uri "$Base/chat/completions" -Method POST -Headers $h -ContentType "application/json" -Body $obj -TimeoutSec 60 -SkipHttpErrorCheck
  $sn = $r.Content; if ($sn.Length -gt 100) { $sn = $sn.Substring(0,100) }
  "developer role -> {0} {1}" -f [int]$r.StatusCode, ($sn -replace '\s+',' ')
} catch { "developer role -> EXC $($_.Exception.Message)" }

Write-Output ""
Write-Output "=== 4) concurrency probe ($Concurrency ways, model $($Models[0])) ==="
$results = 1..$Concurrency | ForEach-Object -Parallel {
  $body = @{ model = $using:Models[0]; messages = @(@{ role = "user"; content = "1+1=?" }); max_tokens = 16 } | ConvertTo-Json -Depth 5 -Compress
  try {
    $r = Invoke-WebRequest -Uri "$using:Base/chat/completions" -Method POST -Headers $using:h -ContentType "application/json" -Body $body -TimeoutSec 60 -SkipHttpErrorCheck
    [int]$r.StatusCode
  } catch { "EXC:$($_.Exception.Message)" }
} -ThrottleLimit $Concurrency
$results | Group-Object | ForEach-Object { "{0} x {1}" -f $_.Name, $_.Count }

Write-Output ""
Write-Output "=== 5) tool schema A/B (developer 之外的 400 回归) ==="
# 注意：tool_choice="none" 会让部分中转跳过 tools 校验，必须走真实工具调用路径。
$newParams = [ordered]@{ type = "object"; properties = [ordered]@{ description = [ordered]@{ type = "string"; description = "A short (3-5 word) description." }; prompt = [ordered]@{ type = "string"; description = "The complete task." } }; required = @("description", "prompt") }
$oldParams = [ordered]@{ description = [ordered]@{ type = "string"; required = $true; description = "A short description." }; prompt = [ordered]@{ type = "string"; required = $true; description = "The task." } }
function ToolSchemaProbe($label, $paramsObj) {
  $body = @{ model = $Models[0]; messages = @(@{ role = "user"; content = "请调用 subagent 工具" }); max_tokens = 64; tools = @(@{ type = "function"; function = @{ name = "subagent"; description = "delegation tool"; parameters = $paramsObj } }) } | ConvertTo-Json -Depth 8 -Compress
  try {
    $r = Invoke-WebRequest -Uri "$Base/chat/completions" -Method POST -Headers $h -ContentType "application/json" -Body $body -TimeoutSec 60 -SkipHttpErrorCheck
    "{0} -> {1}" -f $label, [int]$r.StatusCode
  } catch { "{0} -> EXC {1}" -f $label, $_.Exception.Message }
}
ToolSchemaProbe "OLD property-level required" $oldParams
ToolSchemaProbe "NEW object-level required  " $newParams

Write-Output "=== done ==="
