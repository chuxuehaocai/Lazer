// Exercises the inlined engine prefetch against a real HTTP server: ranges are
// the only reason it exists, and a range assembled in the wrong order (or one
// that trusts a compressed body) would hand Flutter a corrupt wasm.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const template = fs.readFileSync(path.join(__dirname, 'canvaskit-prefetch.js'), 'utf8');

function plan(bytes) {
  return {
    variant: 'chromium',
    path: 'canvaskit-test/chromium/canvaskit.wasm',
    bytes: bytes.length,
    digest: crypto.createHash('sha256').update(bytes).digest('hex'),
    parts: 4,
    retries: 2,
    hedgeMs: 4000,
    mirrors: [],
  };
}

// A tiny static server for the engine file. `mode` decides how ranges are
// answered, which is exactly what the prefetch has to cope with.
async function serve(t, bytes, mode) {
  const requests = [];
  const server = http.createServer((request, response) => {
    const range = request.headers.range || '';
    requests.push({ url: request.url, range });
    const failing = mode === 'broken' || (mode === 'retry-once' && requests.length === 1);
    if (failing) {
      response.writeHead(500).end();
      return;
    }
    if (mode === 'ignored' || !range) {
      response.writeHead(200, { 'content-length': bytes.length }).end(bytes);
      return;
    }
    const match = /bytes=(\d+)-(\d+)/.exec(range);
    const start = Number(match[1]);
    const end = Math.min(Number(match[2]), bytes.length - 1);
    const slice = bytes.subarray(start, end + 1);
    response
      .writeHead(206, {
        'content-range': `bytes ${start}-${end}/${bytes.length}`,
        'content-length': slice.length,
      })
      .end(slice);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  return { requests, origin: `http://127.0.0.1:${server.address().port}/` };
}

async function run(origin, enginePlan) {
  const created = [];
  class Uri extends URL {}
  Uri.createObjectURL = (blob) => {
    created.push(blob);
    return 'blob:engine';
  };
  const context = vm.createContext({
    window: { chrome: {}, crypto: crypto.webcrypto, dispatchEvent() {} },
    navigator: { userAgent: 'Mozilla/5.0 Chrome/120.0.0.0' },
    document: { baseURI: origin },
    fetch,
    AbortController,
    URL: Uri,
    Blob,
    CustomEvent: class {},
    crypto: crypto.webcrypto,
    setTimeout,
    clearTimeout,
  });
  vm.runInContext(template.replace('__LAZER_ENGINE_PLANS__', JSON.stringify([enginePlan])), context);
  const resolved = await context.window.__lazerEngineWasm;
  return { resolved, created };
}

test('ranges are fetched in parallel and stitched back into the exact wasm', async (t) => {
  const bytes = crypto.randomBytes(1300 * 1024);
  const { requests, origin } = await serve(t, bytes, 'range');
  const { resolved, created } = await run(origin, plan(bytes));
  assert.equal(resolved.variant, 'chromium');
  assert.equal(resolved.url, 'blob:engine');
  const assembled = Buffer.from(await created[0].arrayBuffer());
  assert.equal(assembled.length, bytes.length);
  assert.ok(assembled.equals(bytes), 'stitched bytes differ from the shipped file');
  // One probe plus three ranges for a 1.3 MB file (512 KB floor, four parts).
  const ranged = requests.filter((request) => request.range && request.range !== 'bytes=0-0');
  assert.equal(ranged.length, 3);
});

test('an origin that ignores ranges still yields the whole engine once', async (t) => {
  const bytes = crypto.randomBytes(200 * 1024);
  const { requests, origin } = await serve(t, bytes, 'ignored');
  const { resolved, created } = await run(origin, plan(bytes));
  assert.equal(resolved.url, 'blob:engine');
  assert.ok(Buffer.from(await created[0].arrayBuffer()).equals(bytes));
  assert.equal(requests.length, 1);
});

test('a failing source is retried instead of losing the whole download', async (t) => {
  const bytes = crypto.randomBytes(64 * 1024);
  const { origin } = await serve(t, bytes, 'retry-once');
  const { resolved, created } = await run(origin, plan(bytes));
  assert.equal(resolved.url, 'blob:engine');
  assert.ok(Buffer.from(await created[0].arrayBuffer()).equals(bytes));
});

test('a dead origin leaves the engine to Flutter instead of hanging the page', async (t) => {
  const bytes = crypto.randomBytes(32 * 1024);
  const { origin } = await serve(t, bytes, 'broken');
  const { resolved, created } = await run(origin, plan(bytes));
  assert.equal(resolved, null);
  assert.equal(created.length, 0);
});

test('a checksum mismatch is rejected so Flutter fetches the wasm itself', async (t) => {
  const bytes = crypto.randomBytes(48 * 1024);
  const { origin } = await serve(t, bytes, 'range');
  const tampered = { ...plan(bytes), digest: 'a'.repeat(64) };
  const { resolved, created } = await run(origin, tampered);
  assert.equal(resolved, null);
  assert.equal(created.length, 0);
});
