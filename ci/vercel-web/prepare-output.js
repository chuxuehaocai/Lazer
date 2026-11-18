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
const apiFiles = ['plugin-http.js', 'china_ip_ranges.txt', 'forwarded-ip.js', 'forwarded-ip-ranges.json'];
for (const file of apiFiles) {
  if (!fs.existsSync(path.join(api, file))) {
    console.error(`Missing ${path.join(api, file)}`);
    process.exit(1);
  }
}

// Refuse paths that could erase the checkout or a source input by mistake.
for (const input of [root, web, api]) {
  const relative = path.relative(out, input);
  if (relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
    throw new Error(`Output must not contain a source directory: ${out}`);
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
const htmlFile = path.join(staticDir, 'index.html');
function rewriteBoot(search, replacement) {
  for (const file of [bootstrapFile, htmlFile]) {
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll(search, replacement));
  }
}
function filesIn(directory, relative = '') {
  return fs.readdirSync(path.join(directory, relative), { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name, 'en'))
    .flatMap((entry) => {
      const name = path.posix.join(relative, entry.name);
      return entry.isDirectory() ? filesIn(directory, name) : [name];
    });
}
function contentHash(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').slice(0, 12);
}
function directoryHash(directory) {
  const hash = crypto.createHash('sha256');
  for (const relative of filesIn(directory)) {
    hash.update(relative).update('\0').update(fs.readFileSync(path.join(directory, relative))).update('\0');
  }
  return hash.digest('hex').slice(0, 12);
}
for (const marker of ['__LAZER_CANVASKIT_BASE__', '__LAZER_ASSET_BASE__', '__LAZER_FONT_BASE__']) {
  if (!fs.readFileSync(bootstrapFile, 'utf8').includes(marker)) {
    throw new Error(`Missing ${marker}; rebuild the web bundle before packing.`);
  }
}
let canvaskitBase = 'canvaskit';
if (fs.existsSync(canvaskitDir)) {
  if (!fs.existsSync(bootstrapFile)) {
    console.error('The build has no flutter_bootstrap.js to point at the engine');
    process.exit(1);
  }
  const digest = directoryHash(canvaskitDir);
  const bootstrap = fs.readFileSync(bootstrapFile, 'utf8');
  if (bootstrap.includes('__LAZER_CANVASKIT_BASE__')) {
    canvaskitBase = `canvaskit-${digest}`;
    fs.renameSync(canvaskitDir, path.join(staticDir, canvaskitBase));
    rewriteBoot('__LAZER_CANVASKIT_BASE__', canvaskitBase);
  }
}

// CanvasKit fetches all declared fonts before the first frame. WOFF2 preserves
// the existing glyph repertoire while avoiding TTF's expensive wire format.
// Fonts have their own content-addressed directory: a translation or image
// update must not invalidate megabytes of already cached fonts.
const assetsDir = path.join(staticDir, 'assets');
const fontsDir = path.join(staticDir, 'fonts');
fs.mkdirSync(fontsDir, { recursive: true });
const manifestFile = path.join(assetsDir, 'FontManifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const fontAssets = [];
for (const family of manifest) {
  for (const font of family.fonts) {
    const original = path.join(assetsDir, font.asset);
    const woff2 = original.replace(/\.(ttf|otf)$/i, '.woff2');
    const source = fs.existsSync(woff2) ? woff2 : original;
    if (!fs.existsSync(source)) throw new Error(`Missing declared font: ${font.asset}`);
    const extension = path.extname(source);
    const name = `${path.basename(source, extension)}.${contentHash(source)}${extension}`;
    fs.copyFileSync(source, path.join(fontsDir, name));
    fontAssets.push({ font, name });
    // The manifest is the only engine consumer of bundled font assets.
    // Preserve original files for rootBundle consumers; they are not preloaded.
  }
}
const fontsBase = `fonts-${directoryHash(fontsDir)}`;
fs.renameSync(fontsDir, path.join(staticDir, fontsBase));
for (const { font, name } of fontAssets) {
  // Flutter prefixes assetBase + "assets/". Resolving two parent segments
  // keeps font URLs independent of the remaining asset bundle's revision.
  font.asset = `../../${fontsBase}/${name}`;
}
fs.writeFileSync(manifestFile, JSON.stringify(manifest));
const assetsBase = `assets-${directoryHash(assetsDir)}`;
fs.mkdirSync(path.join(staticDir, assetsBase));
fs.renameSync(assetsDir, path.join(staticDir, assetsBase, 'assets'));
rewriteBoot('__LAZER_ASSET_BASE__', `${assetsBase}/`);
rewriteBoot('__LAZER_FONT_BASE__', `${fontsBase}/`);
const preloads = [
  `${assetsBase}/assets/FontManifest.json`,
  ...fontAssets.map(({ name }) => `${fontsBase}/${name}`),
].map((href) => `  <link rel="preload" href="${href}" as="fetch" crossorigin>`).join('\n');
rewriteBoot('<!-- LAZER_FONT_PRELOADS -->', preloads);

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
for (const file of apiFiles) {
  fs.copyFileSync(path.join(api, file), path.join(func, file === 'plugin-http.js' ? 'index.js' : file));
}
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
          src: '/(?:|index\\.html|flutter_bootstrap\\.js|flutter_service_worker\\.js)',
          headers: { 'cache-control': 'public, max-age=0, must-revalidate' },
          continue: true,
        },
        // Some third-party plugins construct asset URLs themselves instead of
        // using Flutter's asset manager. Keep those URLs working, revalidating
        // them on each visit while the normal versioned requests stay cached.
        {
          src: '/assets/(.*)',
          dest: `/${assetsBase}/assets/$1`,
          headers: { 'cache-control': 'public, max-age=0, must-revalidate' },
        },
        {
          src: '/fonts/(.*)',
          dest: `/${fontsBase}/$1`,
          headers: { 'cache-control': 'public, max-age=0, must-revalidate' },
        },
        ...[assetsBase, fontsBase].map((directory) => ({
          src: `/${directory}/(.*)`,
          headers: { 'cache-control': 'public, max-age=31536000, immutable' },
          continue: true,
        })),
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
        // Never cache the HTML shell as an immutable missing asset. This also
        // makes a stale deployment fail clearly instead of parsing HTML as JS.
        { src: '/(?:assets-[0-9a-f]{12}|fonts-[0-9a-f]{12}|canvaskit-[0-9a-f]{12})/(.*)', status: 404 },
        { src: '/main\\.[0-9a-f]{12}\\.js', status: 404 },
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
      // The HTTP bridge reaches mainland music services; Hong Kong avoids
      // routing every request through the default US function region.
      regions: ['hkg1'],
    },
    null,
    2,
  )}\n`,
);
console.log(out);
