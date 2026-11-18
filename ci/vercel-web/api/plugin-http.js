const dns = require('node:dns').promises;
const net = require('node:net');
const { forwardedIp, normalizeCountry } = require('./forwarded-ip');

const MAX_REQUEST_BYTES = 2 * 1024 * 1024;
const MAX_ENVELOPE_BYTES = 3 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 3 * 1024 * 1024;
// Vercel has a 4.5 MB function payload limit. JSON escaping can make a text
// response substantially larger than the upstream bytes, so bound both.
const MAX_JSON_RESPONSE_BYTES = 4 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 25000;
const FORBIDDEN_HEADERS = new Set([
  'host',
  'content-length',
  'connection',
  'transfer-encoding',
  'x-real-ip',
  'x-forwarded-for',
  'forwarded',
  'x-client-ip',
  'true-client-ip',
  'cf-connecting-ip',
]);

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
    return a === 10 || a === 127 || a === 0 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && (b === 168 || b === 0)) ||
      (a === 198 && (b === 18 || b === 19));
  }
  if (net.isIPv6(address)) {
    const value = address.toLowerCase();
    // Only global unicast. This also rejects mapped private IPv4, link local,
    // loopback, multicast and translation prefixes.
    return !/^[23][0-9a-f]{3}:/.test(value);
  }
  return true;
}

async function assertPublicHost(host, lookup) {
  host = host.replace(/^\[|\]$/g, '');
  if (net.isIP(host)) {
    if (isPrivateAddress(host)) throw new Error('Private network target');
    return;
  }
  const records = await lookup(host, { all: true, verbatim: true });
  if (!records.length || records.some((record) => isPrivateAddress(record.address))) {
    throw new Error('Private network target');
  }
}

async function readBody(response) {
  const reader = response.body?.getReader();
  if (!reader) return '';
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_RESPONSE_BYTES) throw new Error('Response too large');
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function createHandler({ fetch = globalThis.fetch, lookup = dns.lookup, timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
  return async function handler(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method === 'OPTIONS') {
      res.status(204).end();
      return;
    }
    if (req.method !== 'POST') {
      res.status(405).json({ error: 'POST required' });
      return;
    }

    const controller = new AbortController();
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => {
        const error = new Error('Upstream request timed out');
        error.name = 'TimeoutError';
        reject(error);
        controller.abort(error);
      }, timeoutMs);
    });
    const request = async () => {
      const raw = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : req.body;
      if (typeof raw === 'string' && Buffer.byteLength(raw) > MAX_ENVELOPE_BYTES) {
        throw new Error('Request too large');
      }
      const input = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid request');
      const country = normalizeCountry(input.egressCountry);
      if (typeof input.url !== 'string' || input.url.length > 8192) throw new Error('Invalid URL');
      const target = new URL(String(input.url || ''));
      if (target.protocol !== 'https:' || target.username || target.password) {
        throw new Error('Only public HTTPS targets are allowed');
      }
      const domains = Array.isArray(input.domains) ? input.domains : [];
      if (domains.length > 128) throw new Error('Too many plugin domains');
      if (!domains.some((rule) => matchesDomain(target.hostname, rule))) {
        throw new Error('Target is outside plugin permissions');
      }
      const method = String(input.method || 'GET').toUpperCase();
      if (!['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'].includes(method)) {
        throw new Error('Unsupported HTTP method');
      }
      const body = input.body == null ? undefined : String(input.body);
      if (body && Buffer.byteLength(body) > MAX_REQUEST_BYTES) {
        throw new Error('Request too large');
      }
      const headers = {};
      if (input.headers != null && (typeof input.headers !== 'object' || Array.isArray(input.headers))) {
        throw new Error('Invalid headers');
      }
      let headerSize = 0;
      for (const [name, value] of Object.entries(input.headers || {})) {
        const lower = name.toLowerCase();
        if (FORBIDDEN_HEADERS.has(lower) || typeof value !== 'string') continue;
        headerSize += Buffer.byteLength(name) + Buffer.byteLength(value);
        if (headerSize > 32 * 1024) throw new Error('Headers too large');
        headers[name] = value;
      }
      // Upstreams that trust these headers see the selected client-IP country.
      // This does not move the function or change its real outbound connection.
      const clientIp = forwardedIp(country);
      headers['X-Real-IP'] = clientIp;
      headers['X-Forwarded-For'] = clientIp;

      await assertPublicHost(target.hostname, lookup);
      controller.signal.throwIfAborted();
      const upstream = await fetch(target, {
        method,
        headers,
        body: method === 'GET' || method === 'HEAD' ? undefined : body,
        redirect: 'manual',
        signal: controller.signal,
      });
      const responseHeaders = {};
      for (const [name, value] of upstream.headers.entries()) {
        if (name !== 'set-cookie') responseHeaders[name] = value;
      }
      const cookies = typeof upstream.headers.getSetCookie === 'function'
        ? upstream.headers.getSetCookie()
        : (upstream.headers.get('set-cookie') || '');
      if (cookies) responseHeaders['set-cookie'] = Array.isArray(cookies) ? cookies.join('\n') : cookies;

      const result = {
        status: upstream.status,
        headers: responseHeaders,
        body: await readBody(upstream),
      };
      if (Buffer.byteLength(JSON.stringify(result)) > MAX_JSON_RESPONSE_BYTES) {
        throw new Error('Response too large');
      }
      return result;
    };
    try {
      res.status(200).json(await Promise.race([request(), deadline]));
    } catch (error) {
      res.status(error.name === 'TimeoutError' ? 504 : 400).json({ error: String(error.message || 'Proxy request failed') });
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
  };
}

module.exports = createHandler();
module.exports.createHandler = createHandler;
