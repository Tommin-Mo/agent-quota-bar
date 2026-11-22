// Each file is a data feed. Adapters never run commands from a feed.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

function feeds(configPath, reserved) {
  const dir = path.join(path.dirname(configPath), 'agents');
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) {
    if (['ENOENT', 'EACCES', 'ENOTDIR'].includes(e.code)) return [];
    throw e;
  }
  return entries.flatMap(entry => {
    const id = entry.name.replace(/\.json$/, '');
    if (!entry.isFile() || entry.name !== id + '.json' || !/^[a-z][a-z0-9-]{0,39}$/.test(id) ||
        reserved.has(id) || Object.hasOwn(Object.prototype, id) || ['all', 'quota'].includes(id)) return [];
    return [{ id, file: path.join(dir, entry.name) }];
  }).sort((a, b) => a.id.localeCompare(b.id));
}

function readFeed({ id, file }, now = Date.now()) {
  const invalid = () => { throw Error('额度文件格式有误'); };
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  let data;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > 65536) invalid();
    const buf = Buffer.alloc(65537);
    const length = fs.readSync(fd, buf, 0, buf.length, 0);
    if (length > 65536) invalid();
    data = JSON.parse(buf.toString('utf8', 0, length));
  } finally { fs.closeSync(fd); }
  const text = x => typeof x === 'string' && x.trim() && x.length <= 32 && !/[\u0000-\u001f\u007f]/.test(x);
  const date = s => typeof s === 'string' && /^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(s) ? Date.parse(s) : NaN;
  const stamp = date(data.updatedAt);
  if (data.schema !== 1 || !text(data.name) || !Number.isFinite(stamp) || stamp > now + 60000 ||
      !Array.isArray(data.metrics) || !data.metrics.length || data.metrics.length > 4) invalid();
  const used = new Set();
  const metrics = data.metrics.map(m => {
    if (!m || typeof m.label !== 'string' || !text(m.label) || !Number.isFinite(m.remaining) || m.remaining < 0) invalid();
    const label = m.label.trim();
    if (used.has(label)) invalid();
    used.add(label);
    if (m.type === 'percent') {
      const reset = m.resetAt == null ? null : date(m.resetAt);
      if (m.remaining > 100 || (reset !== null && !Number.isFinite(reset))) invalid();
      return { kind: 'percent', label, remainingPercent: m.remaining, usedPercent: 100 - m.remaining, resetAt: reset };
    }
    if (data.metrics.length !== 1) invalid();
    if (m.type === 'balance' && ['CNY','USD','EUR','GBP'].includes(m.currency)) {
      const prefix = { CNY: '¥', USD: '$', EUR: '€', GBP: '£' }[m.currency];
      return { kind: 'credit', label, currency: m.currency, value: m.remaining, headlineValue: prefix + m.remaining.toFixed(2) };
    }
    if (m.type !== 'points' || !Number.isSafeInteger(m.remaining)) invalid();
    return { kind: 'credit', label, value: m.remaining, headlineValue: String(m.remaining), currency: '' };
  });
  const row = { id, name: data.name.trim(), status: 'ok', metrics, sampledAt: new Date(stamp).toISOString(), cached: now - stamp > 15 * 60000 };
  if (metrics[0].kind === 'credit') row.balance = metrics[0].value;
  return row;
}

module.exports = { feeds, readFeed };
