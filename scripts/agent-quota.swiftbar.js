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
const providers = (data?.providers || []).filter(p => p.status !== 'disabled' && p.presentation?.visible !== false);
const ranked = providers.filter(p => Number.isFinite(p.presentation?.score))
  .sort((a, b) => a.presentation.tier - b.presentation.tier || a.presentation.score - b.presentation.score || a.id.localeCompare(b.id));
const leaders = ranked.filter(p => p.presentation.tier === ranked[0].presentation.tier && p.presentation.score === ranked[0].presentation.score);
const failed = result.status !== 0 || data?.ok === false || !Array.isArray(data?.providers);
let summary = failed ? '额度读取失败' : providers.length ? '暂无可比较额度' : '没有启用的服务';
if (!failed && leaders.length) {
  const first = leaders[0];
  if (first.presentation.tier === 3) summary = '额度未触发警戒';
  else if (leaders.length === 1) summary = first.name + ' ' + first.presentation.risk;
  else summary = leaders.length + (first.presentation.tier === 0 ? ' 家已耗尽' : ' 家并列紧张');
}
console.log(summary);
console.log('---');
for (const p of providers) console.log(p.name + ': ' + (p.presentation?.primary || '暂无额度数据'));
console.log('---');
console.log('立即刷新 | refresh=true');
console.log('打开 AgentQuotaBar | bash=/usr/bin/open param1=/Applications/AgentQuotaBar.app');
