// Starts the CanvasKit wasm download while the Dart entrypoint is still
// arriving, in ranges that can retry on their own.
//
// `<engine>/<variant>/canvaskit.js` is only ~25 KB compressed; the wasm beside
// it (5.4 MB) is the entire download, and the engine asks for it only after the
// Dart entrypoint has parsed and run. On a mainland connection those two
// transfers otherwise sit one behind the other across an intercontinental round
// trip.
//
// Range requests are used instead of one stream so a stalled range retries by
// itself rather than restarting 5.4 MB. A one-byte probe comes first: an origin
// that answers ranges over a compressed body cannot be stitched back together,
// and in that case the download falls back to a single request. Every failure
// path leaves `self.__lazerEngineWasm` unresolved, and the engine then fetches
// the wasm exactly as it does today.
(function () {
  var plans = __LAZER_ENGINE_PLANS__;
  if (!plans || !plans.length) return;
  // A listener who asked to save data keeps the engine's own single request:
  // starting 5 MB before the first frame is exactly what that flag forbids.
  var connection = navigator.connection || navigator.mozConnection;
  if (connection && connection.saveData) return;

  // Flutter loads `<variant>/canvaskit.js` only on Chromium. Prefetching the
  // Chromium wasm on Safari or Firefox would waste the whole download, so the
  // same split the engine makes is applied here.
  var isChromium =
    typeof window.chrome !== 'undefined' &&
    !/Firefox\//.test(navigator.userAgent);
  var plan = null;
  for (var index = 0; index < plans.length; index++) {
    if (plans[index].variant === (isChromium ? 'chromium' : 'full')) {
      plan = plans[index];
    }
  }
  if (!plan) plan = plans[0];
  if (!plan || !plan.path || !plan.bytes) return;
  window.__lazerEnginePlan = plan;

  var total = plan.bytes;
  var retries = plan.retries || 2;
  var hedge = plan.hedgeMs || 4000;
  var smallestPart = 512 * 1024;
  var received = 0;

  function report() {
    var percent = Math.min(100, Math.round((received / total) * 100));
    window.__lazerEngineProgress = percent;
    try {
      window.dispatchEvent(
        new CustomEvent('lazer-engine-progress', { detail: percent })
      );
    } catch (error) {}
  }

  function absolute(base, path) {
    try {
      var root = base ? new URL(base, document.baseURI) : document.baseURI;
      return new URL(path, root).href;
    } catch (error) {
      return null;
    }
  }

  var sources = [];
  var primary = absolute(null, plan.path);
  if (primary) sources.push(primary);
  for (var m = 0; m < (plan.mirrors || []).length; m++) {
    var mirror = absolute(plan.mirrors[m], plan.path);
    if (mirror && sources.indexOf(mirror) === -1) sources.push(mirror);
  }
  if (!sources.length) return;

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  // One request for [start, end]. `start === null` asks for the whole file.
  function request(url, start, end, controller) {
    var options = { credentials: 'same-origin', signal: controller.signal };
    if (start !== null) options.headers = { Range: 'bytes=' + start + '-' + end };
    return fetch(url, options).then(function (response) {
      if (response.status !== 200 && response.status !== 206) {
        throw new Error('HTTP ' + response.status);
      }
      // A 200 for a ranged request means the origin ignored Range; the body is
      // the whole file and is still usable.
      var whole = start !== null && response.status === 200;
      if (response.status === 206) {
        var contentRange = response.headers.get('content-range') || '';
        var match = /\/(\d+)\s*$/.exec(contentRange);
        if (match && Number(match[1]) !== total) {
          throw new Error('unexpected engine size');
        }
      }
      if (start === null) whole = true;
      return response.arrayBuffer().then(function (buffer) {
        var bytes = new Uint8Array(buffer);
        received += bytes.length;
        report();
        return { bytes: bytes, start: whole ? 0 : start, whole: whole };
      });
    });
  }

  function attempt(url, start, end, controller, tries) {
    return request(url, start, end, controller).catch(function (error) {
      if (controller.signal.aborted || tries <= 0) throw error;
      return sleep(260 * (3 - tries)).then(function () {
        return attempt(url, start, end, controller, tries - 1);
      });
    });
  }

  // The first source starts immediately and each further source joins after
  // `hedge` ms, so a mirror can overtake a primary that is merely slow.
  function race(start, end) {
    return new Promise(function (resolve, reject) {
      var controllers = [];
      var timers = [];
      var settled = false;
      var failures = 0;
      function finish(result) {
        if (settled) return;
        settled = true;
        for (var t = 0; t < timers.length; t++) clearTimeout(timers[t]);
        for (var c = 0; c < controllers.length; c++) {
          try {
            controllers[c].abort();
          } catch (error) {}
        }
        resolve(result);
      }
      function give() {
        failures += 1;
        if (settled || failures < sources.length) return;
        settled = true;
        reject(new Error('engine download failed'));
      }
      sources.forEach(function (url, index) {
        var controller = new AbortController();
        controllers.push(controller);
        var launch = function () {
          if (settled) return;
          attempt(url, start, end, controller, retries).then(finish, give);
        };
        if (index === 0) launch();
        else timers.push(setTimeout(launch, hedge * index));
      });
    });
  }

  // A compressing origin serves ranges over the encoded body, which cannot be
  // assembled. One byte decides that before the download commits; a 200 answer
  // also means the whole file arrived already.
  function probe() {
    return race(0, 0).then(
      function (result) {
        if (result.whole) return { chunked: false, whole: result.bytes };
        return { chunked: result.bytes.length === 1, whole: null };
      },
      function () {
        return { chunked: false, whole: null };
      }
    );
  }

  function download() {
    return probe().then(function (result) {
      if (result.whole) return result.whole;
      var parts = 1;
      if (result.chunked) {
        parts = Math.max(
          1,
          Math.min(plan.parts || 4, Math.ceil(total / smallestPart))
        );
      }
      var ranges = [];
      for (var index = 0; index < parts; index++) {
        ranges.push({
          start: Math.round((total * index) / parts),
          end: Math.round((total * (index + 1)) / parts) - 1,
        });
      }
      return Promise.all(
        ranges.map(function (range) {
          return race(range.start, range.end);
        })
      ).then(function (results) {
        for (var i = 0; i < results.length; i++) {
          if (results[i].whole) return results[i].bytes;
        }
        var bytes = new Uint8Array(total);
        for (var j = 0; j < results.length; j++) {
          var piece = results[j].bytes;
          if (piece.length !== ranges[j].end - ranges[j].start + 1) {
            throw new Error('short engine range');
          }
          bytes.set(piece, ranges[j].start);
        }
        return bytes;
      });
    });
  }

  // A stitched file that does not match the packed digest must never reach the
  // engine: a corrupt wasm is a blank page, while the plain fetch is not.
  function verified(bytes) {
    var subtle = window.crypto && window.crypto.subtle;
    if (!subtle || !plan.digest) return Promise.resolve(true);
    return subtle.digest('SHA-256', bytes).then(function (hash) {
      var hex = '';
      var view = new Uint8Array(hash);
      for (var index = 0; index < view.length; index++) {
        hex += (view[index] < 16 ? '0' : '') + view[index].toString(16);
      }
      return hex === plan.digest;
    }).catch(function () {
      return true;
    });
  }

  window.__lazerEngineWasm = download()
    .then(function (bytes) {
      if (bytes.length !== total) return null;
      return verified(bytes).then(function (ok) {
        if (!ok) return null;
        return {
          variant: plan.variant,
          url: URL.createObjectURL(
            new Blob([bytes], { type: 'application/wasm' })
          ),
        };
      });
    })
    .catch(function () {
      return null;
    });
})();
