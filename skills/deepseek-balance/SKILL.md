---
name: deepseek-balance
description: 查询 DeepSeek API 账户余额与今日消耗金额。当用户问「余额还有多少」「还剩多少钱」「今天花了多少」「DeepSeek balance」「用量费用」时使用；也用于按峰谷定价核算当天消耗。
---

# DeepSeek 余额与今日消耗

## 何时使用

用户询问 DeepSeek 账户余额、今日消耗、当日费用时使用本技能。余额不足、充值前后核对、想确认当天花费时也适用。

## 怎么执行

脚本位于本技能所在插件的 `scripts/balance.mjs`（相对本文件为 `../../scripts/balance.mjs`）。用 node 直接调用，加 `--json` 便于解析：

```bash
node <skill-dir>/../../scripts/balance.mjs balance --json
node <skill-dir>/../../scripts/balance.mjs today --json
```

- `balance`：余额 + 今日已用（同时把本次余额观测记入账本）
- `today`：只算今日已用
- 通用参数：`--mode ledger|token`、`--state-dir <目录>`、`--json`

脚本零依赖，要求 Node >= 18（依赖全局 `fetch`）。

## 凭据

按顺序解析，不需要额外配置：

1. 环境变量 `DEEPSEEK_API_KEY`
2. `~/.codex/config.toml` 中 `base_url` 指向 `api.deepseek.com` 的 `[model_providers.*]` 块里的 token（优先取顶层 `model_provider` 指定的那个）

令牌模式另外需要 `DEEPSEEK_PLATFORM_TOKEN`（DeepSeek 平台网页会话令牌，非 `sk-` 开头的 API key），没有时自动回落记账模式。

## 怎么解读输出

成功时 `ok: true`，关键字段：

- `balance.totalBalance` / `balance.currency`：当前余额与币种
- `todayUsage.amount`：今日已用金额，`todayUsage.mode` 是 `ledger` 或 `token`
- `todayUsage.fallback: true`：令牌模式失败或未配置，已回落记账模式
- `warnings`：非致命告警（如账本不可写）

失败时 `ok: false`，用 `code` 判断原因：`no_api_key`（未配置密钥）、`http_4xx`（密钥无效/无权限）、`network`/`http_5xx`（网络或服务端问题）、`parse`（响应不是合法 JSON）。

向用户汇报时给出余额金额与币种即可；今日已用按 2 位小数展示。账本是余额差值累计，只在脚本被调用时观测，因此要说明「Codex 未运行期间的消耗可能漏记」。

## 注意

- 网络或账本写入可能被 Codex 沙箱拦截：先看 `code` 与 `warnings`，必要时提示用户放行网络，或用 `DEEPSEEK_BALANCE_STATE_DIR` / `--state-dir` 指到可写目录。
- 定价表内置在脚本顶部（`PRICING` / `PEAK_HOURS` / `WEEKEND_VALLEY_FROM_SEC`），DeepSeek 调价后改这里。
- 不要臆造金额：脚本失败时直接回报错误码与原因，不要用估算值替代。
