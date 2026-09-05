package dev.naominet.lazer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import coil3.ImageLoader
import coil3.compose.setSingletonImageLoaderFactory
import coil3.network.ktor3.KtorNetworkFetcherFactory
import coil3.request.crossfade
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.UserAgent
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
            .crossfade(true)
            .build()
    }
    val windowState = rememberWindowState(
        position = WindowPosition.Aligned(Alignment.Center),
        size = DpSize(1280.dp, 820.dp),
    )
    // Undecorated + WindowPlacement.Maximized covers the taskbar on Windows.
    // Track a work-area "maximize" ourselves and keep placement Floating.
    var isWorkAreaMaximized by remember { mutableStateOf(false) }
    var restorePosition by remember {
        mutableStateOf<WindowPosition>(WindowPosition.Aligned(Alignment.Center))
    }
    var restoreSize by remember { mutableStateOf(DpSize(1280.dp, 820.dp)) }

    Window(
        onCloseRequest = ::exitApplication,
        title = "Lazer",
        state = windowState,
        undecorated = true,
        transparent = true,
    ) {
        val density = LocalDensity.current
        DesktopPlayerApp(
            isWindowMaximized = isWorkAreaMaximized,
            onMinimizeWindow = { windowState.isMinimized = true },
            onToggleMaximizeWindow = {
                if (isWorkAreaMaximized) {
                    windowState.placement = WindowPlacement.Floating
                    windowState.position = restorePosition
                    windowState.size = restoreSize
                    isWorkAreaMaximized = false
                } else {
                    restorePosition = windowState.position
                    restoreSize = windowState.size
                    val gc = window.graphicsConfiguration
                    val screen = gc.bounds
                    val insets = Toolkit.getDefaultToolkit().getScreenInsets(gc)
                    val pxX = screen.x + insets.left
                    val pxY = screen.y + insets.top
                    val pxW = (screen.width - insets.left - insets.right).coerceAtLeast(400)
                    val pxH = (screen.height - insets.top - insets.bottom).coerceAtLeast(300)
                    with(density) {
                        windowState.placement = WindowPlacement.Floating
                        windowState.position = WindowPosition(x = pxX.toDp(), y = pxY.toDp())
                        windowState.size = DpSize(width = pxW.toDp(), height = pxH.toDp())
                    }
                    isWorkAreaMaximized = true
                }
            },
            onCloseWindow = ::exitApplication,
        )
    }
}
