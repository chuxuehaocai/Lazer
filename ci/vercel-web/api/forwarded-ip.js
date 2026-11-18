const { randomInt } = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const snapshot = require('./forwarded-ip-ranges.json');

// These choices cover Vercel's 19 compute regions, plus the existing mainland
// China client-IP default. They do not select a Vercel deployment region.
const SUPPORTED_COUNTRIES = Object.freeze(['CN', 'HK', 'JP', 'KR', 'SG', 'IN', 'AU', 'US', 'CA', 'BR', 'GB', 'IE', 'FR', 'DE', 'SE', 'ZA']);
const supportedCountries = new Set(SUPPORTED_COUNTRIES);
const parsedRanges = new Map();
const instanceIps = new Map();

function normalizeCountry(value) {
  if (value == null) return 'CN';
  if (typeof value !== 'string' || !supportedCountries.has(value.trim().toUpperCase())) {
    throw new Error('Unsupported egress country');
  }
  return value.trim().toUpperCase();
}

function ipToInt(ip) {
  return ip.split('.').reduce((value, part) => value * 256 + Number(part), 0);
}

function intToIp(value) {
  return [value >>> 24, (value >>> 16) & 255, (value >>> 8) & 255, value & 255].join('.');
}

function parseRanges(lines) {
  const ranges = [];
  let total = 0;
  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const [ip, prefixText, extra] = line.split('/');
    const prefix = Number(prefixText);
    if (extra || !net.isIPv4(ip) || !/^\d+$/.test(prefixText) || prefix < 1 || prefix > 32) {
      throw new Error('Invalid bundled client IP range');
    }
    const count = 2 ** (32 - prefix);
    const start = Math.floor(ipToInt(ip) / count) * count;
    ranges.push({ start, count });
    total += count;
  }
  if (!total) throw new Error('No bundled client IP ranges');
  return { ranges, total };
}

function rangesForCountry(country) {
  if (!parsedRanges.has(country)) {
    const lines = country === 'CN'
      ? fs.readFileSync(path.join(__dirname, 'china_ip_ranges.txt'), 'utf8').split('\n')
      : snapshot.countries[country]?.cidrs;
    if (!lines) throw new Error('Missing bundled client IP ranges');
    parsedRanges.set(country, parseRanges(lines));
  }
  return parsedRanges.get(country);
}

function forwardedIp(value) {
  const country = normalizeCountry(value);
  if (!instanceIps.has(country)) {
    const { ranges, total } = rangesForCountry(country);
    let offset = randomInt(total);
    for (const range of ranges) {
      if (offset < range.count) {
        // One stable address per country and warm instance, weighted by the
        // allocation's size. No filesystem reads on subsequent requests.
        instanceIps.set(country, intToIp(range.start + offset));
        break;
      }
      offset -= range.count;
    }
  }
  return instanceIps.get(country);
}

module.exports = { SUPPORTED_COUNTRIES, normalizeCountry, forwardedIp, parseRanges };
