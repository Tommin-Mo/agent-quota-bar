#!/usr/bin/env node
/**
 * AgentQuotaBar collector
 *
 * 读取本机已有的登录态（或 ~/.config/agent-quota/config.json 里的密钥），
 * 查询各家 AI 编码服务的剩余额度，输出一份统一的 JSON 给菜单栏 App。
 *
 * 设计原则：
 *  - 只读：不会修改任何第三方登录态 / 配置文件。
 *  - 无依赖：只用 Node 标准库 + 系统自带 curl。
 *  - 单个 provider 失败不影响其它 provider。
 *
 * 用法：
 *   node collector.js [--pretty] [--only=codex,trae]
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const crypto = require('crypto');
const { readTraeAuth } = require('./trae-crypto');

const HOME = os.homedir();
const CONFIG_PATH =
  process.env.AGENT_QUOTA_CONFIG || path.join(HOME, '.config', 'agent-quota', 'config.json');

const DEFAULT_CONFIG = {
  refreshSeconds: 300,
  proxy: 'auto',
  proxyHosts: ['chatgpt.com', 'auth.openai.com'],
  providers: {
    codex: { enabled: true },
    deepseek: { enabled: true, apiKey: '' },
    opencode: { enabled: true, apiKey: '', cookie: '', workspaceId: '' },
    trae: { enabled: true, edition: 'cn' },
    workbuddy: { enabled: true, token: '', uid: '' },
  },
};

// ---------------------------------------------------------------- 配置

function loadConfig() {
  let user = {};
  try {
    user = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch (e) {
    if (e.code === 'ENOENT') {
      try {
        fs.mkdirSync(path.dirname(CONFIG_PATH), { recursive: true });
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(DEFAULT_CONFIG, null, 2) + '\n', { mode: 0o600 });
      } catch {}
    }
  }
  return {
    ...DEFAULT_CONFIG,
    ...user,
    providers: { ...DEFAULT_CONFIG.providers, ...(user.providers || {}) },
  };
}

const CONFIG = loadConfig();

// ---------------------------------------------------------------- 网络

let _proxy;
function systemProxy() {
  if (_proxy !== undefined) return _proxy;
  const configured = String(CONFIG.proxy || 'auto').trim() || 'auto';
  if (configured === 'off' || configured === 'none') return (_proxy = null);
  if (configured !== 'auto') return (_proxy = configured);
  if (process.env.AGENT_QUOTA_PROXY) return (_proxy = process.env.AGENT_QUOTA_PROXY);
  try {
    const out = execFileSync('scutil', ['--proxy'], { encoding: 'utf8' });
    const host = /HTTPSProxy\s*:\s*(\S+)/.exec(out)?.[1];
    const port = /HTTPSPort\s*:\s*(\d+)/.exec(out)?.[1];
    _proxy = host && port ? `http://${host}:${port}` : null;
  } catch {
    _proxy = null;
  }
  return _proxy;
}

function proxyFor(url) {
  const hosts = CONFIG.proxyHosts || [];
  try {
    const host = new URL(url).hostname;
    if (hosts.some((h) => host === h || host.endsWith('.' + h))) return systemProxy();
  } catch {}
  return null;
}

/** 用系统 curl 发请求：自动支持系统代理、TLS、gzip，避免 Node 代理配置的坑。 */
function http(url, opts = {}) {
  const { method = 'GET', headers = {}, body = null, timeout = 25 } = opts;
  const proxy = proxyFor(url);
  const args = ['-sS', '--compressed', '-m', String(timeout), '-w', '\n__AQB_STATUS__%{http_code}'];
  if (proxy) args.push('--proxy', proxy);
  for (const [k, v] of Object.entries(headers)) {
    if (v !== undefined && v !== null && v !== '') args.push('-H', `${k}: ${v}`);
  }
  if (body !== null) args.push('--data-binary', body);
  args.push(url);

  let out;
  try {
    out = execFileSync('curl', args, {
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      timeout: (timeout + 5) * 1000,
    });
  } catch (e) {
    const msg = String(e.stderr || e.message || e).trim().split('\n')[0];
    throw new Error(`网络请求失败（${new URL(url).hostname}）：${msg}`);
  }
  const match = out.match(/__AQB_STATUS__(\d+)\s*$/);
  const status = match ? Number(match[1]) : 0;
  const text = match ? out.slice(0, match.index) : out;
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {}
  return { status, text, json };
}

function pick(obj, ...paths) {
  for (const p of paths) {
    const parts = Array.isArray(p) ? p : p.split('.');
    let cur = obj;
    for (const part of parts) {
      if (cur === null || cur === undefined) break;
      cur = cur[part];
    }
    if (cur !== undefined && cur !== null && cur !== '') return cur;
  }
  return undefined;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

function round(n, digits = 2) {
  const f = 10 ** digits;
  return Math.round(n * f) / f;
}

function fmtMoney(n, currency) {
  const symbol = currency === 'USD' ? '$' : currency === 'CNY' ? '¥' : '';
  return `${symbol}${round(n, 2).toFixed(2)}`;
}

function fmtReset(ts) {
  if (!ts) return '';
  const diff = Math.max(0, ts - Date.now());
  const mins = Math.round(diff / 60000);
  if (mins < 1) return '即将重置';
  if (mins < 60) return `${mins} 分钟后重置`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours} 小时后重置`;
  const days = Math.floor(hours / 24);
  const rest = hours % 24;
  return rest === 0 ? `${days} 天后重置` : `${days} 天 ${rest} 小时后重置`;
}

function fmtDate(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${mm}-${dd}`;
}

