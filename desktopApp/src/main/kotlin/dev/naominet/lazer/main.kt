package dev.naominet.lazer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import coil3.ImageLoader
import coil3.compose.setSingletonImageLoaderFactory
import coil3.memory.MemoryCache
import coil3.network.ktor3.KtorNetworkFetcherFactory
import coil3.request.crossfade
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.UserAgent
import java.awt.Insets
import java.awt.Rectangle
import java.awt.Toolkit

/**
 * Desktop entry.
 *
 * On Windows ARM64, do NOT use the green gutter Run on this function — IDEA creates a
 * "desktopApp [jvm]" config with ComposeJvmRunConfigurationExtension, which crashes with
 * "Unknown host target: windows aarch64".
 *
 * Use run configuration **Desktop App** (`:desktopApp:runDesktop`) or:
 *   gradlew :desktopApp:runDesktop
 *   run-desktop.bat
 */
fun main() = application {
    setSingletonImageLoaderFactory { context ->
        ImageLoader.Builder(context)
            .components {
                add(
                    KtorNetworkFetcherFactory(
                        httpClient = {
                            HttpClient(CIO) {
                                install(UserAgent) {
                                    agent = "LazerDesktop/1.0"
                                }
                            }
                        },
                    ),
                )
            }
            .memoryCache {
                MemoryCache.Builder()
                    .maxSizeBytes(16L * 1024L * 1024L)
                    .weakReferencesEnabled(false)
                    .build()
            }
            .crossfade(false)
            .build()
    }
    val windowState = rememberWindowState(
        position = WindowPosition.Aligned(Alignment.Center),
        size = DpSize(1280.dp, 820.dp),
    )
    // Compose's maximized placement can cover the Windows taskbar for undecorated windows.
    // Store native pixel bounds so maximize/restore also stays correct on mixed-DPI monitors.
    var restoreBounds by remember { mutableStateOf<Rectangle?>(null) }

    Window(
        onCloseRequest = ::exitApplication,
        title = "Lazer",
        icon = painterResource("icon.png"),
        state = windowState,
        undecorated = true,
        transparent = true,
    ) {
        DesktopPlayerApp(
            isWindowMaximized = restoreBounds != null,
            onMinimizeWindow = { windowState.isMinimized = true },
            onToggleMaximizeWindow = {
                val savedBounds = restoreBounds
                if (savedBounds != null) {
                    window.bounds = Rectangle(savedBounds)
                    restoreBounds = null
                } else {
                    val gc = window.graphicsConfiguration
                    val insets = Toolkit.getDefaultToolkit().getScreenInsets(gc)
                    restoreBounds = Rectangle(window.bounds)
                    window.bounds = workAreaBounds(gc.bounds, insets)
                }
            },
            onCloseWindow = ::exitApplication,
        )
    }
}

internal fun workAreaBounds(screen: Rectangle, insets: Insets): Rectangle = Rectangle(
    screen.x + insets.left,
    screen.y + insets.top,
    (screen.width - insets.left - insets.right).coerceAtLeast(400),
    (screen.height - insets.top - insets.bottom).coerceAtLeast(300),
)
