{{flutter_js}}
{{flutter_build_config}}

// Keep the engine's fallback fonts on this origin. The default
// `https://fonts.gstatic.com/s/` is unreachable from mainland China and would
// otherwise be requested while rendering text that MiSans does not cover.
_flutter.loader.load({
  config: {
    // Rewritten to a content-hashed directory by the Vercel packing script, so
    // the engine can be cached immutably instead of revalidated every visit.
    canvasKitBaseUrl: '__LAZER_CANVASKIT_BASE__'
  },
  // Vercel serves the content-hashed engine and entrypoint directly. Keeping
  // Flutter's generated service worker here can resurrect an older bootstrap
  // after a deployment and leave the page waiting for a file that no longer
  // exists. The browser and Vercel already cache the immutable files safely.
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      fontFallbackBaseUrl: 'fonts/'
    });
    await appRunner.runApp();
  }
});
