/**
 * Trae (CN / SOLO) 本地登录态解密。
 *
 * 算法与实现移植自 MIT 许可项目 dsh-trae-api / Trae Local API
 * (https://github.com/Wang-JQ77/dsh-trae-api, Copyright (c) 2026 Trae Local API)。
 * 仅保留读取 storage.json 所需的最小逻辑，便于在本工具里复用。
 *
 * storage.json 中的 "iCubeAuthInfo://icube.cloudide" 为 tc 格式：
 *   [6B Header][32B Random][N AES-128-CBC 密文]
 *   明文 = [64B SHA-512 校验][JSON]
 *   key/iv 由 SHA-512(random) + salt 再做一次 SHA-512 派生。
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SALT_A = Uint8Array.from([
  82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
  124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
  84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
  8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
]);

const SALT_B = Uint8Array.from([
  31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
  96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
  160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
  23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
]);

const SALT_C = Uint8Array.from([
  191, 192, 216, 250, 122, 246, 220, 97, 31, 254, 98, 27, 8, 72, 71, 176,
  135, 99, 96, 18, 127, 101, 203, 104, 211, 102, 191, 125, 37, 72, 150, 156,
  51, 229, 121, 35, 17, 153, 141, 177, 110, 131, 150, 128, 172, 255, 254, 6,
  18, 140, 55, 62, 236, 249, 135, 64, 135, 12, 117, 4, 89, 149, 168, 209,
]);

const SALT_D = Uint8Array.from([
  246, 204, 26, 232, 232, 70, 129, 109, 223, 146, 169, 242, 23, 241, 105, 145,
  50, 196, 165, 42, 254, 120, 3, 54, 244, 207, 209, 85, 53, 6, 138, 106,
  175, 148, 31, 204, 186, 186, 165, 182, 87, 142, 49, 10, 39, 110, 26, 154,
  86, 56, 173, 125, 18, 64, 198, 225, 99, 99, 83, 82, 191, 134, 76, 170,
]);

function xorSalts(a, b) {
  const out = new Uint8Array(a.length);
  for (let i = 0; i < a.length; i += 1) out[i] = a[i] ^ b[i];
  return out;
}

function detectEncType(header) {
  if (header[0] === 0x74 && header[1] === 0x63 && header[2] === 0x05 && header[3] === 0x10) {
    return 'AES';
  }
  if (header[0] === 18 && header[1] === 57 && header[2] === 32 && header[3] === 32) {
    return 'AES_PRIVATE';
  }
  return 'UNKNOWN';
}

function deriveKeyAndIV(randomBytes, encType) {
  const salt = encType === 'AES_PRIVATE' ? xorSalts(SALT_C, SALT_D) : xorSalts(SALT_A, SALT_B);
  const hashOfRandom = crypto.createHash('sha512').update(Buffer.from(randomBytes)).digest();
  const finalHash = crypto
    .createHash('sha512')
    .update(Buffer.concat([hashOfRandom, Buffer.from(salt)]))
    .digest();
  return { key: finalHash.subarray(0, 16), iv: finalHash.subarray(16, 32) };
}

function decryptStorageValue(base64Value) {
  const buffer = Buffer.from(base64Value, 'base64');
  const header = buffer.subarray(0, 6);
  const randomBytes = buffer.subarray(6, 38);
  const encrypted = buffer.subarray(38);
  const encType = detectEncType(header);
  if (encType === 'UNKNOWN') throw new Error('未知的 Trae 加密格式');
  const { key, iv } = deriveKeyAndIV(randomBytes, encType);
  const decipher = crypto.createDecipheriv('aes-128-cbc', key, iv);
  const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
  const storedHash = decrypted.subarray(0, 64);
  const plaintext = decrypted.subarray(64);
  const computed = crypto.createHash('sha512').update(plaintext).digest();
  if (!storedHash.equals(computed)) throw new Error('Trae 登录态校验失败');
  return plaintext.toString('utf8');
}

const DATA_DIRS = {
  cn: () => path.join(os.homedir(), 'Library', 'Application Support', 'Trae CN', 'User'),
  solo: () => path.join(os.homedir(), 'Library', 'Application Support', 'TRAE SOLO CN', 'User'),
  sg: () => path.join(os.homedir(), 'Library', 'Application Support', 'Trae', 'User'),
  'solo-sg': () => path.join(os.homedir(), 'Library', 'Application Support', 'TRAE SOLO', 'User'),
};

function findStorage(edition) {
  const dirs = [];
  if (edition && DATA_DIRS[edition]) dirs.push(DATA_DIRS[edition]());
  for (const fn of Object.values(DATA_DIRS)) dirs.push(fn());
  for (const dir of dirs) {
    const p = path.join(dir, 'globalStorage', 'storage.json');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

/**
 * 读取并解密 Trae 登录态。
 * @returns {{token:string, refreshToken:string, expiredAt:string|null, userId:string, host:string, edition:string, storagePath:string}}
 */
function readTraeAuth(edition = 'cn') {
  const storagePath = findStorage(edition);
  if (!storagePath) {
    throw new Error('未找到 Trae 的 storage.json，请先安装并登录 Trae（CN / SOLO）');
  }
  const storage = JSON.parse(fs.readFileSync(storagePath, 'utf8'));
  const raw = storage['iCubeAuthInfo://icube.cloudide'];
  if (!raw) throw new Error('storage.json 中没有登录信息，请先登录 Trae');
  const data = String(raw).trim().startsWith('{')
    ? JSON.parse(raw)
    : JSON.parse(decryptStorageValue(raw));
  if (!data.token) throw new Error('Trae 登录态缺少 token');
  return {
    token: data.token,
    refreshToken: data.refreshToken || '',
    expiredAt: data.expiredAt || null,
    userId: String(data.userId || ''),
    host: data.host || 'https://api.trae.cn',
    edition,
    storagePath,
  };
}

module.exports = { readTraeAuth, decryptStorageValue, DATA_DIRS };
