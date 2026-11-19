// Replaces the engine's own `<variant>/canvaskit.js` in the packed site.
//
// Flutter imports that path as an ES module and calls its default export with
// `{locateFile}`. The prefetch script in index.html may already hold the wasm
// bytes by then, so this wrapper hands them over as a blob URL instead of
// letting the glue issue a second, serial request for the same file.
//
// Anything unexpected — no prefetch, another CanvasKit variant, a failed
// checksum there — falls through to the untouched glue, which fetches the wasm
// exactly as it always has.
import init from '__LAZER_CANVASKIT_GLUE__';

var variant = '__LAZER_CANVASKIT_VARIANT__';

function prefetchedWasm() {
  var pending = typeof self !== 'undefined' ? self.__lazerEngineWasm : null;
  if (!pending) return Promise.resolve(null);
  return Promise.resolve(pending).then(
    function (result) {
      return result && result.variant === variant ? result.url : null;
    },
    function () {
      return null;
    }
  );
}

export default function CanvasKitInit(options) {
  var locateFile = options && options.locateFile;
  return prefetchedWasm().then(function (wasmUrl) {
    if (!wasmUrl) return init(options);
    var merged = Object.assign({}, options);
    // The glue resolves the wasm through locateFile; everything else must keep
    // resolving against the engine directory it was loaded from.
    merged.locateFile = function (file, prefix) {
      if (/(^|\/)canvaskit\.wasm$/.test(file)) return wasmUrl;
      return locateFile ? locateFile(file, prefix) : (prefix || '') + file;
    };
    return init(merged);
  });
}
