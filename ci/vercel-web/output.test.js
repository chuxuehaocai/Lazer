const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const packer = path.join(__dirname, 'prepare-output.js');
const verifier = path.join(__dirname, 'verify-output.js');

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lazer-web-output-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const web = path.join(directory, 'web');
  const api = path.join(directory, 'api');
  const out = path.join(directory, 'out');
  function write(relative, contents) {
    const file = path.join(directory, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, contents);
  }
  const bootstrap = fs.readFileSync(path.join(root, 'web/flutter_bootstrap.js'), 'utf8')
    .replace('{{flutter_js}}', 'window._flutter = { loader: { load() {} } };')
    .replace('{{flutter_build_config}}', '_flutter.buildConfig = { mainJsPath: "main.dart.js" };');
  write('web/flutter_bootstrap.js', bootstrap);
  write('web/index.html', fs.readFileSync(path.join(root, 'web/index.html'), 'utf8')
    .replace('$FLUTTER_BASE_HREF', '/').replace('{{flutter_bootstrap_js}}', bootstrap));
  write('web/main.dart.js', 'console.log("fixture");');
  write('web/canvaskit/canvaskit.js', '/* engine fixture */');
  write('web/canvaskit/canvaskit.wasm', 'engine fixture');
  write('web/canvaskit/chromium/canvaskit.wasm', 'chromium engine fixture');
  write('web/canvaskit/skwasm.wasm', 'another engine variant');
  write('web/assets/AssetManifest.bin', 'asset manifest');
  write('web/assets/assets/l10n/zh_Hans.json', '{"hello":"你好"}');
  write('web/assets/assets/fonts/MiSans-Regular.ttf', 'TTF fixture');
  write('web/assets/assets/fonts/MiSans-Regular.woff2', 'wOF2 fixture');
  write('web/assets/FontManifest.json', JSON.stringify([
    { family: 'MiSans', fonts: [{ weight: 400, asset: 'assets/fonts/MiSans-Regular.ttf' }] },
  ]));
  write('web/fonts/roboto/fallback.woff2', 'wOF2 fallback fixture');
  for (const file of ['plugin-http.js', 'china_ip_ranges.txt', 'forwarded-ip.js', 'forwarded-ip-ranges.json']) {
    write(`api/${file}`, 'fixture');
  }
  function run(script, args = []) {
    return spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  }
  function pack() {
    const result = run(packer, ['--web', web, '--api', api, '--out', out]);
    assert.equal(result.status, 0, result.stderr);
  }
  function verify() { return run(verifier, ['--out', out]); }
  function config() { return JSON.parse(fs.readFileSync(path.join(out, 'config.json'))); }
  function route(prefix) { return config().routes.find((item) => item.src?.startsWith(`/${prefix}-`)).src; }
  return { directory, web, api, out, write, run, pack, verify, config, route };
}

test('packed startup resolves every preload and font with immutable caching', (t) => {
  const f = fixture(t);
  f.pack();
  const result = f.verify();
  assert.equal(result.status, 0, result.stderr);
  const html = fs.readFileSync(path.join(f.out, 'static/index.html'), 'utf8');
  assert.ok(!html.includes('<script src="flutter_bootstrap.js"'));
  assert.ok(!/__LAZER_(?:CANVASKIT|ASSET|FONT)_BASE__/.test(html));
  const functionConfig = JSON.parse(fs.readFileSync(path.join(f.out, 'functions/api/plugin-http.func/.vc-config.json')));
  assert.deepEqual(functionConfig.regions, ['hkg1']);
  const legacyAssets = f.config().routes.find((route) => route.src === '/assets/(.*)');
  assert.match(legacyAssets.dest, /^\/assets-[0-9a-f]{12}\/assets\/\$1$/);
  assert.equal(legacyAssets.headers['cache-control'], 'public, max-age=0, must-revalidate');
});