function windowLabel(seconds) {
  if (!seconds) return '额度';
  if (seconds <= 6 * 3600) return '5 小时';
  if (seconds <= 8 * 86400) return '本周';
  if (seconds <= 32 * 86400) return '本月';
  return '周期';
}

// ---------------------------------------------------------------- 结果构造

function percentMetric(label, usedPercent, resetAt, extraDetail) {
  const used = Math.min(100, Math.max(0, Number(usedPercent) || 0));
  const detailParts = [];
  if (extraDetail) detailParts.push(extraDetail);
  if (resetAt) detailParts.push(fmtReset(resetAt));
  return {
    label,
    kind: 'percent',
    usedPercent: used,
    remainingPercent: Math.max(0, 100 - used),
    resetAt: resetAt || null,
    detail: detailParts.join(' · '),
  };
}

function creditMetric(label, value, currency, detail) {
  return {
    label,
    kind: 'credit',
    value: round(value, 2),
    currency: currency || '',
    headlineValue: currency ? fmtMoney(value, currency) : String(Math.round(value)),
    detail: detail || '',
  };
}

function textMetric(label, value, detail) {
  return { label, kind: 'text', value: String(value), headlineValue: String(value), detail: detail || '' };
}

function provider(id, name, status, metrics, extra = {}) {
  return { id, name, status, metrics, ...extra };
}

function unconfigured(id, name, message) {
  return provider(id, name, 'unconfigured', [], { detail: message, error: message });
}

function failed(id, name, message) {
  return provider(id, name, 'error', [], { detail: message, error: message });
}

// ---------------------------------------------------------------- Codex / ChatGPT

function collectCodex() {
  const dir = process.env.CODEX_HOME || path.join(HOME, '.codex');
  const authPath = path.join(dir, 'auth.json');
  if (!fs.existsSync(authPath)) {
    return unconfigured('codex', 'Codex', '未找到 ~/.codex/auth.json，请先登录 Codex / ChatGPT');
  }
  let auth;
  try {
    auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
  } catch {
    return failed('codex', 'Codex', '无法解析 ~/.codex/auth.json');
  }
  const token = pick(auth, 'tokens.access_token');
  if (!token) {
    return unconfigured('codex', 'Codex', 'Codex 登录态里没有 access_token，请重新登录');
  }
  const accountId = pick(auth, 'tokens.account_id') || '';
  const res = http('https://chatgpt.com/backend-api/wham/usage', {
    headers: {
      Authorization: `Bearer ${token}`,
      'chatgpt-account-id': accountId,
      'User-Agent': 'codex-cli/0.100.0',
      Accept: 'application/json',
    },
  });
  if (res.status === 401 || res.status === 403) {
    return failed('codex', 'Codex', '登录态已过期，请在 ChatGPT / Codex 中重新登录');
  }
  if (res.status !== 200 || !res.json) {
    return failed('codex', 'Codex', `用量接口返回 HTTP ${res.status}`);
  }

  const j = res.json;
  const plan = pick(j, 'plan_type') || '';
  const email = pick(j, 'email') || '';
  const rateLimit = j.rate_limit || {};
  const metrics = [];

  const primary = rateLimit.primary_window;
  if (primary && num(primary.used_percent) !== undefined) {
    metrics.push(
      percentMetric(
        windowLabel(num(primary.limit_window_seconds)),
        num(primary.used_percent),
        num(primary.reset_at) ? num(primary.reset_at) * 1000 : null,
        rateLimit.allowed === false ? '已达上限' : ''
      )
    );
  }
  const secondary = rateLimit.secondary_window;
  if (secondary && num(secondary.used_percent) !== undefined) {
    metrics.push(
      percentMetric(
        windowLabel(num(secondary.limit_window_seconds)),
        num(secondary.used_percent),
        num(secondary.reset_at) ? num(secondary.reset_at) * 1000 : null
      )
    );
  }

  const credits = j.credits || {};
  const balance = num(credits.balance);
  if (balance !== undefined && (credits.has_credits || balance > 0 || credits.unlimited)) {
    metrics.push(
      textMetric('积分余额', credits.unlimited ? '无限' : String(round(balance, 0)),
        credits.unlimited ? 'unlimited credits' : '')
    );
  }
  if (!metrics.length) {
    return failed('codex', 'Codex', '用量接口没有返回可识别的窗口');
  }

  const headlineMetric = metrics.find((m) => m.kind === 'percent');
  return provider('codex', 'Codex', rateLimit.allowed === false ? 'warn' : 'ok', metrics, {
    account: email,
    plan,
    headline: headlineMetric ? `${Math.round(headlineMetric.remainingPercent)}%` : '',
    detail: rateLimit.allowed === false ? '本周额度已用尽' : 'Codex 订阅额度',
  });
}

// ---------------------------------------------------------------- DeepSeek

