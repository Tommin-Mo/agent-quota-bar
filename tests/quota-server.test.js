'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

function request(port, headers, method = 'GET', url = '/snapshot') {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: url, method, headers }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

test('quota server only grants CORS to extension origins and rejects bad host/method', async (t) => {
  const port = 17991;
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'scripts', 'quota-server.js')], {
    env: { ...process.env, AGENT_QUOTA_PORT: String(port) },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  t.after(() => child.kill());
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server timeout')), 5000);
    child.stdout.on('data', (data) => {
      if (String(data).includes('extension endpoint')) { clearTimeout(timer); resolve(); }
    });
  });
  const evil = await request(port, { Origin: 'https://evil.example', Host: `127.0.0.1:${port}` }, 'GET', '/nope');
  assert.equal(evil.headers['access-control-allow-origin'], undefined);
  const ext = await request(port, { Origin: 'chrome-extension://abcdef', Host: `127.0.0.1:${port}` }, 'GET', '/nope');
  assert.equal(ext.headers['access-control-allow-origin'], 'chrome-extension://abcdef');
  const badHost = await request(port, { Host: 'evil.example' }, 'GET', '/nope');
  assert.equal(badHost.status, 403);
  const post = await request(port, { Host: `127.0.0.1:${port}` }, 'POST', '/nope');
  assert.equal(post.status, 405);
});
