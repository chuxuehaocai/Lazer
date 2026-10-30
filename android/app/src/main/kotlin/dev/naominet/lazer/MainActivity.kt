package dev.naominet.lazer

import android.Manifest
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/// The app's own haptics channel, mirroring the iOS `AppDelegate` handler.
///
/// Flutter's built-in `HapticFeedback` maps taps to `CLOCK_TICK`, which many
/// Android devices do not implement and which ignores the user's intensity
/// setting. Driving the vibrator directly gives every device the same short
/// tick and lets the analytics-free intensity slider control its strength.
class MainActivity : AudioServiceActivity() {
    private var vibrator: Vibrator? = null
    private var permissionResult: MethodChannel.Result? = null
    private var logExportResult: MethodChannel.Result? = null
    private var logExportText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.naominet.lazer/logs")
            .setMethodCallHandler { call, result ->
                if (call.method != "export") {
                    result.notImplemented()
                } else if (logExportResult != null) {
                    result.error("busy", "An export is already open", null)
                } else {
                    logExportText = call.argument<String>("text") ?: ""
                    logExportResult = result
                    try {
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "Lazer-log.txt")
                        }
                        startActivityForResult(intent, 4102)
                    } catch (error: Exception) {
                        logExportResult = null
                        logExportText = null
                        result.error("export_failed", error.message, null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTICS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "impact") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val intensity = ((call.argument<Number>("intensity") ?: .5).toFloat())
                    .coerceIn(0f, 1f)
                val kind = call.argument<String>("kind") ?: "tap"
                impact(intensity, kind)
                result.success(null)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCAL_MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAudioAccess" -> result.success(hasAudioAccess())
                    "requestAudioAccess" -> requestAudioAccess(result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TV_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATES_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")?.trim()
                if (url.isNullOrEmpty()) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                result.success(openInBrowser(url))
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4102) return
        val pending = logExportResult ?: return
        val text = logExportText ?: ""
        logExportText = null
        if (resultCode != RESULT_OK || data?.data == null) {
            logExportResult = null
            pending.success(false)
            return
        }
        val destination = data.data!!
        Thread({
            try {
                val output = contentResolver.openOutputStream(destination)
                    ?: throw IllegalStateException("Cannot open the selected file")
                output.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                runOnUiThread {
                    logExportResult = null
                    pending.success(true)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    logExportResult = null
                    pending.error("export_failed", error.message, null)
                }
            }
        }, "lazer-log-export").start()
    }

    /// Opens a release page without carrying `url_launcher` just for one link.
    private fun openInBrowser(url: String): Boolean = try {
        val uri = Uri.parse(url)
        if (uri.scheme != "https" && uri.scheme != "http") {
            false
        } else {
            startActivity(
                Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }
    } catch (_: Exception) {
        // A device without a browser is unusual but not an error worth crashing
        // for; the update dialog still shows the URL as selectable text.
        false
    }

    /// Whether this device is a television, so Dart can switch to the ten-foot
    /// layout and make every tap target reachable with a D-pad remote.
    ///
    /// Leanback is the official answer, but cheap set-top boxes often ship
    /// without the feature flag while still having a television UI mode or no
    /// touch screen at all; all three shapes are recognised.
    private fun isTelevision(): Boolean {
        val uiMode =
            (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType
        if (uiMode == Configuration.UI_MODE_TYPE_TELEVISION) return true
        val manager = packageManager
        if (manager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            manager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            manager.hasSystemFeature(TELEVISION_FEATURE)
        ) {
            return true
        }
        // No touch input means the only way through the app is a D-pad.
        return !manager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) &&
            !manager.hasSystemFeature(PackageManager.FEATURE_FAKETOUCH)
    }

    /// `READ_MEDIA_AUDIO` replaced `READ_EXTERNAL_STORAGE` on Android 13.
    private fun audioPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun hasAudioAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(audioPermission()) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestAudioAccess(result: MethodChannel.Result) {
        if (hasAudioAccess()) {
            result.success(true)
            return
        }
        // A permission dialog is already on screen; never stack two requests.
        if (permissionResult != null) {
            result.success(false)
            return
        }
        permissionResult = result
        requestPermissions(arrayOf(audioPermission()), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    private fun impact(intensity: Float, kind: String) {
        val vibrator = vibrator ?: resolveVibrator().also { vibrator = it } ?: return
        if (!vibrator.hasVibrator()) return
        val milliseconds = when (kind) {
            "boundary" -> 26L
            "detent" -> 8L
            else -> 12L
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Amplitude 1..255: 0 is not a valid one-shot amplitude, and a
            // non-zero floor keeps the faintest setting perceptible.
            val amplitude = (intensity * 255f).roundToInt().coerceIn(1, 255)
            vibrator.vibrate(VibrationEffect.createOneShot(milliseconds, amplitude))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(milliseconds)
        }
    }

    private fun resolveVibrator(): Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private companion object {
        const val HAPTICS_CHANNEL = "dev.naominet.lazer/haptics"
        const val LOCAL_MEDIA_CHANNEL = "dev.naominet.lazer/local_media"
        const val TV_CHANNEL = "dev.naominet.lazer/tv"
        const val UPDATES_CHANNEL = "dev.naominet.lazer/updates"
        const val TELEVISION_FEATURE = "android.hardware.type.television"
        const val PERMISSION_REQUEST = 4101
    }
}