function collectDeepSeek(cfg) {
  const apiKey = String(cfg.apiKey || process.env.DEEPSEEK_API_KEY || '').trim();
  if (!apiKey) {
    return unconfigured('deepseek', 'DeepSeek', '未配置 API Key（设置 → DeepSeek）');
  }
  const res = http('https://api.deepseek.com/user/balance', {
    headers: { Authorization: `Bearer ${apiKey}`, Accept: 'application/json' },
  });
  if (res.status === 401) return failed('deepseek', 'DeepSeek', 'API Key 无效或已撤销');
  if (res.status !== 200 || !res.json) return failed('deepseek', 'DeepSeek', `余额接口返回 HTTP ${res.status}`);

  const infos = Array.isArray(res.json.balance_infos) ? res.json.balance_infos : [];
  if (!infos.length) return failed('deepseek', 'DeepSeek', '余额接口没有返回 balance_infos');

  const info = infos[0];
  const total = num(info.total_balance) ?? 0;
  const granted = num(info.granted_balance) ?? 0;
  const topped = num(info.topped_up_balance) ?? 0;
  const currency = info.currency || 'CNY';
  const metrics = [creditMetric('余额', total, currency, `赠金 ${fmtMoney(granted, currency)} · 充值 ${fmtMoney(topped, currency)}`)];
  const available = res.json.is_available !== false;
  return provider('deepseek', 'DeepSeek', available && total > 0 ? 'ok' : 'warn', metrics, {
    headline: fmtMoney(total, currency),
    detail: available ? 'API 余额（按量计费）' : '余额不足，API 不可用',
  });
}

// ---------------------------------------------------------------- Trae

