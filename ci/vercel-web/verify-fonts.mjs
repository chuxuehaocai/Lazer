#!/usr/bin/env node
// Decode the shipped fonts with the shipped CanvasKit builds, without a
// browser or network. Checking the file extension alone misses corrupt WOFF2.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const index = process.argv.indexOf('--out');
const out = index === -1
  ? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../.vercel/output')
  : path.resolve(process.argv[index + 1]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'lazer-font-decoder-'));
try {
  const staticDir = path.join(out, 'static');
  const directories = fs.readdirSync(staticDir);
  const engineBase = directories.find((name) => /^canvaskit-[0-9a-f]{12}$/.test(name));
  const assetBase = directories.find((name) => /^assets-[0-9a-f]{12}$/.test(name));
  assert.ok(engineBase && assetBase, 'Pack and verify the web output before checking fonts.');
  const manifest = JSON.parse(fs.readFileSync(path.join(staticDir, assetBase, 'assets/FontManifest.json')));
  const fonts = manifest.flatMap((family) => family.fonts.map((font) => {
    const url = new URL(`${assetBase}/assets/${font.asset}`, 'https://packed.invalid/');
    return { family: family.family, file: path.join(staticDir, url.pathname) };
  }));
  assert.equal(fonts.filter((font) => font.family === 'MiSans').length, 4, 'Expected all four MiSans weights.');
  for (const variant of ['', 'chromium']) {
    const engineDir = path.join(staticDir, engineBase, variant);
    // The packer replaces `canvaskit.js` with a wrapper that imports the glue by a
    // relative specifier, so the decoded copy has to keep the packed directory
    // layout. A `package.json` marks those `.js` files as modules instead of
    // relying on a `.mjs` suffix the wrapper cannot carry into its own imports.
    const moduleDir = path.join(temporary, variant || 'full');
    fs.cpSync(engineDir, moduleDir, { recursive: true });
    fs.writeFileSync(path.join(moduleDir, 'package.json'), '{"type":"module"}\n');
    const moduleFile = path.join(moduleDir, 'canvaskit.js');
    const { default: initialize } = await import(pathToFileURL(moduleFile).href);
    const wasm = await WebAssembly.compile(fs.readFileSync(path.join(engineDir, 'canvaskit.wasm')));
    const kit = await initialize({
      instantiateWasm(imports, receive) {
        const instance = new WebAssembly.Instance(wasm, imports);
        receive(instance, wasm);
        return instance.exports;
      },
    });
    for (const font of fonts) {
      const face = kit.Typeface.MakeFreeTypeFaceFromData(fs.readFileSync(font.file));
      assert.ok(face, `${variant || 'full'} CanvasKit cannot decode ${font.file}`);
      face.delete();
    }
    console.log(`${variant || 'full'} CanvasKit decoded all ${fonts.length} bundled fonts`);
  }
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
