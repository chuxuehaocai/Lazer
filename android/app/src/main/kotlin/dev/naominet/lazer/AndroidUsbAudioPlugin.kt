package dev.naominet.lazer

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Permission and FD ownership only; PCM stays on the native render thread. */
class AndroidUsbAudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var manager: UsbManager
    private lateinit var channel: MethodChannel
    private val sessions = UsbAudioSessionState<MethodChannel.Result, UsbDeviceConnection>(
        fileDescriptor = { it.fileDescriptor },
        disposeConnection = { it.close() },
    )
    private lateinit var permissionAction: String
    private var requestCode = 0

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            val id = "android-usb:${device.deviceName}"
            when (intent.action) {
                permissionAction -> {
                    val results = sessions.completePermission(id, intent.getStringExtra(PERMISSION_NONCE))
                    if (results.isEmpty()) return
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && manager.hasPermission(device)) {
                        results.forEach { openGranted(id, device, it) }
                    } else {
                        results.forEach { it.error("usb_permission_denied", "USB DAC permission was denied", null) }
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    closeDevice(id, "usb_disconnected", "USB DAC was disconnected")
                    channel.invokeMethod("detached", id)
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        // A recreated Flutter engine must not reuse the old engine's PendingIntent identity.
        permissionAction = "${context.packageName}.USB_AUDIO_PERMISSION.${UUID.randomUUID()}"
        channel = MethodChannel(binding.binaryMessenger, "dev.naominet.lazer/usb_audio")
        channel.setMethodCallHandler(this)
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter)
        }
    }

    private fun isUac2(device: UsbDevice): Boolean = (0 until device.interfaceCount).any {
        val iface = device.getInterface(it)
        iface.interfaceClass == 1 && iface.interfaceSubclass == 2 && iface.interfaceProtocol == 0x20
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listDevices" -> result.success(manager.deviceList.values.filter { isUac2(it) }.map { device ->
                    mapOf(
                        "id" to "android-usb:${device.deviceName}",
                        "name" to (device.productName ?: "USB DAC ${device.vendorId}:${device.productId}"),
                        "vendorId" to device.vendorId,
                        "productId" to device.productId,
                        "hasPermission" to manager.hasPermission(device),
                    )
                })
                "openDevice" -> {
                    val id = call.argument<String>("id") ?: throw IllegalArgumentException("Missing USB device ID")
                    require(id.startsWith("android-usb:")) { "Invalid persistent USB device ID" }
                    val device = manager.deviceList[id.removePrefix("android-usb:")]
                        ?: throw IllegalStateException("The selected USB DAC is no longer connected")
                    require(isUac2(device)) { "The selected USB device has no UAC2 streaming interface" }
                    sessions.checkConnectionCapacity(id)
                    if (manager.hasPermission(device)) openGranted(id, device, result)
                    else {
                        val request = sessions.requestPermission(id, result)
                        if (request != null) {
                            try {
                                val intent = Intent(permissionAction).setPackage(context.packageName)
                                    .putExtra(PERMISSION_NONCE, request.nonce)
                                val permission = PendingIntent.getBroadcast(context, ++requestCode, intent,
                                    PendingIntent.FLAG_IMMUTABLE)
                                if (sessions.setPermissionCancellation(id, request.nonce) { permission.cancel() }) {
                                    manager.requestPermission(device, permission)
                                } else permission.cancel()
                            } catch (error: Exception) {
                                sessions.completePermission(id, request.nonce).forEach {
                                    it.error("usb_audio_failed", error.message, null)
                                }
                            }
                        }
                    }
                }
                "closeDevice" -> {
                    val id = call.argument<String>("id") ?: throw IllegalArgumentException("Missing USB device ID")
                    closeDevice(id, "usb_cancelled", "USB connection request was cancelled")
                    result.success(null)
                }
                "closeAll" -> { closeAll(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (error: UsbAudioBusyException) {
            result.error("usb_busy", error.message, null)
        } catch (error: Exception) {
            result.error("usb_audio_failed", error.message, null)
        }
    }

    private fun openGranted(id: String, device: UsbDevice, result: MethodChannel.Result) {
        try {
            // Re-check after the asynchronous permission dialog: detach may have happened meanwhile.
            if (!manager.deviceList.containsKey(device.deviceName)) throw IllegalStateException("USB DAC was disconnected")
            val connection = sessions.openConnection(id) { manager.openDevice(device) }
            result.success("android-usb-fd:${connection.fileDescriptor}")
        } catch (error: UsbAudioBusyException) {
            result.error("usb_busy", error.message, null)
        } catch (error: Exception) {
            result.error("usb_open_failed", error.message, null)
        }
    }

    private fun closeDevice(id: String, code: String, message: String) {
        val cancelled = sessions.cancelPermission(id)
        try {
            sessions.closeConnection(id)
        } finally {
            cancelled.forEach { it.error(code, message, null) }
        }
    }

    private fun closeAll() {
        val cancelled = sessions.cancelAllPermissions()
        try {
            sessions.closeAllConnections()
        } finally {
            cancelled.forEach { it.error("usb_cancelled", "USB connection request was cancelled", null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        try {
            context.unregisterReceiver(receiver)
        } finally {
            closeAll()
        }
    }

    private companion object {
        const val PERMISSION_NONCE = "dev.naominet.lazer.USB_AUDIO_PERMISSION_NONCE"
    }
}