function collectTrae(cfg) {
  let auth;
  try {
    auth = readTraeAuth(cfg.edition || 'cn');
  } catch (e) {
    return unconfigured('trae', 'Trae', e.message);
  }

  let res;
  try {
    res = http(`${auth.host}/trae/api/v2/pay/ide_user_ent_usage`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Cloud-IDE-JWT ${auth.token}`,
      },
      body: JSON.stringify({ require_usage: true, req_source: 1 }),
    });
  } catch (e) {
    return failed('trae', 'Trae', e.message);
  }
  if (res.status === 401 || res.status === 403) {
    return failed('trae', 'Trae', '登录态已过期，请打开 Trae 重新登录后刷新');
  }
  if (res.status !== 200 || !res.json) {
    return failed('trae', 'Trae', `额度接口返回 HTTP ${res.status}`);
  }

  let checkinCredits = null;
  let extraCredits = null;
  try {
    const creditRes = http(`${auth.host}/trae/api/v2/ug/checkin_credits/status`, {
      headers: { Authorization: `Cloud-IDE-JWT ${auth.token}` },
    });
    if (creditRes.status === 200 && creditRes.json) {
      checkinCredits = num(creditRes.json.credits);
      extraCredits = num(creditRes.json.extra_credits);
    }
  } catch {}

  const packs = Array.isArray(res.json.user_entitlement_pack_list)
    ? res.json.user_entitlement_pack_list
    : [];
  if (!packs.length) return failed('trae', 'Trae', '额度接口没有返回套餐');

  const summary = res.json.usage_summary || {};
  const totalCredits = num(summary.total_amount);
  const consumedCredits = num(summary.consumed_amount);
  const remainingCredits = totalCredits != null && consumedCredits != null
    ? Math.max(0, totalCredits - consumedCredits)
    : null;

  const metrics = [];
  const badges = [];
  let soonestExpiry = null;
  let hasQuota = false;

  for (const pack of packs) {
    const base = pack.entitlement_base_info || {};
    const quota = base.quota || {};
    const usage = pack.usage || {};
    const endTime = num(base.end_time) ? num(base.end_time) * 1000 : null;
    if (endTime && (!soonestExpiry || endTime < soonestExpiry)) soonestExpiry = endTime;

    const pairs = [
      ['快速请求', 'premium_model_fast_request_limit', 'premium_model_fast_request_usage'],
      ['慢速请求', 'premium_model_slow_request_limit', 'premium_model_slow_request_usage'],
      ['基础用量', 'basic_usage_limit', 'basic_usage_amount'],
    ];
    for (const [label, limitKey, usedKey] of pairs) {
      const limit = num(quota[limitKey]) ?? 0;
      const used = num(usage[usedKey]) ?? 0;
      if (limit > 0) {
        hasQuota = true;
        metrics.push(
          percentMetric(label, (used / limit) * 100, null, `剩余 ${Math.max(0, limit - used)} / ${limit} 次`)
        );
      }
    }
  }

  if (remainingCredits != null && totalCredits > 0) {
    metrics.push(creditMetric(
      '积分',
      Math.round(remainingCredits),
      '',
      `已用 ${round(consumedCredits, 0)} / ${round(totalCredits, 0)}`
    ));
  }

  const planName = packs.map((p) => p.display_desc).filter(Boolean).join(' / ');
  if (!hasQuota) {
    if (remainingCredits != null && totalCredits > 0) {
      return provider('trae', 'Trae', 'ok', metrics, {
        account: auth.userId,
        headline: String(Math.round(remainingCredits)),
        detail: '积分余额',
      });
    }
    if (checkinCredits != null) {
      const note = (extraCredits ? `签到积分 · 额外 +${extraCredits}` : '签到积分')
        + (soonestExpiry ? ` · ${fmtDate(soonestExpiry)} 到期` : '');
      metrics.push(creditMetric('积分', checkinCredits, '', note));
      return provider('trae', 'Trae', 'ok', metrics, {
        account: auth.userId,
        headline: String(checkinCredits),
        detail: '积分余额',
      });
    }
    metrics.push(textMetric('积分', '—', soonestExpiry ? `免费版 · ${fmtDate(soonestExpiry)} 到期` : '免费版'));
    badges.push('');
    return provider('trae', 'Trae', 'warn', metrics, {
      account: auth.userId,
      headline: planName || '免费',
      detail: '免费版' + (soonestExpiry ? ` · ${fmtDate(soonestExpiry)} 到期` : ''),
    });
  }

  const percent = metrics.find((m) => m.kind === 'percent');
  return provider('trae', 'Trae', 'ok', metrics, {
    account: auth.userId,
    headline: percent ? `${Math.round(percent.remainingPercent)}%` : '',
    detail: planName || 'Trae 套餐额度',
  });
}

// ---------------------------------------------------------------- WorkBuddy


function discoverWorkBuddyToken() {
  let files = [];
  try {
    files = fs
      .readdirSync(WB_AUTH_DIR)
      .filter((f) => f.endsWith('.info'))
      .map((f) => ({ f, mtime: fs.statSync(path.join(WB_AUTH_DIR, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
  } catch {
    return null;
  }
  for (const { f } of files) {
    let raw;
    try {
      raw = JSON.parse(fs.readFileSync(path.join(WB_AUTH_DIR, f), 'utf8'));
    } catch {
      continue;
    }
    const candidates = [
      raw?.auth?.accessToken,
      raw?.account?.accessToken,
      ...(Array.isArray(raw?.accounts) ? raw.accounts.map((a) => a?.accessToken) : []),
    ];
    const token = candidates.find((t) => typeof t === 'string' && t.length > 20);
    if (!token) continue;
    return {
      token,
      uid: String(raw?.account?.uid || raw?.uid || ''),
      name: String(raw?.account?.nickname || ''),
      file: f,
    };
  }
  return null;
}


// ---------------------------------------------------------------- WorkBuddy 本机密钥

const WB_AUTH_DIR = path.join(
  HOME,
  'Library',
  'Application Support',
  'CodeBuddyExtension',
  'Data',
  'Public',
  'auth'
);
const WB_KEY_CACHE = path.join(path.dirname(CONFIG_PATH), 'workbuddy-at-rest');
const WB_ELECTRON = '/Applications/WorkBuddy.app/Contents/MacOS/Electron';

function encodeU32(value) {
  const buffer = Buffer.allocUnsafe(4);
  buffer.writeUInt32BE(value);
  return buffer;
}

function lengthPrefixed(value) {
  const buffer = Buffer.from(value, 'utf8');
  return Buffer.concat([encodeU32(buffer.length), buffer]);
}

function workbuddyAad(keyId, suite, framing) {
  const framingName = framing === 'file' ? 'WBEF1' : 'WBEV1';
  const framingByte = framing === 'file' ? 1 : 2;
  return Buffer.concat([
    Buffer.from('WB-AAD\0', 'ascii'),
    Buffer.from([1]),
    lengthPrefixed(framingName),
    lengthPrefixed('sym-v1'),
    encodeU32(suite),
    lengthPrefixed(keyId),
    Buffer.from([framingByte]),
    Buffer.from([0]),
    Buffer.from([0]),
  ]);
}

function openWorkbuddyEnvelope(envelope, key, framing) {
  const parsed = JSON.parse(Buffer.from(envelope, 'base64').toString('utf8'));
  const keyId = crypto.createHash('sha256').update(key).digest('hex').slice(0, 16);
  if (parsed.keyId !== keyId) throw new Error('key id mismatch');
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    key,
    Buffer.from(parsed.nonce, 'base64'),
    { authTagLength: 16 }
  );
  decipher.setAAD(workbuddyAad(parsed.keyId, parsed.suite, framing));
  decipher.setAuthTag(Buffer.from(parsed.authTag, 'base64'));
  return Buffer.concat([
    decipher.update(Buffer.from(parsed.ciphertext, 'base64')),
    decipher.final(),
  ]);
}

function probeWorkBuddyKey() {
  const helper = path.join(__dirname, 'workbuddy-key');
  if (!fs.existsSync(helper) || !fs.existsSync(WB_ELECTRON)) return null;
  const env = { ...process.env, ELECTRON_RUN_AS_NODE: '1' };
  let result;
  try {
    result = spawnSync(WB_ELECTRON, [helper], {
      timeout: 15000,
      encoding: 'utf8',
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch {
    return null;
  }
  const output = String(result.stdout || '');
  const match = output.match(/AQBKEY:(\{[\s\S]*\})/);
  if (!match) return null;
  try {
    const payload = JSON.parse(match[1]);
    const raw = Buffer.from(payload.atRestSecretKey || '', 'base64');
    if (raw.length !== 32) return null;
    return payload.atRestSecretKey;
  } catch (e) {
    return null;
  }
}

function readCachedWorkBuddyKey() {
  try {
    const value = fs.readFileSync(WB_KEY_CACHE, 'utf8').trim();
    if (Buffer.from(value, 'base64').length === 32) return value;
  } catch {}
  return null;
}

function latestWorkBuddySnapshot() {
  try {
    const files = fs
      .readdirSync(WB_AUTH_DIR)
      .filter((f) => f.endsWith('.info'))
      .map((f) => ({ f, mtime: fs.statSync(path.join(WB_AUTH_DIR, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
    for (const { f } of files) {
      try {
        const raw = JSON.parse(fs.readFileSync(path.join(WB_AUTH_DIR, f), 'utf8'));
        if (raw?.auth?.accessToken?.envelope && raw?.account?.uid) return raw;
      } catch {}
    }
  } catch {}
  return null;
}

function workBuddyAutoCredential() {
  const snapshot = latestWorkBuddySnapshot();
  if (!snapshot) return null;
  const tryDecrypt = (secret) => {
    if (!secret) return null;
    try {
      const key = crypto.createHash('sha256').update(secret, 'utf8').digest();
      const token = openWorkbuddyEnvelope(snapshot.auth.accessToken.envelope, key, 'field')
        .toString('utf8')
        .trim();
      if (!token || token.length < 40) return null;
      return { token, uid: String(snapshot.account.uid || '') };
    } catch (e) {
      return null;
    }
  };
  let secret = readCachedWorkBuddyKey();
  let credential = tryDecrypt(secret);
  if (!credential) {
    secret = probeWorkBuddyKey();
    credential = tryDecrypt(secret);
    if (credential && secret) {
      try {
        fs.mkdirSync(path.dirname(WB_KEY_CACHE), { recursive: true });
        fs.writeFileSync(WB_KEY_CACHE, secret + '\n', { mode: 0o600 });
      } catch {}
    }
  }
  return credential;
}

function collectWorkBuddy(cfg) {
  let token = String(cfg.token || process.env.WORKBUDDY_TOKEN || '').trim().replace(/^Bearer\s+/i, '');
  let uid = String(cfg.uid || '').trim();
  let source = 'config';
  const auto = workBuddyAutoCredential();
  if (auto) {
    token = auto.token;
    uid = auto.uid;
    source = 'auto';
  } else if (!token) {
    const found = discoverWorkBuddyToken();
    if (found) {
      token = found.token;
      uid = uid || found.uid;
      source = found.file;
    }
  }
  if (!token) {
    return unconfigured(
      'workbuddy',
      'WorkBuddy',
      '未找到可用的登录态（新版把 token 加密了），请在设置里粘贴 token'
    );
  }

  const res = http('https://www.workbuddy.cn/billing/meter/get-user-resource-summary', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'X-User-Id': uid,
      'X-Client-Platform': 'web',
      Accept: 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      Origin: 'https://www.workbuddy.cn',
      Referer: 'https://www.workbuddy.cn/profile/plans-usage',
    },
    body: '{}',
  });
  const code = res.json?.code;
  if (res.status === 401 || res.status === 403 || code === 10085) {
    const hint = source === 'config'
      ? 'Token 已失效，请更新'
      : 'token 已过期，请更新';
    return failed('workbuddy', 'WorkBuddy', hint);
  }
  if (res.status !== 200 || !res.json) {
    return failed('workbuddy', 'WorkBuddy', `积分接口返回 HTTP ${res.status}`);
  }

  const packages =
    res.json?.data?.Packages ||
    res.json?.data?.data?.Packages ||
    res.json?.data?.packages ||
    res.json?.data?.data?.packages ||
    [];
  if (!Array.isArray(packages) || !packages.length) {
    const msg = res.json?.msg || res.json?.message || '积分接口没有返回套餐明细';
    return failed('workbuddy', 'WorkBuddy', msg);
  }

  const totalKeys = ['CycleCapacitySizePrecise', 'CycleCapacitySize', 'CycleTotalCapacity', 'CapacitySizePrecise', 'CapacitySize'];
  const remainKeys = ['CycleCapacityRemainPrecise', 'CycleCapacityRemain', 'CycleRemainCapacity', 'CapacityRemainPrecise', 'CapacityRemain'];
  let total = 0;
  let remaining = 0;
  let soonest = null;
  for (const p of packages) {
    const t = num(pick(p, ...totalKeys)) ?? 0;
    const r = num(pick(p, ...remainKeys)) ?? 0;
    total += t;
    remaining += r;
    const exp = pick(p, 'ExpireTime', 'expireTime', 'ExpiredTime');
    const ts = num(exp) ? Number(exp) * (Number(exp) < 1e12 ? 1000 : 1) : null;
    if (r > 0 && ts && (!soonest || ts < soonest)) soonest = ts;
  }

  const metrics = [
    creditMetric('剩余积分', Math.floor(remaining), '', `共 ${round(total, 0)}${soonest ? ` · 最近到期 ${fmtDate(soonest)}` : ''}`),
  ];
  return provider('workbuddy', 'WorkBuddy', remaining > 0 ? 'ok' : 'warn', metrics, {
    account: uid,
    headline: `${Math.floor(remaining)}`,
    detail: source === 'auto' ? 'WorkBuddy 积分（自动）' : `WorkBuddy 积分（${source.split('.')[0]}）`,
  });
}

// ---------------------------------------------------------------- OpenCode

function cookieHeader(cookie) {
  const value = String(cookie || '').trim();
  if (!value) return '';
  if (value.includes('=')) return value;
  return `__Host-console_session=${value}`;
}

function extractMeters(json) {
  const out = [];
  const seen = new Set();
  const visit = (node, keyPath, depth) => {
    if (!node || depth > 5 || out.length >= 4) return;
    if (Array.isArray(node)) {
      node.forEach((v, i) => visit(v, `${keyPath}[${i}]`, depth + 1));
      return;
    }
    if (typeof node !== 'object') return;
    const usedPercent = num(pick(node, 'used_percent', 'usedPercent', 'usage_percent', 'usagePercent', 'percent'));
    const limit = num(pick(node, 'limit', 'total', 'quota', 'max'));
    const used = num(pick(node, 'used', 'usage', 'consumed'));
    const resetRaw = pick(node, 'reset_at', 'resets_at', 'resetAt', 'resetsAt', 'next_reset_at', 'period_end');
    let reset = null;
    if (resetRaw !== undefined) {
      const n = Number(resetRaw);
      if (Number.isFinite(n)) reset = n < 1e12 ? n * 1000 : n;
      else {
        const parsed = Date.parse(String(resetRaw));
        if (!Number.isNaN(parsed)) reset = parsed;
      }
    }
    let pct = usedPercent;
    if (pct === undefined && limit && used !== undefined) pct = (used / limit) * 100;
    if (pct !== undefined && !seen.has(keyPath)) {
      seen.add(keyPath);
      let label;
      if (/(?:five|5h|rolling|session)/i.test(keyPath)) label = '5 小时';
      else if (/(?:week|7d)/i.test(keyPath)) label = '本周';
      else if (/(?:month|30d)/i.test(keyPath)) label = '本月';
      else if (reset) {
        const hours = (reset - Date.now()) / 3600000;
        label = hours <= 6 ? '5 小时' : hours <= 8 * 24 ? '本周' : '本月';
      } else label = `额度${out.length + 1}`;
      out.push(percentMetric(label, pct, reset));
    }
    for (const [k, v] of Object.entries(node)) {
      if (v && typeof v === 'object') visit(v, `${keyPath}.${k}`, depth + 1);
    }
  };
  visit(json, 'root', 0);
  return out;
}

function collectOpenCode(cfg) {
  const mode = String(cfg.mode || '').toLowerCase();
  const apiKey = String(cfg.apiKey || process.env.OPENCODE_GO_API_KEY || '').trim();
  const cookie = String(cfg.cookie || '').trim();

  if (apiKey && mode !== 'zen') {
    const res = http('https://opencode.ai/zen/go/v1/usage', {
      headers: { Authorization: `Bearer ${apiKey}`, Accept: 'application/json' },
    });
    if (res.status === 401 || res.status === 403) {
      return failed('opencode', 'OpenCode', 'API Key 无效或已过期');
    }
    if (res.status === 200 && res.json) {
      const meters = [];
      const windows = res.json.usage;
      if (windows && typeof windows === 'object') {
        for (const [key, label] of [['rolling', '5 小时'], ['weekly', '本周'], ['monthly', '本月']]) {
          const item = windows[key];
          if (!item) continue;
          const used = num(item.percent) ?? 0;
          let reset = null;
          if (item.resetsAt) {
            const parsed = Date.parse(String(item.resetsAt));
            if (!Number.isNaN(parsed)) reset = parsed;
          }
          meters.push(percentMetric(label, used, reset));
        }
      }
      if (!meters.length) meters.push(...extractMeters(res.json));
      if (meters.length) {
        const first = meters[0];
        return provider('opencode', 'OpenCode', 'ok', meters, {
          headline: `${Math.round(first.remainingPercent)}%`,
          detail: 'OpenCode Go 订阅额度',
        });
      }
      return provider('opencode', 'OpenCode', 'warn', [], {
        headline: '已连接',
        detail: 'API Key 可用，但 usage 接口未返回可识别的窗口',
        error: 'usage 响应格式未识别',
      });
    }
    return failed('opencode', 'OpenCode', `用量接口返回 HTTP ${res.status}`);
  }

  if (cookie && mode !== 'go') {
    const headers = { Cookie: cookieHeader(cookie), Accept: 'application/json' };
    const orgIdCfg = String(cfg.workspaceId || '').trim();
    let orgId = orgIdCfg;
    if (!orgId) {
      const orgs = http('https://opencode.ai/console/api/orgs', { headers });
      if (orgs.status === 401 || orgs.status === 403) {
        return failed('opencode', 'OpenCode', 'Cookie 已失效，请重新从浏览器复制');
      }
      const list = Array.isArray(orgs.json?.data) ? orgs.json.data : Array.isArray(orgs.json) ? orgs.json : [];
      orgId = String(list[0]?.id || list[0]?.orgId || '');
    }
    if (!orgId) return unconfigured('opencode', 'OpenCode', 'Cookie 有效但找不到 workspace，请填写 workspaceId');

    const metrics = [];
    const billing = http('https://opencode.ai/console/api/billing/status', {
      headers: { ...headers, 'x-org-id': orgId },
    });
    if (billing.status === 200 && billing.json) {
      const micro = num(pick(billing.json, 'balanceMicroCents', 'data.balanceMicroCents'));
      if (micro !== undefined) {
        metrics.push(creditMetric('Zen 余额', micro / 1e8, 'USD', `可用额度 ${fmtMoney(micro / 1e8, 'USD')}`));
      }
    }
    const go = http('https://opencode.ai/console/api/go/status', {
      headers: { ...headers, 'x-org-id': orgId },
    });
    if (go.status === 200 && go.json) metrics.push(...extractMeters(go.json));

    if (!metrics.length) return failed('opencode', 'OpenCode', 'Console 接口没有返回余额或额度');
    const first = metrics.find((m) => m.kind === 'percent') || metrics[0];
    return provider('opencode', 'OpenCode', 'ok', metrics, {
      account: orgId,
      headline: first.kind === 'credit' ? first.headlineValue : `${Math.round(first.remainingPercent)}%`,
      detail: 'OpenCode Console（Cookie）',
    });
  }

  return unconfigured(
    'opencode',
    'OpenCode',
    '未配置：可填 OpenCode Go 的 API Key，或 console cookie + workspaceId'
  );
}


// ---------------------------------------------------------------- 每日签到

function checkinTrae(cfg) {
  let auth;
  try {
    auth = readTraeAuth(cfg.edition || 'cn');
  } catch (e) {
    return { provider: 'trae', status: 'failed', message: e.message || '未找到 Trae 登录态' };
  }
  // x-device-id 必须是客户端真实注册过的设备号；自己 hash 的号会稳定返回 9074。
  const deviceId = auth.deviceId;
  if (!deviceId) {
    return {
      provider: 'trae',
      status: 'failed',
      message: '未找到 Trae 设备号，请先打开 Trae 登录一次',
    };
  }
  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Cloud-IDE-JWT ${auth.token}`,
    'X-User-Region': 'CN',
    'User-Agent': 'Trae/2.1.0',
    'x-device-id': deviceId,
    'x-device-type': 'Windows',
    'x-os-version': '10.0.19045',
    'x-app-version': '2.1.0',
  };
  const request = (endpoint, body) => http(`${auth.host}${endpoint}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body || {}),
  });

  let status;
  try {
    status = request('/trae/api/v2/ug/checkin_credits/status', { req_source: 1 });
  } catch (e) {
    return { provider: 'trae', status: 'failed', message: e.message };
  }
  if (status.status === 401 || status.status === 403) {
    return { provider: 'trae', status: 'failed', message: '登录态已失效，请打开 Trae 重新登录' };
  }
  if (!status.json) {
    return { provider: 'trae', status: 'failed', message: `状态接口 HTTP ${status.status}` };
  }
  if (status.json.checked_in === true || status.json.did_checked_in === true) {
    return {
      provider: 'trae',
      status: 'already',
      message: '今日已签到',
      points: num(status.json.credits) ?? null,
    };
  }
  if (status.json.enable === false) {
    return { provider: 'trae', status: 'inactive', message: '当前未开放签到' };
  }

  let claim;
  try {
    claim = request('/trae/api/v2/ug/checkin_credits/claim', { req_source: 1 });
  } catch (e) {
    return { provider: 'trae', status: 'failed', message: e.message };
  }
  const code = claim.json?.code;
  if (code === 9095) {
    return { provider: 'trae', status: 'already', message: '今日已签到' };
  }
  if (code !== 0) {
    const hint = code === 9074
      ? '设备号未注册（9074），请先打开 Trae 登录一次后重试'
      : `领取失败 code=${code ?? claim.status}`;
    return { provider: 'trae', status: 'failed', message: hint };
  }
  const points = num(claim.json?.data?.points);
  return {
    provider: 'trae',
    status: 'ok',
    message: '签到成功',
    points: points ?? num(status.json.credits) ?? null,
  };
}

function checkinWorkBuddy(cfg) {
  let token = '';
  try {
    const auto = workBuddyAutoCredential();
    if (auto) token = auto.token;
  } catch {}
  if (!token) token = String(cfg.token || process.env.WORKBUDDY_TOKEN || '').trim().replace(/^Bearer\s+/i, '');
  if (!token) {
    return { provider: 'workbuddy', status: 'failed', message: '未找到 WorkBuddy 登录态' };
  }
  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
    Origin: 'https://www.codebuddy.cn',
    Referer: 'https://www.codebuddy.cn/',
  };
  const request = (endpoint, body) => http(`https://www.codebuddy.cn/v2/billing/meter/${endpoint}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body || {}),
  });

  let status;
  try {
    status = request('checkin-activity-status', {});
  } catch (e) {
    return { provider: 'workbuddy', status: 'failed', message: e.message };
  }
  if (status.status === 401 || status.status === 403) {
    return { provider: 'workbuddy', status: 'failed', message: '登录态已失效，请打开 WorkBuddy 重新登录' };
  }
  const data = status.json?.data || {};
  if (data.today_checked_in === true) {
    return {
      provider: 'workbuddy',
      status: 'already',
      message: '今日已签到',
      points: num(data.today_credit) ?? null,
      streak: num(data.streak_days) ?? null,
    };
  }
  if (data.active === false) {
    return { provider: 'workbuddy', status: 'inactive', message: '当前未开放签到活动' };
  }

  let claim;
  try {
    claim = request('daily-checkin', {});
  } catch (e) {
    return { provider: 'workbuddy', status: 'failed', message: e.message };
  }
  const code = claim.json?.code;
  if (code === 10001) {
    return { provider: 'workbuddy', status: 'already', message: '今日已签到' };
  }
  if (code !== 0) {
    return {
      provider: 'workbuddy',
      status: 'failed',
      message: `领取失败 code=${code ?? claim.status}`,
    };
  }
  const claimed = claim.json?.data || {};
  return {
    provider: 'workbuddy',
    status: 'ok',
    message: '签到成功',
    points: num(claimed.today_credit) ?? num(data.daily_credit) ?? null,
    streak: num(claimed.streak_days) ?? num(data.streak_days) ?? null,
  };
}

