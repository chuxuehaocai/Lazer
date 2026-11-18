{{flutter_js}}
{{flutter_build_config}}

// Keep the engine's fallback fonts on this origin. The default
// `https://fonts.gstatic.com/s/` is unreachable from mainland China and would
// otherwise be requested while rendering text that MiSans does not cover.
const lazerFlutterConfig = {
    // Rewritten to a content-hashed directory by the Vercel packing script, so
    // the engine can be cached immutably instead of revalidated every visit.
    canvasKitBaseUrl: '__LAZER_CANVASKIT_BASE__',
    // The packer replaces these with content-hashed, same-origin directories.
    // Flutter adds `assets/` to assetBase when resolving a bundled asset.
    assetBase: '__LAZER_ASSET_BASE__',
    fontFallbackBaseUrl: '__LAZER_FONT_BASE__'
};
// Keep normal `flutter run/build web` working without the Vercel packer.
if (lazerFlutterConfig.canvasKitBaseUrl.startsWith('__LAZER_')) {
  lazerFlutterConfig.canvasKitBaseUrl = 'canvaskit';
  lazerFlutterConfig.assetBase = '';
  lazerFlutterConfig.fontFallbackBaseUrl = 'fonts/';
}
_flutter.loader.load({
  config: lazerFlutterConfig,
  // Vercel serves the content-hashed engine and entrypoint directly. Keeping
  // Flutter's generated service worker here can resurrect an older bootstrap
  // after a deployment and leave the page waiting for a file that no longer
  // exists. The browser and Vercel already cache the immutable files safely.
  onEntrypointLoaded: async function (engineInitializer) {
    // A custom callback must explicitly forward engine-stage configuration.
    const appRunner = await engineInitializer.initializeEngine(lazerFlutterConfig);
    await appRunner.runApp();
  }
});
