const assert = require('node:assert/strict');
const test = require('node:test');
const { createHandler } = require('./api/plugin-http');
const { SUPPORTED_COUNTRIES, forwardedIp } = require('./api/forwarded-ip');

const baseInput = { url: 'https://music.example/api', domains: ['music.example'] };
const publicLookup = async () => [{ address: '8.8.8.8', family: 4 }];

function response() {
  return {
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
    end() { this.ended = true; },
  };
}

async function invoke(input = {}, options = {}, method = 'POST') {
  const res = response();
  await createHandler({ lookup: publicLookup, fetch: async () => new Response('ok'), ...options })(
    { method, body: { ...baseInput, ...input } }, res,
  );
  return res;
}

test('forwards every supported country and protects client IP headers from overrides', async () => {
  for (const country of SUPPORTED_COUNTRIES) {
    const result = await invoke({
      egressCountry: country,
      headers: {
        'x-ReAl-Ip': '127.0.0.1', 'X-FoRwArDeD-fOr': '127.0.0.2',
        Forwarded: 'for=127.0.0.3', 'CF-Connecting-IP': '127.0.0.4',
        Host: 'internal', 'Content-Length': '999', Authorization: 'test-token',
      },
    }, {
      fetch: async (target, options) => {
        assert.equal(target.hostname, 'music.example');
        const headers = new Headers(options.headers);
        assert.equal(headers.get('x-real-ip'), forwardedIp(country));
        assert.equal(headers.get('x-forwarded-for'), forwardedIp(country));
        assert.equal(headers.get('authorization'), 'test-token');
        for (const name of ['host', 'content-length', 'forwarded', 'cf-connecting-ip']) {
          assert.equal(headers.get(name), null);
        }
        assert.equal(options.redirect, 'manual');
        assert.ok(options.signal instanceof AbortSignal);
        return new Response('upstream', { status: 201, headers: [['set-cookie', 'a=1'], ['set-cookie', 'b=2']] });
      },
    });
    assert.equal(result.statusCode, 200);
    assert.equal(result.headers['Cache-Control'], 'no-store');
    assert.equal(result.body.status, 201);
    assert.equal(result.body.body, 'upstream');
    assert.equal(result.body.headers['set-cookie'], 'a=1\nb=2');
  }
});

test('old callers retain mainland China and requests preserve method and body', async () => {
  const result = await invoke({ method: 'POST', body: '{"hello":"world"}' }, {
    fetch: async (_, options) => {
      assert.equal(options.headers['X-Real-IP'], forwardedIp('CN'));
      assert.equal(options.method, 'POST');
      assert.equal(options.body, '{"hello":"world"}');
      return new Response('');
    },
  });
  assert.equal(result.statusCode, 200);
});

test('invalid country and oversized requests fail before DNS or upstream work', async () => {
  const inputs = [
    ...['', 'XX', 3, false, {}, []].map((egressCountry) => ({ egressCountry })),
    { body: 'x'.repeat(2 * 1024 * 1024 + 1) },
    { headers: { oversized: 'x'.repeat(32 * 1024 + 1) } },
    { headers: [] }, { domains: Array(129).fill('music.example') },
  ];
  for (const input of inputs) {
    let contacted = false;
    const result = await invoke(input, {
      lookup: async () => { contacted = true; return publicLookup(); },
      fetch: async () => { contacted = true; return new Response('bad'); },
    });
    assert.equal(result.statusCode, 400);
    assert.equal(contacted, false);
  }
});

test('raw JSON and Buffer requests work and oversized envelopes are rejected', async () => {
  const handler = createHandler({ lookup: publicLookup, fetch: async () => new Response('ok') });
  for (const body of [JSON.stringify(baseInput), Buffer.from(JSON.stringify(baseInput))]) {
    const res = response();
    await handler({ method: 'POST', body }, res);
    assert.equal(res.statusCode, 200);
  }
  for (const body of ['{', '[]', 'null', ' '.repeat(3 * 1024 * 1024 + 1)]) {
    const res = response();
    await handler({ method: 'POST', body }, res);
    assert.equal(res.statusCode, 400);
  }
});

test('permission matching and private-address checks reject unsafe targets', async () => {
  const targets = ['http://music.example/', 'https://user:pass@music.example/', 'https://music.example.evil/',
    'https://127.0.0.1/', 'https://100.64.0.1/', 'https://10.0.0.1/', 'https://[::1]/',
    'https://[::ffff:127.0.0.1]/', 'https://[fe80::1]/'];
  for (const url of targets) {
    let contacted = false;
    const result = await invoke({ url, domains: url.includes('example') ? ['*.example'] : [new URL(url).hostname] }, {
      fetch: async () => { contacted = true; return new Response('bad'); },
    });
    assert.equal(result.statusCode, 400, url);
    assert.equal(contacted, false, url);
  }
  const denied = await invoke({ url: 'https://badexample/api', domains: ['*.example'] });
  assert.equal(denied.statusCode, 400);
  const mixedDns = await invoke({}, { lookup: async () => [{ address: '8.8.8.8' }, { address: '10.0.0.1' }] });
  assert.equal(mixedDns.statusCode, 400);
  assert.equal((await invoke({ domains: ['*.example'] })).statusCode, 200);
});

test('the shared deadline covers DNS and prevents a late lookup starting a request', async () => {
  let finishLookup;
  let contacted = false;
  const result = await invoke({}, {
    timeoutMs: 15,
    lookup: () => new Promise((resolve) => { finishLookup = resolve; }),
    fetch: async () => { contacted = true; return new Response('bad'); },
  });
  assert.equal(result.statusCode, 504);
  finishLookup(await publicLookup());
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(contacted, false);
});

test('the deadline aborts both a stalled connection and a stalled response body', async () => {
  for (const stage of ['connect', 'body']) {
    let signal;
    const result = await invoke({}, {
      timeoutMs: 15,
      fetch: async (_, options) => {
        signal = options.signal;
        if (stage === 'connect') return new Promise(() => {});
        return new Response(new ReadableStream({
          start(controller) {
            signal.addEventListener('abort', () => controller.error(signal.reason), { once: true });
          },
        }));
      },
    });
    assert.equal(result.statusCode, 504, stage);
    assert.equal(signal.aborted, true);
  }
});

test('oversized streams are cancelled and escaped JSON stays below the platform limit', async () => {
  let cancelled = false;
  const result = await invoke({}, {
    fetch: async () => new Response(new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array(3 * 1024 * 1024 + 1)); },
      cancel() { cancelled = true; },
    })),
  });
  assert.equal(result.statusCode, 400);
  assert.equal(result.body.error, 'Response too large');
  assert.equal(cancelled, true);
  const escaped = await invoke({}, { fetch: async () => new Response('\0'.repeat(750000)) });
  assert.equal(escaped.statusCode, 400);
  assert.equal(escaped.body.error, 'Response too large');
});

test('GET on the proxy is rejected and OPTIONS succeeds without upstream work', async () => {
  assert.equal((await invoke({}, {}, 'GET')).statusCode, 405);
  assert.equal((await invoke({}, {}, 'OPTIONS')).statusCode, 204);
});