function localDateKey() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function writeCheckinConfig(results) {
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    const checkin = raw.checkin && typeof raw.checkin === 'object' ? raw.checkin : {};
    const failed = results.some((r) => r.status === 'failed');
    const summary = results.map((r) => {
      const name = r.provider === 'trae' ? 'Trae' : 'WorkBuddy';
      if (r.status === 'ok') return `${name} +${r.points ?? 100}`;
      if (r.status === 'already') return `${name} 已签`;
      if (r.status === 'inactive') return `${name} 未开放`;
      return `${name} 失败`;
    }).join(' · ');
    const workbuddy = results.find((r) => r.provider === 'workbuddy');
    checkin.lastAttempt = new Date().toISOString();
    if (!failed) checkin.lastDate = localDateKey();
    checkin.lastSummary = summary || '今日已签到';
    if (workbuddy && workbuddy.streak != null) checkin.workbuddyStreak = workbuddy.streak;
    raw.checkin = checkin;
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(raw, null, 2) + '\n', { mode: 0o600 });
  } catch (e) {
    process.stderr.write(`write config failed: ${e.message}\n`);
  }
}

function runCheckin(only, options = {}) {
  const cfgCheckin = CONFIG.checkin || {};
  if (options.scheduled) {
    if (cfgCheckin.auto === false) {
      process.stdout.write(JSON.stringify({ schema: 1, skipped: 'disabled' }) + '\n');
      return;
    }
    if (cfgCheckin.lastDate === localDateKey()) {
      process.stdout.write(JSON.stringify({ schema: 1, skipped: 'already' }) + '\n');
      return;
    }
    const scheduledHour = Math.min(23, Math.max(0, Number(cfgCheckin.hour ?? 9)));
    if (new Date().getHours() < scheduledHour) {
      process.stdout.write(JSON.stringify({ schema: 1, skipped: 'before-schedule' }) + '\n');
      return;
    }
  }

  const results = [];
  const map = { trae: checkinTrae, workbuddy: checkinWorkBuddy };
  for (const [id, fn] of Object.entries(map)) {
    if (only && !only.includes(id)) continue;
    try {
      results.push(fn(CONFIG.providers[id] || {}));
    } catch (e) {
      results.push({ provider: id, status: 'failed', message: e.message || String(e) });
    }
  }
  if (options.writeConfig) writeCheckinConfig(results);
  process.stdout.write(JSON.stringify({
    schema: 1,
    updatedAt: new Date().toISOString(),
    results,
  }) + '\n');
}

