const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const extension = fs.readFileSync(path.join(root, 'browser-extension/popup.js'), 'utf8');
const swiftbar = fs.readFileSync(path.join(root, 'scripts/agent-quota.swiftbar.js'), 'utf8');

test('browser popup distinguishes transport failure, unreadable data, empty and recovery', async () => {
  const list = { appendChild() {} };
  const clock = {};
  const document = {
    getElementById: id => id === 'list' ? list : clock,
    createElement: () => ({ querySelector: () => ({}) }),
  };
  let fetchResult;
  let refresh;
  const context = vm.createContext({
    document,
    fetch: async () => {
      if (!fetchResult) throw new Error('offline');
      return fetchResult;
    },
    setInterval: fn => { refresh = fn; },
  });
  vm.runInContext(extension, context);
  for (let i = 0; i < 25; i++) {
    for (const [response, expected] of [
      [null, '无法连接'],
      [{ ok: false, json: async () => ({ ok: false }) }, '读取失败'],
      [{ ok: true, json: async () => { throw new Error('invalid data'); } }, '读取失败'],
      [{ ok: true, json: async () => ({ providers: [] }) }, '没有启用'],
    ]) {
      fetchResult = response;
      await refresh();
      assert.ok(list.textContent.includes(expected));
    }
    fetchResult = { ok: true, json: async () => ({ sampledAt: '2026-11-18T08:00:00Z', providers: [{ name: 'Fixture' }] }) };
    await refresh();
    assert.ok(clock.textContent.length > 0);
  }
});

test('SwiftBar distinguishes subprocess errors, empty service lists and recovery', () => {
  for (const [result, expected] of [
    [{ status: null, stdout: '' }, '额度读取失败'],
    [{ status: 0, stdout: 'bad data' }, '额度读取失败'],
    [{ status: 0, stdout: '{"providers":[]}' }, '没有启用的服务'],
    [{ status: 0, stdout: '{"providers":[{"name":"Fixture","presentation":{"score":2,"tier":3}}]}' }, '额度未触发警戒'],
  ]) {
    const lines = [];
    vm.runInNewContext(swiftbar, {
      __dirname: root, process: { execPath: process.execPath },
      require: id => id === 'path' ? path : { spawnSync: () => result },
      console: { log: line => lines.push(line) },
    });
    assert.equal(lines[0], expected);
  }
});