test('translation updates invalidate assets while reusing cached fonts and engine', (t) => {
  const f = fixture(t);
  f.pack();
  const before = { assets: f.route('assets'), fonts: f.route('fonts'), engine: f.route('canvaskit') };
  f.write('web/assets/assets/l10n/zh_Hans.json', '{"hello":"您好"}');
  f.pack();
  assert.notEqual(f.route('assets'), before.assets);
  assert.equal(f.route('fonts'), before.fonts);
  assert.equal(f.route('canvaskit'), before.engine);
  assert.equal(f.verify().status, 0);
});

test('changing a font or any engine variant invalidates the corresponding cache', (t) => {
  const f = fixture(t);
  f.pack();
  const fonts = f.route('fonts');
  const engine = f.route('canvaskit');
  f.write('web/assets/assets/fonts/MiSans-Regular.woff2', 'wOF2 new font');
  f.write('web/canvaskit/skwasm.wasm', 'new alternate renderer');
  f.pack();
  assert.notEqual(f.route('fonts'), fonts);
  assert.notEqual(f.route('canvaskit'), engine);
  assert.equal(f.verify().status, 0);
});

test('identical inputs produce identical routing and HTML', (t) => {
  const f = fixture(t);
  f.pack();
  const config = f.config();
  const html = fs.readFileSync(path.join(f.out, 'static/index.html'), 'utf8');
  f.pack();
  assert.deepEqual(f.config(), config);
  assert.equal(fs.readFileSync(path.join(f.out, 'static/index.html'), 'utf8'), html);
});

test('missing fonts and stale startup references fail deployment verification', (t) => {
  const f = fixture(t);
  f.pack();
  const fonts = f.route('fonts').slice(1).split('/')[0];
  const file = fs.readdirSync(path.join(f.out, 'static', fonts)).find((name) => name.startsWith('MiSans-'));
  fs.unlinkSync(path.join(f.out, 'static', fonts, file));
  let result = f.verify();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing font|preloaded file is missing/);
  f.pack();
  const html = path.join(f.out, 'static/index.html');
  fs.writeFileSync(html, fs.readFileSync(html, 'utf8').replace('initializeEngine(lazerFlutterConfig)', 'initializeEngine({})'));
  result = f.verify();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /same asset configuration/);
});

test('an old build cannot silently ship with an unversioned assetBase', (t) => {
  const f = fixture(t);
  f.write('web/flutter_bootstrap.js', 'old loader');
  const result = f.run(packer, ['--web', f.web, '--api', f.api, '--out', f.out]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /rebuild the web bundle/);
});

test('output directory cannot overwrite a source directory', (t) => {
  const f = fixture(t);
  const result = f.run(packer, ['--web', f.web, '--api', f.api, '--out', f.directory]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Output must not contain a source directory/);
  assert.ok(fs.existsSync(path.join(f.web, 'index.html')));
});

test('the first Flutter frame dismisses the loader even after a slow-network timeout', () => {
  const html = fs.readFileSync(path.join(root, 'web/index.html'), 'utf8');
  const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
    .map((match) => match[1]).find((source) => source.includes("var fill = document.getElementById"));
  const classes = new Set();
  const elements = new Map();
  for (const id of ['lazer-boot', 'lazer-boot-fill', 'lazer-boot-hint', 'lazer-boot-retry']) {
    elements.set(id, { style: {}, classList: { add: (value) => classes.add(value) }, addEventListener() {} });
  }
  const listeners = new Map();
  const timeouts = new Map();
  vm.runInNewContext(script, {
    document: { getElementById: (id) => elements.get(id) },
    window: {
      addEventListener: (event, handler) => listeners.set(event, handler),
      removeEventListener() {},
    },
    setInterval() {}, clearInterval() {},
    setTimeout: (handler, delay) => timeouts.set(delay, handler),
  });
  timeouts.get(20000)();
  assert.ok(classes.has('lazer-boot--failed'));
  listeners.get('flutter-first-frame')();
  assert.ok(classes.has('lazer-boot--done'));
});
