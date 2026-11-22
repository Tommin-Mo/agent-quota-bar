#!/usr/bin/env node
'use strict';
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.AGENT_QUOTA_PORT || 17890);
let cache = { at: 0, body: null };
let inflight = null;

function publicSnapshot(output) {
  try {
    const parsed = JSON.parse(output);
    if (!Array.isArray(parsed?.providers) || !parsed.providers.every(p =>
      p && typeof p.id === 'string' && p.id.length > 0 && typeof p.status === 'string')) return null;
    parsed.providers = parsed.providers.filter(p => p.status !== 'disabled' && p.presentation?.visible !== false);
    for (const provider of parsed.providers) {
      delete provider.account;
      delete provider.localAccountID;
    }
    return JSON.stringify(parsed);
  } catch {
    return null;
  }
}

function snapshot() {
  if (inflight) return inflight;
  inflight = new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(ROOT, 'scripts/quota'), 'snapshot'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve(code === 0 ? publicSnapshot(out) : null));
    child.on('error', () => resolve(null));
  }).then(body => {
    if (body !== null) cache = { at: Date.now(), body };
    return body;
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
  const body = cache.body && Date.now() - cache.at <= 30000 ? cache.body : await snapshot();
  if (!body) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'snapshot unavailable' }));
  }
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (req.method === 'HEAD') return res.end();
  res.end(body);
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`AgentQuotaBar extension endpoint: http://127.0.0.1:${PORT}/snapshot`);
});
