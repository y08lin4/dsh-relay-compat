# DSH 接入 new-api 中转（DeepSeek 后端）完整手册

目标形态：DSH → 你的 new-api 面板（OpenAI 兼容口）→ DeepSeek 后端。
以下结论来自一次真实部署的逐项实测。

## 0. 术语

- **DSH**：DeepSeek Harness。两条 LLM 路径：
  - `deepseek-official`（`@deepseek-ai/dsh-llm-deepseek`）：直连官方 API，不发 `developer`，无 1MB 问题；
  - pi-ai 路由（`@deepseek-ai/dsh-llm-pi-ai`）：配置化 provider（如 `lyai`），走 `@earendil-works/pi-ai`，本文主角。
- **中转**：new-api 面板（Go/Gin），DeepSeek 后端，OpenAI 兼容接口。

## 1. 协议三选一：只能用 openai-completions

| 协议 | reasoning 支持 | 结论 |
|---|---|---|
| **openai-completions** | ✅ `reasoning_effort` 7 档全通；`none` 正确关闭思考（prompt token 91→12 量级） | **用这个** |
| openai-responses | ❌ `reasoning.effort` 映射坏，`none` 仍在思考 | 弃 |
| anthropic-messages | ❌ thinking 映射坏 | 弃 |

配置里写 `api: openai-completions`（见 `settings/lyai-snippet.yaml`）。

## 2. developer role 400：补丁 + 开关缺一不可

**症状**：

```
400: messages[0].role: unknown variant 'developer',
expected one of 'system', 'user', 'assistant', 'tool', 'latest_reminder'
```

**机理**：pi-ai 对非知名域名自动检测为「标准 OpenAI」→ `supportsDeveloperRole: true`
→ system prompt 的 role 被发成 `developer`。DeepSeek 后端只认 `system`。

**修法**（两步，缺一步 400 复现）：

1. 打补丁（让 `dsh-llm-pi-ai` 读取 `compat.supportsDeveloperRole`）：
   `powershell -File scripts/apply.ps1`
2. 打开开关（settings 对应 model 的 compat 下）：
   `supportsDeveloperRole: false`

两者都到位后**重启 DSH**。验证：发一句「测试」应正常回复；补丁在文件里应留
5 处 `supportsDeveloperRole`（`apply.ps1` 会自动校验）。

## 3. 思考档：7 档 wire 值映射

中转接受的 `reasoning_effort` wire 值为 `none/minimal/low/medium/high/xhigh/max`；
**`off` 直接发会被拒**（实测 400，见 §7），所以 settings 里必须写 `off: "none"` 映射。
DSH 侧档位键（选择器与 `effort` 参数）为 `off/minimal/low/medium/high/xhigh/max`。

| DSH 档位 | wire 值 | 用途建议 |
|---|---|---|
| off | none | 机械执行，最省（约 80% token 节约） |
| minimal / low | minimal / low | 简单执行、快速问答 |
| medium / high | medium / high | 正常推理（默认起点 medium） |
| xhigh | xhigh | 疑难排查 |
| max | max | 关键决策 / 高风险变更 |

注意：**不传 effort 时模型默认思考开启**——想要省钱，必须显式传 `off`。

## 4. 413 Payload Too Large：DSH 侧无解

**事实**（实测）：请求体 512/900/1000/1024KB→200，1050KB→413（阈值恰好 ≈1MB）；
直连面板端口（绕过 nginx / Cloudflare）同样 413 → 限制在 **new-api 进程自身的
Gin 层 1MB 请求体上限**，不是环境变量可调，改 nginx `client_max_body_size` 无效。

**触发场景**：长对话（历史累积）+ DSH 每轮重发 system prompt 与全工具 schema，
请求体越过 1MB。新会话短对话不触发。

**三条出路**：

1. **改源码重建镜像（治本）**：fork `QuantumNous/new-api`，找到 body 限制
   （`MaxBytesReader` / `1<<20` 之类），改大后自行 build Docker 镜像替换。
2. **换中转**：换 one-api（new-api 前身，可能无此 1MB 限制）或官方 key
   （`deepseek-official` 无此限制）。
3. **DSH 侧减小请求体（治标）**：精简 persona / 工具描述；勤开新会话控制历史长度。

## 5. 验收清单

- [ ] `apply.ps1` 通过（5 处标记校验）且已重启 DSH
- [ ] 简单对话通（无 developer 400）
- [ ] `off`/`none` 档：简单任务不思考、token 明显下降
- [ ] 7 档在模型选择器可见、逐档可跑
- [ ] 长对话越 1MB 前的表现已知（413 属服务端，非本仓库可修）
- [ ] `plugin/relay-doctor.js` 挂载后启动日志正常

## 6. 排障速查

| 症状 | 查 |
|---|---|
| developer 400 | 补丁丢了（跑 apply.ps1）或开关没写 false；改完必须重启 |
| off 档被拒 / 仍思考 | `off: "none"` 映射没写；确认 `api: openai-completions` |
| 413 | 见第 4 节；把长会话拆短或换中转 |
| 补丁打不上 | 版本漂移，按 `docs/upstream.md` 的 5 处清单手动改 |

## 7. wire 实测记录（可复验）

`scripts/wire-test.ps1` 一键复验（`-Base` / `-KeyEnv` 参数化，key 走环境变量不落盘）。
作者中转（new-api + DeepSeek 后端）2025-08-14 实测：

| 项 | 结果 |
|---|---|
| 7 档 × 2 模型（flash / pro） | 全 200 ✅ |
| `none` | think=no（关思考生效）✅ |
| 其余 6 档 | think=YES ✅ |
| `off` 直接发 wire | 400 ❌ → `off:"none"` 映射必需 |
| developer 角色 | 400 ❌ → 补丁 + `supportsDeveloperRole:false` 必需 |
| 请求体体积 | 1024KB→200，1050KB→413（阈值 ≈1MB） |
| 20 路并发 | 20×200，无 429 ✅ |
| 工具 schema 400 回归 | 属性级 `required:true` → 400；对象级 `required:[...]` → 200（DSH 插件必须用编译形态；注意 `tool_choice:"none"` 会跳过校验，测试必须走真实工具调用路径） |

结论：接入手册第 1–3 节的做法全部被实测背书；唯一无解项是 413（第 4 节）。
