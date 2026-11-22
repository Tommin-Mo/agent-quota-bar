'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { codexWindows, goWindowMeters, workBuddyQuota, deepseekResult } = require('../collector/collector');

test('Codex distinguishes missing usage, zero and full usage', () => {
  for (const used of [null, '', ' ', false]) {
    assert.deepEqual(codexWindows({ primary_window: { used_percent: used } }), []);
  }
  for (const used of [0, 100]) {
    assert.equal(codexWindows({ primary_window: { used_percent: used } })[0].remainingPercent, 100 - used);
  }
});

test('OpenCode weekly remainder and reset belong to weekly window', () => {
  for (const [weekly, expected] of [[17, 83], [90, 10]]) {
    const reset = '2026-11-23T00:00:00Z';
    const meters = goWindowMeters({ usage: { monthly: { percent: 10 }, weekly: { percent: weekly, resetsAt: reset }, rolling: { percent: 4 } } });
    assert.deepEqual(meters.map(m => [m.label, m.remainingPercent]), [['5 小时', 96], ['本周', expected], ['本月', 90]]);
    assert.equal(meters[1].resetAt, Date.parse(reset));
  }
});

test('WorkBuddy partial packages, expiration and real zero', () => {
  const good = { CycleCapacitySize: 1000, CycleCapacityRemain: 0 };
  const bad = { CycleCapacitySize: 1000 };
  for (const list of [[bad], [good, bad]]) {
    const result = workBuddyQuota(list, '', 'auto');
    assert.equal(result.metrics.length, 0);
    assert.equal(result.consumed, undefined);
  }
  const zero = workBuddyQuota([good, { ...bad, ExpireTime: 1 }], '', 'auto');
  assert.equal(zero.metrics[0].value, 0);
  assert.equal(zero.consumed, 1000);
  assert.equal(workBuddyQuota([{ CycleCapacityRemain: 12 }], '', 'auto').consumed, undefined);
});

test('DeepSeek keeps currency, debt and unknown total', () => {
  const dollars = deepseekResult({ balance_infos: [{ currency: 'USD', total_balance: '-12' }] });
  assert.equal(dollars.balance, -12);
  assert.equal(dollars.metrics[0].headlineValue, '$-12.00');
  const unknown = deepseekResult({ balance_infos: [{ total_balance: null, granted_balance: 12 }] });
  assert.ok(!unknown.metrics.some(m => m.kind === 'credit'));
});

test('external presentation keeps mixed points, zero cash and visibility', () => {
  const { quotaPresentation } = require('../collector/collector');
  const points = {label: '积分', kind: 'credit', value: 12, headlineValue: '12'};
  const window = {label: '快速请求', kind: 'percent', remainingPercent: 55};
  const mixed = quotaPresentation({id: 'trae', status: 'ok', metrics: [window, points]}, {});
  assert.equal(mixed.primary, '积分 12');
  assert.equal(mixed.risk, '积分 12');
  const empty = quotaPresentation({id: 'deepseek', status: 'warn', metrics: [{...points, value: 0}]}, {hiddenProviders: ['deepseek']});
  assert.equal(empty.score, 0);
  assert.equal(empty.visible, false);
});

test('cross-surface percent endpoints and valid threshold pairs', () => {
  const { quotaPresentation } = require('../collector/collector');
  function present(value, style = {}) {
    return quotaPresentation({id:'opencode', status:'ok', metrics:[
      {label:'本周',kind:'percent',remainingPercent:value}
    ]}, {style});
  }
  for (const [input, expected] of [[0,'0%'],[0.4,'<1%'],[83,'83%'],[99.6,'>99%'],[100,'100%']]) {
    assert.equal(present(input).risk, '本周剩 ' + expected);
  }
  assert.equal(present(1,{warningPercent:1,dangerPercent:2}).tier,1);
  assert.equal(present(2,{warningPercent:1,dangerPercent:2}).tier,2);
  const oldStyle = {warningPercent:54.945605, dangerPercent:20.034567};
  assert.equal(present(54.92, oldStyle).tier, 3);
  assert.equal(present(54.9, oldStyle).tier, 2);
  assert.equal(present(20.02, oldStyle).tier, 2);
});

test('daily quota is distinct from rolling and weekly and requires source data', () => {
  assert.equal(codexWindows({primary_window: {used_percent: 25, limit_window_seconds: 86400}})[0].label, '每日');
  assert.deepEqual(goWindowMeters({usage: {daily: {percent: 25}, weekly: {percent: 10}}}).map(m => [m.label, m.remainingPercent]), [['每日', 75], ['本周', 90]]);
  assert.equal(goWindowMeters({usage: {daily: {}}}).length, 0);
});
