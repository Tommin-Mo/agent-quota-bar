#!/usr/bin/env node
'use strict';
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.AGENT_QUOTA_PORT || 17890);
let cache = { at: 0, body: null };

function snapshot() {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(ROOT, 'scripts/quota'), 'snapshot'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve(code === 0 ? out : null));
    child.on('error', () => resolve(null));
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  if (req.url !== '/snapshot') {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'not found' }));
  }
  if (!cache.body || Date.now() - cache.at > 30000) {
    cache = { at: Date.now(), body: await snapshot() };
  }
  if (!cache.body) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'snapshot unavailable' }));
  }
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(cache.body);
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`AgentQuotaBar extension endpoint: http://127.0.0.1:${PORT}/snapshot`);
});
