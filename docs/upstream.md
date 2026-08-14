# 上游 PR 说明

`patch/` 里的补丁最终应该提 PR 给 `@deepseek-ai/dsh-llm-pi-ai`。
补丁文件本身即标准 unified diff，可直接作为 PR 的 diff。

## 目标包

`@deepseek-ai/dsh-llm-pi-ai`（`lib/index.js`）

## 改动内容（5 处，全部围绕 `supportsDeveloperRole`）

1. `resolveModelCompat()` 新增读取：
   `const supportsDeveloperRole = entry.compat?.supportsDeveloperRole ?? route?.supportsDeveloperRole;`
2. 早退条件补上 `&& supportsDeveloperRole === void 0`。
3. 非 openai-completions 协议的 `invalid(...)` 报错条件补上
   `|| entry.compat?.supportsDeveloperRole !== void 0`。
4. 返回的 `compat` 对象补上 `...supportsDeveloperRole === void 0 ? {} : { supportsDeveloperRole }`。
5. `compatProfile` 的 zod schema 补上 `supportsDeveloperRole: z.boolean()`。

## 动机

pi-ai 的 `detectCompat()` 对非知名域名默认 `supportsDeveloperRole: true`，
DeepSeek 后端只接受 `system` 角色，导致中转用户收到
`400: messages[0].role: unknown variant 'developer'`。
原版 `dsh-llm-pi-ai` 不读取该字段（且 zod 剥掉未知 key），用户无法从配置侧纠正。

该改动让 `compat.supportsDeveloperRole: false` 可从 settings 的 model / route 两级
透传，与已有的 `thinkingFormat` / `supportsReasoningEffort` 处理方式完全对称，
默认行为不变（未设置时输出与现状一致）。

## 备注

- 同一 PR 顺带建议：把 `invalid(...)` 的报错文案里的字段清单补上
  `supportsDeveloperRole`（第 3 处改动已包含条件，文案可一并更新）。
- 上游合入后，本仓库的 `patch/` 与 `plugin/relay-doctor.js` 即可退役，
  只保留接入手册与 settings 片段。
