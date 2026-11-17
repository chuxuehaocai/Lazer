# Native audio diagnostics example

Zip `manifest.json` and `main.lua` at the archive root, then import the ZIP in
Lazer's plugin manager. Use the plugin's **Read audio diagnostics** action and
open its diagnostics page. The two lyrics actions request a separate permission.
There is no network, storage, filesystem permission, timer or background polling.

The example requests `native_audio` for audio snapshots and `native_control` for
lyrics settings. Declining consent or revoking it leaves subsequent operations
blocked. On a browser or a host without the native engine, diagnostics report
unsupported; output formats describe engine negotiation, never a DAC readback.
The device list is an existing catalog snapshot, not a request to scan/open USB.

See [the host contract](../../docs/lua-plugins.md#受限原生宿主能力) for fields,
unsupported results, bounds and lifecycle behavior.
