'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { readChromeCookiesForHost, parseServiceStatus } = require('../collector/collector.js');

function makeChromeCookie(value, password = 'test-password') {
  const key = crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
  const iv = Buffer.alloc(16, 0x20);
  const cipher = crypto.createCipheriv('aes-128-cbc', key, iv);
  const body = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from('v10'), body]);
}

test('Chrome v10 cookie decryption and host filtering', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aqb-cookie-'));
  const db = path.join(dir, 'Cookies');
  const blob = makeChromeCookie('abc123');
  execFileSync('/usr/bin/sqlite3', [db], {
    input: `CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER);
      INSERT INTO cookies VALUES ('.opencode.ai', '__Host-console_session', '', x'${blob.toString('hex')}', '/', 0);
      INSERT INTO cookies VALUES ('.evil.example', 'secret', '', x'${blob.toString('hex')}', '/', 0);`,
  });
  const result = readChromeCookiesForHost('opencode.ai', { databasePath: db, password: 'test-password' });
  assert.match(result.header, /__Host-console_session=abc123/);
  assert.doesNotMatch(result.header, /secret/);
  const wrong = readChromeCookiesForHost('opencode.ai', { databasePath: db, password: 'wrong' });
  assert.equal(wrong.header, '');
});

test('status parsers map statuspage/opencode/flashduty', () => {
  assert.deepEqual(parseServiceStatus('codex', { status: { indicator: 'minor', description: 'Degraded' } }).serviceStatus, 'degraded');
  assert.deepEqual(parseServiceStatus('opencode', { status: 'operational' }).serviceStatus, 'ok');
  assert.deepEqual(parseServiceStatus('deepseek', { overall: { status: 'partial_outage' } }).serviceStatus, 'outage');
});
