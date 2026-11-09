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
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      fontFallbackBaseUrl: 'fonts/'
    });
    await appRunner.runApp();
  }
});
