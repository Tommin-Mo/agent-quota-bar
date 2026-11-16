# scripts/quota —— JSON / 成本 CLI

零依赖 Node 小工具，直接复用仓库或已安装 App 里的 `collector.js`。默认输出单行 JSON，适合接 SketchyBar、状态栏脚本、cron、CI 或 `jq`。

```bash
./scripts/quota snapshot --pretty          # 实时查询一次 collector
./scripts/quota cost --pretty              # 今日消费 + 余额 + OpenCode 本地成本
./scripts/quota usage --pretty             # usage.json 原始状态
./scripts/quota history --pretty           # App 7 天历史 + CLI 兜底记录
./scripts/quota accounts --pretty          # 多账号（不含凭据值）
./scripts/quota help
```

## 通用约定

| 项目 | 说明 |
| --- | --- |
| 运行环境 | macOS + Node.js 18+（不在 App 内运行） |
| 默认输出 | 单行 JSON；`--pretty` 缩进 2 空格 |
| 退出码 | `0` 成功；`1` 数据/collector 失败；`2` 参数错误 |
| 错误格式 | `{"schema":1,"ok":false,"error":{"code":"...","message":"..."}}` |
| 只读 | 除 `history --record` 外不写文件；不打印配置里的 API Key / Cookie / token |
| 配置目录 | 默认 `~/.config/agent-quota/`；`AGENT_QUOTA_CONFIG` 可改路径，同目录下的 `usage.json`、`last-snapshot.json`、`history.json`、`history/` 一起生效 |
| collector | 默认先找仓库 `collector/collector.js`，再找 `~/Applications` 或 `/Applications` 的 App；也可用 `AGENT_QUOTA_COLLECTOR` 指定 |

## snapshot

实时调用 collector，输出与 App 内部完全相同的 schema：`schema / updatedAt / sampledAt / providers[]`。单个 provider 失败也会返回 JSON（该行 `status` 为 `error/unconfigured`），不会整体失败。

```json
{
  "schema": 1,
  "updatedAt": "2026-11-16T05:00:00.000Z",
  "sampledAt": "2026-11-16T04:59:58.000Z",
  "providers": [
    {
      "id": "deepseek",
      "name": "DeepSeek",
      "status": "ok",
      "balance": 1.31,
      "metrics": [{ "label": "余额", "kind": "credit", "currency": "CNY", "headlineValue": "¥1.31" }]
    },
    {
      "id": "opencode",
      "name": "OpenCode",
      "status": "ok",
      "metrics": [{ "label": "本周", "kind": "percent", "usedPercent": 9, "remainingPercent": 91 }],
      "cost": {
        "currency": "USD",
        "today": 0.12,
        "last7Days": 0.84,
        "tokens": { "today": { "input": 1000, "output": 2000 }, "last7Days": { "input": 8000, "output": 12000 } }
      }
    }
  ]
}
```

- `providers[].account` 可能是 email / uid / orgId，属于账号标识；转发或贴日志前请自行脱敏。
- OpenCode 的 `cost` 只有在本地 `opencode.db` 可读且 `providers.opencode.costEnabled != false` 时出现。

## cost

合并 `usage.json`（今日消费）与 `last-snapshot.json`（余额/累计消费/OpenCode 成本）。默认不联网；`--live` 才会先跑一次 collector。`stale: true` 表示 `usage.json` 不是今天的数据。

```json
{
  "schema": 1,
  "ok": true,
  "day": "2026-11-16",
  "generatedAt": "2026-11-16T05:00:00.000Z",
  "stale": false,
  "snapshotSource": "cache",
  "snapshotAt": "2026-11-16T04:59:58.000Z",
  "providers": [
    { "id": "deepseek", "name": "DeepSeek", "unit": "CNY", "todaySpent": 0.03, "balance": 1.31 },
    { "id": "trae", "name": "Trae", "unit": "credits", "todaySpent": 100, "consumed": 1234 },
    { "id": "workbuddy", "name": "WorkBuddy", "unit": "credits", "todaySpent": 0, "consumed": 456 },
    {
      "id": "opencode",
      "name": "OpenCode",
      "unit": "USD",
      "todaySpent": 0.12,
      "last7Days": 0.84,
      "tokens": { "today": { "input": 1000, "output": 2000 }, "last7Days": { "input": 8000, "output": 12000 } },
      "source": "opencode-local-db"
    }
  ]
}
```

- 不同 provider 的 `unit` 不同（CNY / credits / USD），不要跨行直接相加。
- `--only=opencode` 时只读快照里的 OpenCode 成本，不需要 `usage.json`；此时 `day` / `stale` 可能为 `null`。
- OpenCode 无本地库时该行 `todaySpent` 为 `null` 并带 `note`。
- 口径见 README 的「成本口径」；这是采样估算，不是账单。

## usage

输出 `usage.json` 的原始状态并加一层包装，便于排查“今日消费为什么是 0”：

