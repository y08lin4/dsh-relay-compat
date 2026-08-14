# dsh-relay-compat · DSH 接入第三方中转模型

> DeepSeek Harness 接入第三方中转（new-api / one-api + DeepSeek 后端）的兼容工具包：
> 补丁 + 一键重打脚本 + 医生插件 + 完整接入手册。
>
> Relay-compat kit for DeepSeek Harness: a patch, a one-command re-applier, a
> doctor plugin, and a full integration playbook for third-party relays.

## 解决什么问题 / What this fixes

把 DSH 接到第三方中转（如 new-api 面板 + DeepSeek 后端）时，会撞上三个坑：

| # | 症状 | 根因 | 本仓库的解法 |
|---|---|---|---|
| 1 | `400: messages[0].role: unknown variant 'developer'` | pi-ai 对非知名域名默认把 system prompt 发成 `developer`，DeepSeek 后端只认 `system` | `patch/` 补丁 + 设置 `compat.supportsDeveloperRole: false` |
| 2 | 思考档选不了 / 选错 | 官方默认档位（off/high/max）与中转的 wire 值（none/minimal/…/max）对不上，`off` 直接发 `off` 会被拒 | `settings/` 里的 7 档 `reasoningEfforts` 映射（`off`→`none`） |
| 3 | `413 Payload Too Large` | new-api 自身 1MB 请求体上限（Gin 层硬限制），改 nginx 没用 | 服务端问题，DSH 侧无解——三条出路见 [docs/new-api-integration.md](docs/new-api-integration.md) |

另附协议选型实测结论：**openai-completions 是三个协议里唯一可靠的一个**
（openai-responses 的 reasoning 映射坏、anthropic-messages 的 thinking 映射坏）。

## 快速开始 / Quick start（三步）

```powershell
# 1. 打补丁（自动定位 npx 缓存 / 项目 node_modules 里的 dsh-llm-pi-ai，幂等）
powershell -File scripts/apply.ps1

# 2. 把 settings/lyai-snippet.yaml 合并进 ~/.dsh/settings.yaml
#    （baseURL 换成你的中转地址；API key 放进 ~/.dsh/.credentials.yaml）

# 3. 重启 DSH
```

可选：挂载 `plugin/relay-doctor.js`（见下），补丁丢失或开关缺失时在启动期提前告警，
而不是等到运行时收到一条谜之 400。

## 原理 / Why a patch is required

`@earendil-works/pi-ai`（`dsh-llm-pi-ai` 的底层库）对 OpenAI-completions 模型
**自动检测** `supportsDeveloperRole`：你的中转域名不属于任何已知服务商，检测结果为
「标准 OpenAI 模型」→ 默认 `supportsDeveloperRole = true` → system prompt 的 role
被发成 `developer`。

唯一覆盖入口是 `model.compat.supportsDeveloperRole`，但该字段只由 `dsh-llm-pi-ai`
内部从 settings 构建——**原版不认识这个 key，zod 校验还会把未知 key 剥掉**，且
ESM 绑定不可运行时 patch、provider 路由不可重注册。因此：

- 一个纯运行时插件**无法**替代这个补丁；
- 补丁（`patch/`，5 处小改动）或上游 PR（`docs/upstream.md`，补丁即 diff）是必需路径；
- 本仓库的插件只做「检查 + 提前告警」，让补丁丢失时问题暴露在启动期。

## 仓库结构 / Layout

```
patch/dsh-llm-pi-ai-supportsDeveloperRole.patch   补丁本体（git apply 可用，LF 已保真）
scripts/apply.ps1                                 一键：定位 → 打补丁 → 校验 → 检查设置 → 提示重启
plugin/relay-doctor.js                            医生插件：挂载时体检，缺补丁/缺开关提前告警
settings/lyai-snippet.yaml                        中转 provider 配置片段（7 档映射 + compat 开关）
docs/new-api-integration.md                       接入手册：协议对比、档位映射、413 三条出路、验收清单
docs/upstream.md                                  上游 PR 说明
```

## 挂载医生插件 / Mounting the doctor

把 `plugin/relay-doctor.js` 作为一个本地插件行加进任意 agent 预设（或主机组合）：

```yaml
# agent.cordis.yml（预设）里加一行：
- id: relay-doctor
  name: ./plugins/relay-doctor.js   # 按实际路径调整；本地路径以预设目录为 baseUrl
```

启动时它会在控制台输出：

- ✔ `[dsh-relay-compat] pi-ai 补丁已生效` —— 补丁在位；
- ⚠ `未找到已打补丁的 dsh-llm-pi-ai` —— 补丁丢了（npx 缓存刷新 / 换机器），提示先跑 `apply.ps1`；
- ⚠ `settings.yaml 未发现 supportsDeveloperRole 开关` —— 补丁在但开关没开，role 仍会是 `developer`。

## 边界 / Limits

- **413 无解于 DSH 侧**：new-api 的 1MB 请求体上限写在 Go 源码里，不是环境变量可调；
  三条出路（改源码重建镜像 / 换 one-api / 减小请求体）见 [docs/new-api-integration.md](docs/new-api-integration.md)。
- **补丁以版本为准**：补丁行号基于当前 `dsh-llm-pi-ai` 版本；版本漂移导致无法 apply 时，
  按补丁的 5 处语义改动手动打（`docs/upstream.md` 有清单）。
- **终点是上游**：`patch/` 里的 5 处改动提 PR 给 `@deepseek-ai/dsh-llm-pi-ai` 后，
  本仓库的补丁与医生插件即可退役，只留接入手册。

## 许可证 / License

[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)（署名-相同方式共享）：
可商用、可修改、可再分发；衍生作品须同样以 CC BY-SA 4.0 开源并保留署名。
