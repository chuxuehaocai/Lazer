#!/usr/bin/env node
// Refresh the small, bundled country-allocation sample. No runtime network
// lookup is needed. RIPEstat aggregates the five RIRs' registration statistics;
// these are NOT Vercel egress ranges or authoritative IP geolocation.
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const COUNTRIES = ['AU', 'BR', 'CA', 'DE', 'FR', 'GB', 'HK', 'IE', 'IN', 'JP', 'KR', 'SE', 'SG', 'US', 'ZA'];
const SAMPLE_SIZE = 64;

async function countryRanges(country) {
  const source = `https://stat.ripe.net/data/country-resource-list/data.json?resource=${country}&v4_format=prefix`;
  const response = await fetch(source, { signal: AbortSignal.timeout(60000) });
  if (!response.ok) throw new Error(`${country}: HTTP ${response.status}`);
  const result = await response.json();
  const ipv4 = result.data?.resources?.ipv4;
  if (result.status !== 'ok' || !Array.isArray(ipv4)) {
    throw new Error(`${country}: invalid RIPEstat response`);
  }
  const ranges = ipv4.filter((cidr) => {
    const [ip, prefix, extra] = cidr.split('/');
    return !extra && net.isIPv4(ip) && /^\d+$/.test(prefix) &&
      Number(prefix) >= 1 && Number(prefix) <= 30;
  }).sort((a, b) => Number(a.split('/')[1]) - Number(b.split('/')[1]) || a.localeCompare(b, 'en'));
  if (!ranges.length) throw new Error(`${country}: no IPv4 CIDRs`);
  return {
    source: `${source}&time=${encodeURIComponent(result.data.query_time)}`,
    queryTime: result.data.query_time,
    ipv4Sha256: crypto.createHash('sha256').update(JSON.stringify(ipv4)).digest('hex'),
    availableCidrCount: ranges.length,
    cidrs: ranges.slice(0, SAMPLE_SIZE),
  };
}

async function main() {
  const countries = {};
  // RIPEstat permits at most eight concurrent requests. Four also keeps this
  // maintenance command usable on slow connections.
  for (let start = 0; start < COUNTRIES.length; start += 4) {
    const batch = COUNTRIES.slice(start, start + 4);
    const results = await Promise.all(batch.map(countryRanges));
    batch.forEach((country, index) => { countries[country] = results[index]; });
  }
  const output = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    sourceDocumentation: 'https://stat.ripe.net/docs/data-api/api-endpoints/country-resource-list',
    regionDocumentation: 'https://vercel.com/docs/regions',
    purpose: 'Synthetic forwarded client IP only; these are not Vercel egress address ranges.',
    limitations: 'RIR country codes describe resource registration, not verified current physical location. Upstream GeoIP databases may disagree. Forwarding headers do not change the actual server egress, and only work with services that trust those headers.',
    selection: `Largest ${SAMPLE_SIZE} IPv4 CIDRs per country, then lexical order; CN retains the existing china_ip_ranges.txt dataset.`,
    countries,
  };
  const destination = path.join(__dirname, 'api', 'forwarded-ip-ranges.json');
  fs.writeFileSync(destination, `${JSON.stringify(output, null, 2)}\n`);
  console.log(`Updated ${COUNTRIES.length} country samples in ${destination}`);
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
