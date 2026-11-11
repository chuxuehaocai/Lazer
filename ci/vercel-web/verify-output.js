#!/usr/bin/env node
// Rejects a packed Vercel directory that would deploy a broken site: the
// entrypoint the HTML asks for must exist under its hashed name, the engine must
// be served from this origin, and the HTTP bridge must have shipped.
//
//   node ci/vercel-web/verify-output.js [--out .vercel/output]
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

const configFile = path.join(out, 'config.json');
const config = JSON.parse(read(configFile) || '{}');
if (config.version !== 3) fail(`config.json: expected version 3, got ${config.version}`);
const routes = Array.isArray(config.routes) ? config.routes : [];
if (routes.length === 0) fail('config.json: no routes');

const staticDir = path.join(out, 'static');
const html = read(path.join(staticDir, 'index.html'));
const bootstrap = read(path.join(staticDir, 'flutter_bootstrap.js'));
if (!html) fail('static/index.html is missing');
if (!bootstrap) fail('static/flutter_bootstrap.js is missing');

// The packer renames the entrypoint and points both files at the new name. A
// stale name here is a blank page, and the error only shows up in a browser.
const entryRoute = routes.find((route) => /^\/main\.[0-9a-f]{12}\.js$/.test(route.src));
if (!entryRoute) {
  fail('config.json: no content-hashed entrypoint route');
} else {
  const entry = entryRoute.src.slice(1);
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
  if (!fs.existsSync(path.join(staticDir, directory, 'canvaskit.wasm'))) {
    fail(`static/${directory}/canvaskit.wasm is missing`);
  }
}
if (bootstrap.includes('__LAZER_CANVASKIT_BASE__')) {
  fail('flutter_bootstrap.js still has the unresolved engine placeholder');
}
if (canvaskitRoute && !bootstrap.includes(canvaskitRoute.src.slice(1).split('/')[0])) {
  fail('flutter_bootstrap.js does not point at the packed engine directory');
}

// The site is only usable if the same-origin HTTP bridge and its IP table ship.
for (const file of ['index.js', 'china_ip_ranges.txt']) {
  const packed = path.join(out, 'functions', 'api', 'plugin-http.func', file);
  if (!fs.existsSync(packed)) fail(`functions/api/plugin-http.func/${file} is missing`);
}
if (!routes.some((route) => route.src === '/api/plugin-http' && route.dest === '/api/plugin-http')) {
  fail('config.json: /api/plugin-http is not routed to the function');
}
if (!routes.some((route) => route.handle === 'filesystem')) {
  fail('config.json: no filesystem handle, so static files would not be served');
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`error: ${problem}`);
  process.exit(1);
}
console.log(`packed site looks deployable: ${out}`);