#!/usr/bin/env node
// Packs this repository's web build into a Vercel Build Output API directory.
//
// Vercel's build machines have no Flutter, so the static site is compiled here
// (`flutter build web --release --no-web-resources-cdn`) and only the finished
// bytes are uploaded. The same script serves CI (.github/workflows/web-demo.yml)
// and a local `vercel deploy --prebuilt` run:
//
//   flutter build web --release --no-web-resources-cdn
//   node ci/vercel-web/prepare-output.js
//   vercel deploy --prebuilt --prod
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return fallback;
  const value = process.argv[index + 1];
  if (!value || value.startsWith('--')) {
    console.error(`--${name} needs a value`);
    process.exit(2);
  }
  return path.resolve(value);
}

const root = path.resolve(__dirname, '..', '..');
const web = argument('web', path.join(root, 'build', 'web'));
const api = argument('api', path.join(__dirname, 'api'));
const out = argument('out', path.join(root, '.vercel', 'output'));
const func = path.join(out, 'functions', 'api', 'plugin-http.func');

if (!fs.existsSync(path.join(web, 'index.html'))) {
  console.error(`Missing ${path.join(web, 'index.html')}. Run the web build first.`);
  process.exit(1);
}
for (const file of ['plugin-http.js', 'china_ip_ranges.txt']) {
  if (!fs.existsSync(path.join(api, file))) {
    console.error(`Missing ${path.join(api, file)}`);
    process.exit(1);
  }
}

fs.rmSync(out, { recursive: true, force: true });
fs.cpSync(web, path.join(out, 'static'), { recursive: true });

// Content-hash the engine directory so it can be served with an immutable
// cache. The Flutter loader asks for `canvaskit/...`; the bootstrap in
// web/flutter_bootstrap.js carries the placeholder rewritten below.
const staticDir = path.join(out, 'static');
const canvaskitDir = path.join(staticDir, 'canvaskit');
const bootstrapFile = path.join(staticDir, 'flutter_bootstrap.js');
let canvaskitBase = 'canvaskit';
if (fs.existsSync(canvaskitDir)) {
  if (!fs.existsSync(bootstrapFile)) {
    console.error('The build has no flutter_bootstrap.js to point at the engine');
    process.exit(1);
  }
  const hash = crypto.createHash('sha256');
  for (const relative of [
    'canvaskit.js',
    'canvaskit.wasm',
    'chromium/canvaskit.js',
    'chromium/canvaskit.wasm',
  ]) {
    const file = path.join(canvaskitDir, relative);
    if (fs.existsSync(file)) hash.update(fs.readFileSync(file));
  }
  const digest = hash.digest('hex').slice(0, 12);
  const bootstrap = fs.readFileSync(bootstrapFile, 'utf8');
  if (bootstrap.includes('__LAZER_CANVASKIT_BASE__')) {
    canvaskitBase = `canvaskit-${digest}`;
    fs.renameSync(canvaskitDir, path.join(staticDir, canvaskitBase));
    fs.writeFileSync(
      bootstrapFile,
      bootstrap.replaceAll('__LAZER_CANVASKIT_BASE__', canvaskitBase),
    );
  }
}

// Give the entrypoint the same treatment: hash the file name and point the
// bootstrap build config at it, so the browser can keep it forever.
let entrypoint = 'main.dart.js';
const entrypointFile = path.join(staticDir, entrypoint);
if (fs.existsSync(entrypointFile)) {
  const digest = crypto
    .createHash('sha256')
    .update(fs.readFileSync(entrypointFile))
    .digest('hex')
    .slice(0, 12);
  const hashed = `main.${digest}.js`;
  fs.renameSync(entrypointFile, path.join(staticDir, hashed));
  for (const relative of ['flutter_bootstrap.js', 'index.html']) {
    const file = path.join(staticDir, relative);
    if (!fs.existsSync(file)) continue;
    fs.writeFileSync(
      file,
      fs.readFileSync(file, 'utf8').replaceAll('main.dart.js', hashed),
    );
  }
  entrypoint = hashed;
}

fs.mkdirSync(func, { recursive: true });
fs.copyFileSync(path.join(api, 'plugin-http.js'), path.join(func, 'index.js'));
fs.copyFileSync(
  path.join(api, 'china_ip_ranges.txt'),
  path.join(func, 'china_ip_ranges.txt'),
);
fs.writeFileSync(
  path.join(out, 'config.json'),
  `${JSON.stringify(
    {
      version: 3,
      routes: [
        {
          src: '/api/plugin-http',
          headers: { 'cache-control': 'no-store' },
          dest: '/api/plugin-http',
        },
        {
          src: `/${canvaskitBase}/(.*)`,
          headers: { 'cache-control': 'public, max-age=31536000, immutable' },
          continue: true,
        },
        {
          src: `/${entrypoint}`,
          headers: { 'cache-control': 'public, max-age=31536000, immutable' },
          continue: true,
        },
        { handle: 'filesystem' },
        { src: '/(.*)', dest: '/index.html' },
      ],
    },
    null,
    2,
  )}\n`,
);
fs.writeFileSync(
  path.join(func, '.vc-config.json'),
  `${JSON.stringify(
    {
      runtime: 'nodejs22.x',
      handler: 'index.js',
      launcherType: 'Nodejs',
      shouldAddHelpers: true,
      maxDuration: 30,
    },
    null,
    2,
  )}\n`,
);
console.log(out);