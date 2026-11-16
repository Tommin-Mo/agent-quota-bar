#!/usr/bin/env node
'use strict';
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.AGENT_QUOTA_PORT || 17890);
let cache = { at: 0, body: null };
let inflight = null;

function snapshot() {
  if (inflight) return inflight;
  inflight = new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(ROOT, 'scripts/quota'), 'snapshot'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve(code === 0 ? out : null));
    child.on('error', () => resolve(null));
  }).finally(() => { inflight = null; });
  return inflight;
}

const EXTENSION_ORIGIN = /^(chrome|moz|safari-web)-extension:\/\//;
const server = http.createServer(async (req, res) => {
  // 只允许浏览器扩展读取；普通网页不能通过 CORS 读取本机额度/账号标识。
  const origin = req.headers.origin;
  if (typeof origin === 'string' && EXTENSION_ORIGIN.test(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'OPTIONS') {
    if (res.getHeader('Access-Control-Allow-Origin')) {
      res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    }
    res.writeHead(204);
    return res.end();
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'method not allowed' }));
  }
  const host = String(req.headers.host || '');
  if (!/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(host)) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'invalid host' }));
  }
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
  // 不把邮箱 / uid 暴露给扩展或任何调用方。
  let body = cache.body;
  try {
    const parsed = JSON.parse(body);
    if (Array.isArray(parsed.providers)) {
      for (const provider of parsed.providers) delete provider.account;
    }
    body = JSON.stringify(parsed);
  } catch {}
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (req.method === 'HEAD') return res.end();
  res.end(body);
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`AgentQuotaBar extension endpoint: http://127.0.0.1:${PORT}/snapshot`);
});