```json
{
  "schema": 1,
  "ok": true,
  "path": "/Users/me/.config/agent-quota/usage.json",
  "day": "2026-11-16",
  "stale": false,
  "usage": {
    "day": "2026-11-16",
    "deepseek": { "lastBalance": 1.31, "spent": 0.03, "updatedAt": "2026-11-16T04:59:58.000Z" },
    "trae": { "baseline": 1134, "spent": 100, "updatedAt": "..." },
    "workbuddy": { "baseline": 456, "spent": 0, "updatedAt": "..." }
  }
}
```

## history

App 每次刷新成功后写 `<配置目录>/history.json`（近 7 天）；`history` 同时返回 App 历史和 CLI 兜底记录：

```json
{
  "schema": 1,
  "ok": true,
  "app": {
    "path": "/Users/me/.config/agent-quota/history.json",
    "available": true,
    "retentionDays": 7,
    "entries": [
      {
        "date": "2026-11-16",
        "provider": "deepseek",
        "balance": 1.31,
        "status": "ok",
        "updatedAt": "2026-11-16T04:59:58.000Z"
      },
      {
        "date": "2026-11-16",
        "provider": "opencode",
        "cost": 0.12,
        "tokens": { "input": 1000, "output": 2000 },
        "status": "ok",
        "updatedAt": "2026-11-16T04:59:58.000Z"
      }
    ]
  },
  "cli": { "dir": "/Users/me/.config/agent-quota/history", "days": [] }
}
```

- `history.json` 是 App 持久化的 `{schema:1, entries:[...]}`；每个 `date + provider` 一条，记录 `usedPercent / remainingPercent / balance / consumed / cost / tokens / status / account / plan / updatedAt`。其中 `cost / tokens` 主要由 OpenCode 本地库提供，其他家通常只有额度/余额字段。保留窗口 7 天，跨天自动裁剪。
- `history --record` 只写 CLI 的 `history/YYYY-MM-DD.json`（成本快照），用于 App 长期没运行时的兜底；与 `history.json` 不共用目录，不会覆盖 App 数据。重复执行会覆盖当天文件。
- `usage.json` 不是今天时 `--record` 会拒绝（`--allow-stale` 可强制）。

## accounts

读取 `config.json` 的多账号配置，只输出标签、活动账号和“哪些字段已填”，**不输出凭据值**：

```json
{
  "schema": 1,
  "ok": true,
  "path": "/Users/me/.config/agent-quota/config.json",
  "providers": [
    {
      "id": "opencode",
      "name": "OpenCode",
      "mode": "accounts",
      "activeAccount": "work",
      "accounts": [
        {
          "id": "work",
          "label": "Work",
          "account": "me@example.com",
          "legacy": false,
          "credentialFields": ["cookie", "workspaceId"],
          "updatedAt": "2026-01-01T00:00:00Z",
          "lastUsedAt": "2026-01-02T00:00:00Z"
        }
      ]
    },
    {
      "id": "deepseek",
      "name": "DeepSeek",
      "mode": "legacy",
      "activeAccount": "default",
      "accounts": [
        { "id": "default", "label": "默认账号", "legacy": true, "credentialFields": ["apiKey"] }
      ]
    }
  ]
}
```

- `mode`：`accounts` = 显式 `accounts[]`；`legacy` = 旧扁平字段合成的默认账号；`none` = 未配置。
- 该命令只读；新增/切换账号请用 App（切换）或直接改 `config.json`（新增/编辑）。手工新增 `accounts[]` 后，建议在设置 → 服务里切换一次该账号，让凭据镜像到扁平字段，collector 才能读到。

## 集成示例

```bash
# 只有 DeepSeek 的今日消费（金额）
./scripts/quota cost | jq -r '.providers[] | select(.id=="deepseek") | .todaySpent'

# 菜单栏文案：本周剩余百分比（Codex）
./scripts/quota snapshot --only=codex | jq -r '.providers[0].metrics[0] | "\(.remainingPercent)%"'

# 只看 OpenCode 本地成本（需要 opencode.db）
./scripts/quota cost --only=opencode --live --pretty

# 用另一份配置查询第二个账号（不改动当前 App 配置）
AGENT_QUOTA_CONFIG=~/.config/agent-quota/account-b.json ./scripts/quota snapshot --pretty
```

`jq` 不是必需依赖；它只用于上面的示例。

## 隐私与限制

- `snapshot` / `history` 可能包含账号标识（email、uid、orgId），`accounts` 只含标签、账号标识和已填字段名（不含凭据值）；不要公开转贴未脱敏输出。
- 不打印 `config.json` 里的 `apiKey`、`cookie`、`token` 等值。
- 成本是本地估算：DeepSeek / Trae / WorkBuddy 来自采样差值，OpenCode 来自本地库；Codex 没有成本数据。
- 多账号同一时间只有一个活动账号；App 的 `activeAccount` 切换会把凭据镜像到扁平字段以兼容 collector。