// ---------------------------------------------------------------- main

const COLLECTORS = {
  codex: collectCodex,
  deepseek: collectDeepSeek,
  opencode: collectOpenCode,
  trae: collectTrae,
  workbuddy: collectWorkBuddy,
};

const NAMES = {
  codex: 'Codex',
  deepseek: 'DeepSeek',
  opencode: 'OpenCode',
  trae: 'Trae',
  workbuddy: 'WorkBuddy',
};

function main() {
  const onlyArg = process.argv.find((a) => a.startsWith('--only='));
  const only = onlyArg ? onlyArg.slice('--only='.length).split(',').map((s) => s.trim()) : null;
  if (process.argv.includes('--checkin')) {
    runCheckin(only, {
      scheduled: process.argv.includes('--scheduled'),
      writeConfig: process.argv.includes('--write-config'),
    });
    return;
  }
  const results = [];

  for (const [id, fn] of Object.entries(COLLECTORS)) {
    if (only && !only.includes(id)) continue;
    const cfg = CONFIG.providers[id] || {};
    if (cfg.enabled === false) {
      results.push(provider(id, NAMES[id], 'disabled', [], { detail: '已停用' }));
      continue;
    }
    try {
      const result = fn(cfg);
      results.push({ ...result, name: result.name || NAMES[id] });
    } catch (e) {
      results.push(failed(id, NAMES[id], e.message || String(e)));
    }
  }

  const output = {
    schema: 1,
    updatedAt: new Date().toISOString(),
    providers: results,
  };
  process.stdout.write(
    JSON.stringify(output, null, process.argv.includes('--pretty') ? 2 : 0) + '\n'
  );
}

main();
