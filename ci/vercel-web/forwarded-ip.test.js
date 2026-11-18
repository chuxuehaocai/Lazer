const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const test = require('node:test');
const { SUPPORTED_COUNTRIES, normalizeCountry, forwardedIp, parseRanges } = require('./api/forwarded-ip');
const snapshot = require('./api/forwarded-ip-ranges.json');

function contains(ip, cidrs) {
  const value = ip.split('.').reduce((number, octet) => number * 256 + Number(octet), 0);
  return parseRanges(cidrs).ranges.some(({ start, count }) => value >= start && value < start + count);
}

test('the country catalog covers all Vercel compute countries and the CN default', () => {
  assert.deepEqual([...SUPPORTED_COUNTRIES].sort(), ['AU', 'BR', 'CA', 'CN', 'DE', 'FR', 'GB', 'HK', 'IE', 'IN', 'JP', 'KR', 'SE', 'SG', 'US', 'ZA']);
  assert.deepEqual(Object.keys(snapshot.countries).sort(), SUPPORTED_COUNTRIES.filter((country) => country !== 'CN').sort());
  assert.match(snapshot.purpose, /not Vercel egress/);
  assert.match(snapshot.limitations, /not verified current physical location/);
});

test('each forwarded address belongs to its country snapshot and remains stable', () => {
  for (const country of SUPPORTED_COUNTRIES) {
    const cidrs = country === 'CN'
      ? fs.readFileSync(path.join(__dirname, 'api', 'china_ip_ranges.txt'), 'utf8').split('\n')
      : snapshot.countries[country].cidrs;
    const ip = forwardedIp(country);
    assert.ok(net.isIPv4(ip), country);
    assert.ok(contains(ip, cidrs), `${country}: ${ip}`);
    assert.equal(forwardedIp(country), ip);
    assert.equal(forwardedIp(country.toLowerCase()), ip);
  }
  assert.equal(forwardedIp(), forwardedIp('CN'));
});

test('the allocation snapshot retains auditable sources and is bounded for cold starts', () => {
  for (const [country, data] of Object.entries(snapshot.countries)) {
    const source = new URL(data.source);
    assert.equal(source.hostname, 'stat.ripe.net');
    assert.equal(source.searchParams.get('resource'), country);
    assert.equal(source.searchParams.get('time'), data.queryTime);
    assert.equal(source.searchParams.get('v4_format'), 'prefix');
    assert.match(data.ipv4Sha256, /^[0-9a-f]{64}$/);
    assert.ok(data.cidrs.length > 0 && data.cidrs.length <= 64);
    assert.ok(data.availableCidrCount >= data.cidrs.length);
    parseRanges(data.cidrs);
  }
});

test('country validation defaults only for omitted values and rejects unknown values', () => {
  assert.equal(normalizeCountry(), 'CN');
  assert.equal(normalizeCountry(null), 'CN');
  assert.equal(normalizeCountry(' hk '), 'HK');
  for (const input of ['', 'XX', 'CN/../US', 'toString', false, 1, [], {}]) {
    assert.throws(() => normalizeCountry(input), /Unsupported egress country/);
  }
});

test('malformed CIDRs fail instead of selecting an unrelated fallback address', () => {
  for (const input of ['1.2.3.4/NaN', '1.2.3.4/', '1.2.3.4/0', '1.2.3.4/33', '1.2.3.4/24.5', '256.2.3.4/24', '1.2.3.4/24/8']) {
    assert.throws(() => parseRanges([input]), /Invalid bundled client IP range/);
  }
  assert.throws(() => parseRanges(['# empty']), /No bundled client IP ranges/);
  assert.deepEqual(parseRanges(['1.2.3.4/32']), { ranges: [{ start: 16909060, count: 1 }], total: 1 });
});
