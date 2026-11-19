#!/usr/bin/env node
// Rejects a packed Vercel directory that would deploy a broken site: the
// entrypoint the HTML asks for must exist under its hashed name, the engine must
// be served from this origin, and the HTTP bridge must have shipped.
//
//   node ci/vercel-web/verify-output.js [--out .vercel/output]
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const index = process.argv.indexOf('--out');
const out = index === -1
  ? path.resolve(__dirname, '..', '..', '.vercel', 'output')
  : path.resolve(process.argv[index + 1]);

const problems = [];
function fail(message) {
  problems.push(message);
}
function read(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    fail(`${file}: ${error.message}`);
    return '';
  }
}
function json(file) {
  try {
    return JSON.parse(read(file) || 'null');
  } catch (error) {
    fail(`${file}: invalid JSON: ${error.message}`);
    return null;
  }
}

const configFile = path.join(out, 'config.json');
const config = json(configFile) || {};
if (config.version !== 3) fail(`config.json: expected version 3, got ${config.version}`);
const routes = Array.isArray(config.routes) ? config.routes : [];
if (routes.length === 0) fail('config.json: no routes');

const staticDir = path.join(out, 'static');
const html = read(path.join(staticDir, 'index.html'));
const bootstrap = read(path.join(staticDir, 'flutter_bootstrap.js'));
if (!html) fail('static/index.html is missing');
if (!bootstrap) fail('static/flutter_bootstrap.js is missing');
if (!html.includes('_flutter.loader.load(') || /<script[^>]+src=["']flutter_bootstrap\.js/.test(html)) {
  fail('static/index.html must inline the Flutter loader to avoid a serial network request');
}
for (const [name, text] of [['index.html', html], ['flutter_bootstrap.js', bootstrap]]) {
  if (/__LAZER_(?:CANVASKIT|ASSET|FONT)_BASE__/.test(text)) fail(`${name}: unresolved asset placeholder`);
  if (!text.includes('initializeEngine(lazerFlutterConfig)')) {
    fail(`${name}: the engine must receive the same asset configuration as the loader`);
  }
}

// The packer renames the entrypoint and points both files at the new name. A
// stale name here is a blank page, and the error only shows up in a browser.
const entryRoute = routes.find((route) => /^\/main\.[0-9a-f]{12}\.js$/.test(route.src));
if (!entryRoute) {
  fail('config.json: no content-hashed entrypoint route');
} else {
  const entry = entryRoute.src.slice(1);
  if (!entryRoute.headers?.['cache-control']?.includes('immutable')) fail('entrypoint is not immutable');
  if (!fs.existsSync(path.join(staticDir, entry))) fail(`static/${entry} is missing`);
  for (const [name, text] of [['index.html', html], ['flutter_bootstrap.js', bootstrap]]) {
    if (!text.includes(entry)) fail(`static/${name} does not reference ${entry}`);
  }
  if (/main\.dart\.js/.test(html)) fail('static/index.html still references main.dart.js');
}

// Mainland China cannot reach www.gstatic.com, so the engine has to ship.
const canvaskitRoute = routes.find((route) => /^\/canvaskit-[0-9a-f]{12}\//.test(route.src));
if (!canvaskitRoute) {
  fail('config.json: no content-hashed canvaskit route');
} else {
  const directory = canvaskitRoute.src.slice(1).split('/')[0];
  if (!canvaskitRoute.headers?.['cache-control']?.includes('immutable')) fail('engine is not immutable');
  if (!fs.existsSync(path.join(staticDir, directory, 'canvaskit.wasm'))) {
    fail(`static/${directory}/canvaskit.wasm is missing`);
  }
  // Every variant's canvaskit.js is a wrapper the prefetch feeds; its glue has
  // to sit beside it, and the plan in index.html has to describe the real files
  // or the prefetch would stitch the wrong bytes into a blob.
  const planMatch = /var plans = (\[[\s\S]*?\]);/.exec(html);
  const declared = planMatch ? JSON.parse(planMatch[1]) : [];
  if (declared.length === 0) fail('index.html: the engine prefetch plan is missing');
  for (const plan of declared) {
    if (!plan.variant || !plan.path || !plan.bytes || !plan.digest) {
      fail('index.html: an engine plan entry is incomplete');
      continue;
    }
    const file = path.join(staticDir, plan.path);
    if (!fs.existsSync(file)) {
      fail(`prefetched engine is missing: ${plan.path}`);
      continue;
    }
    const bytes = fs.readFileSync(file);
    if (bytes.length !== plan.bytes) fail(`${plan.path}: prefetch size does not match the file`);
    const digest = crypto.createHash('sha256').update(bytes).digest('hex');
    if (digest !== plan.digest) fail(`${plan.path}: prefetch digest does not match the file`);
    const glue = file.replace(/canvaskit\.wasm$/, 'canvaskit.glue.js');
    const wrapper = file.replace(/canvaskit\.wasm$/, 'canvaskit.js');
    if (!fs.existsSync(glue)) fail(`${plan.path}: the original engine glue is missing`);
    const wrapperText = read(wrapper);
    if (!wrapperText.includes('__lazerEngineWasm')) {
      fail(`${plan.path}: the variant wrapper does not consume the prefetch`);
    }
    if (!/export default function CanvasKitInit/.test(wrapperText)) {
      fail(`${plan.path}: the variant wrapper has no default export for Flutter`);
    }
    for (const marker of ['__LAZER_CANVASKIT_GLUE__', '__LAZER_CANVASKIT_VARIANT__']) {
      if (wrapperText.includes(marker)) fail(`${plan.path}: unresolved ${marker}`);
    }
  }
}

// Validate the actual URLs Flutter will resolve, including the shared fonts
// outside the per-release assets directory. A wrong assetBase silently falls
// back to missing fonts or an HTML response unless caught before deployment.
const assetRoute = routes.find((route) => /^\/assets-[0-9a-f]{12}\//.test(route.src));
const fontRoute = routes.find((route) => /^\/fonts-[0-9a-f]{12}\//.test(route.src));
for (const [name, route] of [['assets', assetRoute], ['fonts', fontRoute]]) {
  if (!route) {
    fail(`config.json: no content-hashed ${name} route`);
    continue;
  }
  if (!route.headers?.['cache-control']?.includes('immutable')) fail(`${name} are not immutable`);
  const directory = route.src.slice(1).split('/')[0];
  for (const [file, text] of [['index.html', html], ['flutter_bootstrap.js', bootstrap]]) {
    if (!text.includes(`${directory}/`)) fail(`${file} does not reference ${directory}/`);
  }
}
if (assetRoute && fontRoute) {
  const assetBase = assetRoute.src.slice(1).split('/')[0];
  const fontBase = fontRoute.src.slice(1).split('/')[0];
  const manifest = json(path.join(staticDir, assetBase, 'assets', 'FontManifest.json'));
  if (!Array.isArray(manifest)) {
    fail('FontManifest.json: expected an array');
  } else {
    for (const family of manifest) {
      for (const font of family.fonts || []) {
        const url = new URL(`${assetBase}/assets/${font.asset}`, 'https://packed.invalid/');
        const file = path.join(staticDir, url.pathname);
        if (!url.pathname.startsWith(`/${fontBase}/`)) fail(`font is not in the shared immutable directory: ${font.asset}`);
        if (!fs.existsSync(file)) {
          fail(`missing font ${url.pathname}`);
        } else if (family.family === 'MiSans') {
          if (!url.pathname.endsWith('.woff2') || fs.readFileSync(file).toString('ascii', 0, 4) !== 'wOF2') {
            fail(`MiSans must use WOFF2: ${url.pathname}`);
          }
        }
        if (!html.includes(`href="${url.pathname.slice(1)}" as="fetch" crossorigin`)) {
          fail(`font is not preloaded with the engine's fetch mode: ${url.pathname}`);
        }
      }
    }
  }
}
for (const match of html.matchAll(/<link\s+rel="preload"\s+href="([^"]+)"/g)) {
  if (!fs.existsSync(path.join(staticDir, match[1]))) fail(`preloaded file is missing: ${match[1]}`);
}
if (bootstrap.includes('__LAZER_CANVASKIT_BASE__')) {
  fail('flutter_bootstrap.js still has the unresolved engine placeholder');
}
if (canvaskitRoute && !bootstrap.includes(canvaskitRoute.src.slice(1).split('/')[0])) {
  fail('flutter_bootstrap.js does not point at the packed engine directory');
}

// The site is only usable if the same-origin HTTP bridge and its IP table ship.
for (const file of ['index.js', 'china_ip_ranges.txt', 'forwarded-ip.js', 'forwarded-ip-ranges.json']) {
  const packed = path.join(out, 'functions', 'api', 'plugin-http.func', file);
  if (!fs.existsSync(packed)) fail(`functions/api/plugin-http.func/${file} is missing`);
}
const functionConfig = json(path.join(out, 'functions', 'api', 'plugin-http.func', '.vc-config.json')) || {};
if (!functionConfig.regions?.includes('hkg1')) fail('HTTP bridge must deploy in the configured Hong Kong region');
if (!routes.some((route) => route.src === '/api/plugin-http' && route.dest === '/api/plugin-http')) {
  fail('config.json: /api/plugin-http is not routed to the function');
}
if (!routes.some((route) => route.handle === 'filesystem')) {
  fail('config.json: no filesystem handle, so static files would not be served');
}
if (!routes.some((route) => route.status === 404 && route.src?.includes('assets-'))) {
  fail('missing immutable assets must return 404 instead of the HTML shell');
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`error: ${problem}`);
  process.exit(1);
}
console.log(`packed site looks deployable: ${out}`);
