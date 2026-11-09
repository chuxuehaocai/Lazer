{{flutter_js}}
{{flutter_build_config}}

// Keep the engine's fallback fonts on this origin. The default
// `https://fonts.gstatic.com/s/` is unreachable from mainland China and would
// otherwise be requested while rendering text that MiSans does not cover.
_flutter.loader.load({
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
