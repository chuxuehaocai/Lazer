package dev.naominet.lazer

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.Structure
import java.awt.Window

/**
 * Windows-only native backdrop for desktop Liquid Glass.
 *
 * Uses the undocumented `user32!SetWindowCompositionAttribute` with an acrylic accent policy, which
 * asks DWM to blur the live operating-system content behind the window. This is the efficient,
 * real-time replacement for screen-capture-based approaches.
 */

private const val WCA_ACCENT_POLICY = 19
private const val ACCENT_DISABLED = 0
private const val ACCENT_ENABLE_ACRYLICBLURBEHIND = 4

/** 0xAABBGGRR. A cool, low-alpha tint so the blurred desktop stays clearly visible. */
private const val ACRYLIC_TINT = 0x662D281D.toInt()

private interface User32Accent : Library {
    fun SetWindowCompositionAttribute(hwnd: Pointer, data: WindowCompositionAttributeData): Int
}

private interface DwmApi : Library {
    fun DwmSetWindowAttribute(hwnd: Pointer, attribute: Int, value: Pointer, size: Int): Int
}

private const val DWMWA_SYSTEMBACKDROP_TYPE = 38
private const val DWMWA_USE_IMMERSIVE_DARK_MODE = 20
private const val DWMWA_WINDOW_CORNER_PREFERENCE = 33
private const val DWMSBT_TRANSIENTWINDOW = 3
private const val DWMSBT_MAINWINDOW = 2

private val dwmApi: DwmApi? by lazy {
    if (!isWindowsDesktop()) null else runCatching { Native.load("dwmapi", DwmApi::class.java) }.getOrNull()
}

private fun Pointer.putInt(attribute: Int, value: Int) {
    val dwm = dwmApi ?: return
    val buffer = com.sun.jna.Memory(4).apply { setInt(0, value) }
    runCatching { dwm.DwmSetWindowAttribute(this, attribute, buffer, 4) }
}

private class AccentPolicy : Structure() {
    @JvmField var accentState: Int = 0
    @JvmField var accentFlags: Int = 0
    @JvmField var gradientColor: Int = 0
    @JvmField var animationId: Int = 0

    override fun getFieldOrder(): List<String> =
        listOf("accentState", "accentFlags", "gradientColor", "animationId")
}

private class WindowCompositionAttributeData : Structure() {
    @JvmField var attribute: Int = 0
    @JvmField var data: Pointer? = null
    @JvmField var sizeOfData: Int = 0

    override fun getFieldOrder(): List<String> = listOf("attribute", "data", "sizeOfData")
}

private val user32Accent: User32Accent? by lazy {
    if (!isWindowsDesktop()) {
        null
    } else {
        runCatching { Native.load("user32", User32Accent::class.java) }.getOrNull()
    }
}

/**
 * Enables or disables the acrylic backdrop on [window]. No-op on non-Windows platforms or when the
 * user32 call is unavailable.
 */
internal fun applyWindowsAcrylic(window: Window, enabled: Boolean) {
    runCatching {
        val hwnd: Pointer = Native.getWindowPointer(window) ?: return
        val backdrop = if (enabled) DWMSBT_TRANSIENTWINDOW else 0
        hwnd.putInt(DWMWA_SYSTEMBACKDROP_TYPE, backdrop)
        // DWMWCP_DONOTROUND = 1: keep the frame square on desktop.
        hwnd.putInt(DWMWA_WINDOW_CORNER_PREFERENCE, 1)
        hwnd.putInt(DWMWA_USE_IMMERSIVE_DARK_MODE, 1)

        val user32 = user32Accent ?: return
        val accent = AccentPolicy().apply {
            accentState = if (enabled) ACCENT_ENABLE_ACRYLICBLURBEHIND else ACCENT_DISABLED
            accentFlags = if (enabled) 2 else 0
            gradientColor = if (enabled) ACRYLIC_TINT else 0
        }
        accent.write()
        val data = WindowCompositionAttributeData().apply {
            attribute = WCA_ACCENT_POLICY
            this.data = accent.pointer
            sizeOfData = accent.size()
        }
        data.write()
        user32.SetWindowCompositionAttribute(hwnd, data)
    }
}
