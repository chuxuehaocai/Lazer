const dns = require('node:dns').promises;
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const MAX_REQUEST_BYTES = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const FORBIDDEN_HEADERS = new Set([
  'host',
  'content-length',
  'connection',
  'transfer-encoding',
  'x-real-ip',
  'x-forwarded-for',
]);

// Same selection as api-enhanced `generateRandomChineseIP`: weight each CIDR
// by how many addresses it holds, then pick one address inside it. The music
// service treats X-Real-IP as the client, so a Vercel egress address is not
// usable. One address is kept for the life of this instance.
let chinaForwardIp;

function ipToInt(ip) {
  const parts = ip.split('.').map(Number);
  return (((parts[0] << 24) >>> 0) + (parts[1] << 16) + (parts[2] << 8) + parts[3]) >>> 0;
}

function intToIp(value) {
  return [
    (value >>> 24) & 0xff,
    (value >>> 16) & 0xff,
    (value >>> 8) & 0xff,
    value & 0xff,
  ].join('.');
}

function loadChinaRanges() {
  const file = path.join(__dirname, 'china_ip_ranges.txt');
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const ranges = [];
  let total = 0;
  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const [ip, prefixText] = line.split('/');
    const prefix = Number(prefixText);
    if (!net.isIPv4(ip) || prefix < 1 || prefix > 32) continue;
    const start = (ipToInt(ip) & ((0xffffffff << (32 - prefix)) >>> 0)) >>> 0;
    const end = (start | (~((0xffffffff << (32 - prefix)) >>> 0) >>> 0)) >>> 0;
    const count = end - start + 1;
    ranges.push({ start, end, count });
    total += count;
  }
  ranges.sort((a, b) => b.count - a.count);
  return { ranges, total };
}

function generateRandomChineseIP() {
  let ranges;
  let total = 0;
  try {
    ({ ranges, total } = loadChinaRanges());
  } catch {
    ranges = [];
  }
  if (!total) {
    const octet = (min, max) => min + Math.floor(Math.random() * (max - min + 1));
    return `116.${octet(25, 94)}.${octet(1, 255)}.${octet(1, 255)}`;
  }
  let offset = Math.floor(Math.random() * total);
  let chosen = ranges[ranges.length - 1];
  for (const range of ranges) {
    if (offset < range.count) {
      chosen = range;
      break;
    }
    offset -= range.count;
  }
  const span = chosen.end - chosen.start + 1;
  return intToIp((chosen.start + Math.floor(Math.random() * span)) >>> 0);
}

function forwardedChinaIp() {
  chinaForwardIp ??= generateRandomChineseIP();
  return chinaForwardIp;
}

function matchesDomain(host, rule) {
  const normalized = String(rule || '').toLowerCase();
  const value = host.toLowerCase();
  if (normalized.startsWith('*.')) {
    const suffix = normalized.slice(2);
    return value === suffix || value.endsWith(`.${suffix}`);
  }
  return value === normalized;
}

function isPrivateAddress(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168);
  }
  if (net.isIPv6(address)) {
    const value = address.toLowerCase();
    return value === '::1' || value === '::' || value.startsWith('fc') ||
      value.startsWith('fd') || value.startsWith('fe80:');
  }
  return true;
}

async function assertPublicHost(host) {
  if (net.isIP(host)) {
    if (isPrivateAddress(host)) throw new Error('Private network target');
    return;
  }
  const records = await dns.lookup(host, { all: true, verbatim: true });
  if (!records.length || records.some((record) => isPrivateAddress(record.address))) {
    throw new Error('Private network target');
  }
}

async function readBody(response) {
  const reader = response.body?.getReader();
  if (!reader) return '';
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_RESPONSE_BYTES) throw new Error('Response too large');
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'POST required' });
    return;
  }

  try {
    const raw = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : req.body;
    const input = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!input || typeof input !== 'object') throw new Error('Invalid request');
    const target = new URL(String(input.url || ''));
    if (target.protocol !== 'https:' || target.username || target.password) {
      throw new Error('Only public HTTPS targets are allowed');
    }
    const domains = Array.isArray(input.domains) ? input.domains : [];
    if (!domains.some((rule) => matchesDomain(target.hostname, rule))) {
      throw new Error('Target is outside plugin permissions');
    }
    await assertPublicHost(target.hostname);

    const method = String(input.method || 'GET').toUpperCase();
    if (!['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'].includes(method)) {
      throw new Error('Unsupported HTTP method');
    }
    const body = input.body == null ? undefined : String(input.body);
    if (body && Buffer.byteLength(body) > MAX_REQUEST_BYTES) {
      throw new Error('Request too large');
    }
    const headers = {};
    for (const [name, value] of Object.entries(input.headers || {})) {
      const lower = name.toLowerCase();
      if (FORBIDDEN_HEADERS.has(lower) || typeof value !== 'string') continue;
      headers[name] = value;
    }
    const clientIp = forwardedChinaIp();
    headers['X-Real-IP'] = clientIp;
    headers['X-Forwarded-For'] = clientIp;

    const upstream = await fetch(target, {
      method,
      headers,
      body: method === 'GET' || method === 'HEAD' ? undefined : body,
      redirect: 'manual',
    });
    const responseHeaders = {};
    for (const [name, value] of upstream.headers.entries()) {
      if (name !== 'set-cookie') responseHeaders[name] = value;
    }
    const cookies = typeof upstream.headers.getSetCookie === 'function'
      ? upstream.headers.getSetCookie()
      : (upstream.headers.get('set-cookie') || '');
    if (cookies) responseHeaders['set-cookie'] = Array.isArray(cookies) ? cookies.join('\n') : cookies;

    res.status(200).json({
      status: upstream.status,
      headers: responseHeaders,
      body: await readBody(upstream),
    });
  } catch (error) {
    res.status(400).json({ error: String(error.message || 'Proxy request failed') });
  }
};
