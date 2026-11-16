#!/usr/bin/env node
/**
 * SwiftBar / xbar 插件：直接复用 scripts/quota snapshot。
 * 安装：chmod +x，然后在 SwiftBar 插件目录放一个软链接即可，例如
 *   ln -s "$PWD/scripts/agent-quota.swiftbar.js" "$HOME/Library/Application Support/SwiftBar/Plugins/agent-quota.1m.js"
 * SwiftBar 会在菜单栏/桌面显示最紧张的一家。
 */
'use strict';
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const result = spawnSync(process.execPath, [path.join(root, 'scripts/quota'), 'snapshot'], {
  encoding: 'utf8',
  timeout: 120000,
});
let data;
try { data = JSON.parse(result.stdout || '{}'); } catch {}
const providers = Array.isArray(data?.providers) ? data.providers : [];
const percent = providers
  .map((p) => {
    const m = (p.metrics || []).find((x) => x.kind === 'percent');
    if (!m || typeof m.remainingPercent !== 'number') return null;
    return { id: p.id, name: p.name, remaining: m.remainingPercent, reset: m.detail || '' };
  })
  .filter(Boolean)
  .sort((a, b) => a.remaining - b.remaining);
const credit = providers
  .map((p) => {
    const m = (p.metrics || []).find((x) => x.kind === 'credit');
    if (!m || !m.headlineValue) return null;
    return { id: p.id, name: p.name, value: m.headlineValue };
  })
  .filter(Boolean)[0];
const worst = percent[0];
const label = worst
  ? `${worst.name} ${Math.round(worst.remaining)}%`
  : (credit ? `${credit.name} ${credit.value}` : (data?.ok === false ? '额度读取失败' : '暂无额度'));
console.log(label);
console.log('---');
for (const p of providers) {
  const m = (p.metrics || []).find((x) => x.kind === 'percent');
  const c = (p.metrics || []).find((x) => x.kind === 'credit');
  const value = m ? `剩 ${Math.round(m.remainingPercent)}%${m.detail ? ' · ' + m.detail : ''}` : (c?.headlineValue ? `余额 ${c.headlineValue}` : (p.headline || ''));
  console.log(`${p.name}: ${value}`);
}
console.log('---');
console.log('立即刷新 | refresh=true');
console.log('打开 AgentQuotaBar | bash=/usr/bin/open param1=/Applications/AgentQuotaBar.app');
