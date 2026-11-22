const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const { feeds, readFeed } = require('../collector/local-agents');

test('local feed discovery, metric validation and collector output', t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-feeds-'));
  t.after(() => fs.rmSync(home, {recursive:true, force:true}));
  const config = path.join(home, 'config.json'), dir = path.join(home, 'agents');
  fs.writeFileSync(config, '{}');
  fs.mkdirSync(dir);
  const name = 'demo-agent', file = path.join(dir, name + '.json');
  const stamp = new Date().toISOString();
  const weekly = {type:'percent', label:'本周', remaining:83};
  const put = (metrics, updatedAt = stamp) => fs.writeFileSync(file, JSON.stringify({schema:1, name:'Demo', updatedAt, metrics}));
  put([weekly, {...weekly, label:'5 小时', remaining:0}]);
  for (const bad of ['doubao','all','constructor','Bad.ID']) fs.writeFileSync(path.join(dir, bad + '.json'), '{}');
  fs.symlinkSync(file, path.join(dir, 'linked.json'));
  const found = feeds(config, new Set(['doubao']));
  assert.deepEqual(found, [{id:name, file}]);
  const result = JSON.parse(execFileSync(process.execPath, [require.resolve('../collector/collector'), '--only=' + name],
    {env:{...process.env, AGENT_QUOTA_CONFIG:config}}));
  const [row] = result.providers;
  assert.equal(row.name, 'Demo');
  assert.equal(row.sampledAt, stamp);
  assert.equal(row.metrics[0].remainingPercent, 83);
  assert.equal(row.metrics[1].remainingPercent, 0);
  assert.equal(row.presentation.tier, 0);
  const read = () => readFeed(found[0]);
  put([{type:'balance',label:'余额',remaining:2.5,currency:'CNY'}]);
  assert.equal(read().metrics[0].headlineValue, '¥2.50');
  assert.equal(read().balance, 2.5);
  put([{type:'points',label:'积分',remaining:0}], '2020-01-01T00:00:00Z');
  assert.equal(read().cached, true);
  assert.equal(read().metrics[0].value, 0);
  for (const metrics of [[], [weekly,weekly], [weekly,{...weekly,label:'本周 '}], [{...weekly,remaining:null}], [{...weekly,remaining:101}], [{...weekly,remaining:'0'}]]) {
    put(metrics); assert.throws(read);
  }
  put([weekly], new Date(Date.now() + 3600000).toISOString()); assert.throws(read);
  fs.unlinkSync(file);
  assert.deepEqual(feeds(config, new Set(['doubao'])), []);
});
