package dev.naominet.lazer

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.window.WindowDraggableArea
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.window.WindowScope
import coil3.compose.AsyncImage
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.DEFAULT_GATEWAY_BASE_URL
import dev.naominet.lazer.gateway.normalizeGatewayBaseUrl
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.*
import kotlin.math.absoluteValue
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import org.jetbrains.skia.Image as SkiaImage

private val LocalScrollInertia = compositionLocalOf<ScrollInertiaController> {
    error("ScrollInertiaController missing")
}

private enum class DesktopDestination(
    val label: String,
    val icon: ImageVector,
) {
    HOME("主页", Icons.Outlined.Home),
    DISCOVER("发现", Icons.Outlined.Explore),
    LIBRARY("音乐库", Icons.Outlined.LibraryMusic),
    LIKED("我喜欢", Icons.Outlined.FavoriteBorder),
}

private val calmArtwork = listOf(
    listOf(Color(0xFF9FC6D8), Color(0xFF527D91)),
    listOf(Color(0xFFC5D5CE), Color(0xFF718D83)),
    listOf(Color(0xFFD9C4B5), Color(0xFFA1745B)),
    listOf(Color(0xFFBAC7DB), Color(0xFF697D9A)),
    listOf(Color(0xFFD2D4C2), Color(0xFF898A6A)),
)

@Composable
fun WindowScope.DesktopPlayerApp(
    controller: DesktopPlayerController = remember {
        DesktopPlayerController().also { it.start() }
    },
    isWindowMaximized: Boolean = false,
    onMinimizeWindow: () -> Unit = {},
    onToggleMaximizeWindow: () -> Unit = {},
    onCloseWindow: () -> Unit = {},
) {
    DisposableEffect(controller) {
        onDispose { controller.dispose() }
    }
    var destination by remember { mutableStateOf(DesktopDestination.HOME) }
    var settingsVisible by remember { mutableStateOf(false) }
    val scrollInertia = rememberScrollInertiaController()

    LazerTheme(isDark = controller.isDark, engine = controller.themeEngine) {
        val frameShape = RoundedCornerShape(if (isWindowMaximized) 0.dp else 12.dp)
        CompositionLocalProvider(LocalScrollInertia provides scrollInertia) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            shape = frameShape,
            color = MaterialTheme.colorScheme.background,
            border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        ) {
            PaperBackground {
                Column(Modifier.fillMaxSize()) {
                    WindowTitleBar(
                        maximized = isWindowMaximized,
                        onMinimize = onMinimizeWindow,
                        onToggleMaximize = onToggleMaximizeWindow,
                        onClose = onCloseWindow,
                    )
                    AnimatedContent(
                        targetState = controller.isLyricsVisible,
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                        transitionSpec = {
                            if (targetState) {
                                (
                                    fadeIn(tween(220)) +
                                        slideInVertically(
                                            spring(
                                                dampingRatio = Spring.DampingRatioNoBouncy,
                                                stiffness = Spring.StiffnessMediumLow,
                                            ),
                                        ) { height -> height / 14 }
                                    ) togetherWith (
                                    fadeOut(tween(170)) + scaleOut(tween(220), targetScale = 0.985f)
                                    )
                            } else {
                                (
                                    fadeIn(tween(220)) + scaleIn(tween(260), initialScale = 0.985f)
                                    ) togetherWith (
                                    fadeOut(tween(150)) +
                                        slideOutVertically(
                                            spring(
                                                dampingRatio = Spring.DampingRatioNoBouncy,
                                                stiffness = Spring.StiffnessMediumLow,
                                            ),
                                        ) { height -> height / 14 }
                                    )
                            }
                        },
                        contentKey = { lyricsVisible -> lyricsVisible },
                        label = "main-lyrics-page",
                    ) { lyricsVisible ->
                        if (lyricsVisible) {
                            LyricsOverlay(controller = controller, modifier = Modifier.fillMaxSize())
                        } else {
                            Column(Modifier.fillMaxSize()) {
                                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                                    val compactNavigation = maxWidth < 1100.dp
                                    Row(Modifier.fillMaxSize()) {
                                        NavigationPanel(
                                            controller = controller,
                                            selectedDestination = destination,
                                            compact = compactNavigation,
                                            onDestinationSelected = { destination = it },
                                            onPlaylistSelected = {
                                                destination = DesktopDestination.LIBRARY
                                                controller.openPlaylist(it)
                                            },
                                            onOpenSettings = { settingsVisible = true },
                                        )
                                        MainContent(
                                            controller = controller,
                                            destination = destination,
                                            modifier = Modifier.weight(1f),
                                        )
                                    }
                                }
                                PlayerBar(controller)
                            }
                        }
                    }
                }

                if (controller.isLoginVisible) {
                    LoginOverlay(controller)
                }
                if (settingsVisible) {
                    DesktopSettingsDialog(
                        controller = controller,
                        onDismiss = { settingsVisible = false },
                    )
                }
            }
        }
        }
    }
}

@Composable
private fun WindowScope.WindowTitleBar(
    maximized: Boolean,
    onMinimize: () -> Unit,
    onToggleMaximize: () -> Unit,
    onClose: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier = Modifier.fillMaxWidth().height(42.dp).background(colors.surface.copy(alpha = 0.9f)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val titleModifier = Modifier.weight(1f).fillMaxHeight()
        if (maximized) {
            Box(titleModifier) { WindowTitleIdentity() }
        } else {
            WindowDraggableArea(titleModifier) { WindowTitleIdentity() }
        }
        WindowControlButton(Icons.Outlined.Remove, "最小化", onMinimize)
        WindowControlButton(if (maximized) Icons.Outlined.FilterNone else Icons.Outlined.CropSquare, if (maximized) "还原" else "最大化", onToggleMaximize)
        WindowControlButton(Icons.Outlined.Close, "关闭", onClose, close = true)
    }
}

@Composable
private fun WindowTitleIdentity() {
    val colors = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxSize().padding(start = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(20.dp).clip(RoundedCornerShape(7.dp)).background(colors.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "L",
                style = MaterialTheme.typography.labelSmall,
                color = colors.onPrimaryContainer,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text("Lazer", style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
    }
}

@Composable
private fun WindowControlButton(icon: ImageVector, description: String, onClick: () -> Unit, close: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    IconButton(
        onClick = onClick,
        modifier = Modifier.width(46.dp).fillMaxHeight(),
        colors = IconButtonDefaults.iconButtonColors(
            contentColor = if (close) colors.error else colors.onSurfaceVariant,
        ),
    ) {
        Icon(icon, description, Modifier.size(if (description == "关闭") 17.dp else 15.dp))
    }
}

@Composable
private fun PaperBackground(content: @Composable () -> Unit) {
    val colors = MaterialTheme.colorScheme
    // Calm paper sheet — no fiber dots / dashed noise.
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
    ) {
        content()
    }
}

private fun Color.luminanceValue(): Float = (red + green + blue) / 3f

@Composable
private fun NavigationPanel(
    controller: DesktopPlayerController,
    selectedDestination: DesktopDestination,
    compact: Boolean,
    onDestinationSelected: (DesktopDestination) -> Unit,
    onPlaylistSelected: (PlaylistItem) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val playlistScrollState = rememberScrollState()
    val inertia = LocalScrollInertia.current
    // width() (not requiredWidth) so a narrow window can still shrink the rail.
    val railWidth = if (compact) 72.dp else 208.dp
    Surface(
        modifier = Modifier
            .fillMaxHeight()
            .width(railWidth)
            .widthIn(max = railWidth),
        color = colors.surface.copy(alpha = 0.86f),
        border = androidx.compose.foundation.BorderStroke(1.dp, colors.outlineVariant.copy(alpha = 0.45f)),
    ) {
        Column(
            Modifier
                .fillMaxHeight()
                .padding(horizontal = if (compact) 10.dp else 14.dp, vertical = 18.dp),
            horizontalAlignment = if (compact) Alignment.CenterHorizontally else Alignment.Start,
        ) {
            BrandMark(compact)
            Spacer(Modifier.height(if (compact) 22.dp else 28.dp))

            DesktopDestination.entries.forEach { destination ->
                NavigationEntry(
                    destination = destination,
                    selected = destination == selectedDestination,
                    compact = compact,
                    themeEngine = controller.themeEngine,
                    onClick = { onDestinationSelected(destination) },
                )
                Spacer(Modifier.height(4.dp))
            }

            Spacer(Modifier.height(if (compact) 14.dp else 20.dp))
            HorizontalDivider(
                modifier = Modifier.fillMaxWidth(),
                thickness = 1.dp,
                color = colors.outlineVariant.copy(alpha = if (compact) 0.85f else 0.7f),
            )
            if (!compact) {
                Spacer(Modifier.height(16.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("你的歌单", style = MaterialTheme.typography.titleSmall, color = colors.onSurface)
                    Spacer(Modifier.weight(1f))
                    if (controller.isSignedIn) {
                        IconButton(onClick = controller::syncLibrary, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Outlined.Sync, "同步歌单", Modifier.size(16.dp), tint = colors.primary)
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
            } else {
                Spacer(Modifier.height(12.dp))
            }

            val playlists = controller.browsePlaylists()
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentAlignment = Alignment.TopStart,
            ) {
                when {
                    playlists.isEmpty() && !compact -> {
                        Text(
                            if (controller.isSignedIn) "暂时没有歌单" else "登录后在这里同步收藏",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                        )
                    }
                    playlists.isNotEmpty() -> {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .verticalScroll(playlistScrollState)
                                .scrollInertia(playlistScrollState, inertia),
                            horizontalAlignment = if (compact) Alignment.CenterHorizontally else Alignment.Start,
                            verticalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 0.dp),
                        ) {
                            playlists.forEach { playlist ->
                                SidebarPlaylistRow(
                                    playlist = playlist,
                                    selected = controller.activePlaylist?.id == playlist.id,
                                    compact = compact,
                                    onClick = { onPlaylistSelected(playlist) },
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
            NavigationUtilityEntry(
                icon = Icons.Outlined.Settings,
                label = "设置",
                compact = compact,
                onClick = onOpenSettings,
            )
        }
    }
}

@Composable
private fun NavigationUtilityEntry(
    icon: ImageVector,
    label: String,
    compact: Boolean,
    onClick: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .then(if (compact) Modifier.size(48.dp) else Modifier.fillMaxWidth())
            .clip(RoundedCornerShape(11.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = if (compact) 0.dp else 11.dp, vertical = if (compact) 0.dp else 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = if (compact) Arrangement.Center else Arrangement.Start,
    ) {
        Icon(icon, label, Modifier.size(19.dp), tint = colors.onSurfaceVariant)
        if (!compact) {
            Spacer(Modifier.width(11.dp))
            Text(label, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        }
    }
}

@Composable
private fun SidebarPlaylistRow(
    playlist: PlaylistItem,
    selected: Boolean,
    compact: Boolean,
    onClick: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    if (compact) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(if (selected) colors.primaryContainer.copy(alpha = 0.8f) else Color.Transparent)
                .clickable(onClick = onClick)
                .padding(4.dp),
            contentAlignment = Alignment.Center,
        ) {
            Artwork(
                id = playlist.id,
                title = playlist.title,
                coverUrl = playlist.coverUrl,
                modifier = Modifier.size(36.dp),
                cornerRadius = 9.dp,
            )
        }
        return
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) colors.primaryContainer.copy(alpha = 0.72f) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 6.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            id = playlist.id,
            title = playlist.title,
            coverUrl = playlist.coverUrl,
            modifier = Modifier.size(32.dp),
            cornerRadius = 8.dp,
        )
        Spacer(Modifier.width(10.dp))
        Text(
            playlist.title,
            style = MaterialTheme.typography.bodySmall,
            color = if (selected) colors.onPrimaryContainer else colors.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun BrandMark(compact: Boolean) {
    val colors = MaterialTheme.colorScheme
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(38.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(colors.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Text("L", color = colors.onPrimaryContainer, fontWeight = FontWeight.Bold, fontSize = 17.sp)
        }
        if (!compact) {
            Spacer(Modifier.width(10.dp))
            Column {
                Text("Lazer", style = MaterialTheme.typography.titleLarge)
            }
        }
    }
}

@Composable
private fun NavigationEntry(
    destination: DesktopDestination,
    selected: Boolean,
    compact: Boolean,
    themeEngine: LazerThemeEngine,
    onClick: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val selectedIconColor = if (themeEngine == LazerThemeEngine.MIUIX) Color.White else colors.primary
    Row(
        modifier = Modifier
            .then(if (compact) Modifier.size(48.dp) else Modifier.fillMaxWidth())
            .clip(RoundedCornerShape(11.dp))
            .background(if (selected) colors.primaryContainer else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = if (compact) 0.dp else 11.dp, vertical = if (compact) 0.dp else 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = if (compact) Arrangement.Center else Arrangement.Start,
    ) {
        Icon(
            destination.icon,
            contentDescription = destination.label,
            modifier = Modifier.size(19.dp),
            tint = if (selected) selectedIconColor else colors.onSurfaceVariant,
        )
        if (!compact) {
            Spacer(Modifier.width(11.dp))
            Text(
                destination.label,
                style = MaterialTheme.typography.bodyMedium,
                color = if (selected) colors.onPrimaryContainer else colors.onSurfaceVariant,
                fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            )
        }
    }
}

@Composable
private fun MainContent(
    controller: DesktopPlayerController,
    destination: DesktopDestination,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxHeight().padding(horizontal = 28.dp)) {
        TopBar(controller)
        when {
            controller.searchQuery.isNotBlank() -> SearchPage(controller, Modifier.weight(1f))
            destination == DesktopDestination.HOME -> HomePage(controller, Modifier.weight(1f))
            destination == DesktopDestination.DISCOVER -> DiscoverPage(controller, Modifier.weight(1f))
            destination == DesktopDestination.LIBRARY -> LibraryPage(controller, Modifier.weight(1f))
            else -> LikedPage(controller, Modifier.weight(1f))
        }
    }
}

@Composable
private fun DesktopSettingsDialog(
    controller: DesktopPlayerController,
    onDismiss: () -> Unit,
) {
    var followDelaySliderValue by remember(controller.lyricFollowDelayMillis) {
        mutableFloatStateOf(controller.lyricFollowDelayMillis.toFloat())
    }
    var gatewayBaseUrlDraft by remember(controller.gatewayBaseUrl) {
        mutableStateOf(controller.gatewayBaseUrl)
    }
    val displayedFollowDelay = normalizeLyricFollowDelayMillis(followDelaySliderValue.roundToLong())
    val normalizedGatewayBaseUrl = normalizeGatewayBaseUrl(gatewayBaseUrlDraft)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置") },
        text = {
            Column(
                modifier = Modifier
                    .widthIn(min = 480.dp)
                    .heightIn(max = 680.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text("外观", style = MaterialTheme.typography.titleSmall)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable {
                            controller.updateThemeEngine(
                                if (controller.themeEngine == LazerThemeEngine.MIUIX) {
                                    LazerThemeEngine.MATERIAL3
                                } else {
                                    LazerThemeEngine.MIUIX
                                },
                            )
                        }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Miuix 组件风格", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "当前：${controller.themeEngine.label} · 切换后立即生效",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    LazerThemeEngineSwitch(
                        engine = controller.themeEngine,
                        onEngineChange = controller::updateThemeEngine,
                    )
                }
                HorizontalDivider()
                if (isWindowsDesktop()) {
                    Text("播放", style = MaterialTheme.typography.titleSmall)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .clickable(role = androidx.compose.ui.semantics.Role.Switch) {
                                controller.updateExclusiveAudio(!controller.exclusiveAudio)
                            }
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("独占音频", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                if (controller.exclusiveAudio) {
                                    "播放时独占当前输出设备，其他应用会暂时无声"
                                } else {
                                    "与其他应用共享音频输出"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        LazerSwitch(
                            engine = controller.themeEngine,
                            checked = controller.exclusiveAudio,
                            onCheckedChange = null,
                        )
                    }
                    HorizontalDivider()
                }
                Text("歌词", style = MaterialTheme.typography.titleSmall)
                Text(
                    "手动滚动歌词后，经过所选时间恢复自动跟随。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("恢复跟随", style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.weight(1f))
                    Text(
                        lyricFollowDelayLabel(displayedFollowDelay),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                LazerSlider(
                    engine = controller.themeEngine,
                    value = followDelaySliderValue,
                    onValueChange = {
                        followDelaySliderValue = normalizeLyricFollowDelayMillis(it.roundToLong()).toFloat()
                    },
                    onValueChangeFinished = {
                        controller.updateLyricFollowDelay(displayedFollowDelay)
                    },
                    valueRange = MIN_LYRIC_FOLLOW_DELAY_MILLIS.toFloat()..MAX_LYRIC_FOLLOW_DELAY_MILLIS.toFloat(),
                    steps = LYRIC_FOLLOW_DELAY_OPTIONS_MILLIS.size - 2,
                )
                Row(Modifier.fillMaxWidth()) {
                    Text(
                        lyricFollowDelayLabel(MIN_LYRIC_FOLLOW_DELAY_MILLIS),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        lyricFollowDelayLabel(MAX_LYRIC_FOLLOW_DELAY_MILLIS),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                HorizontalDivider()
                Text("音乐服务", style = MaterialTheme.typography.titleSmall)
                Text(
                    "填写兼容服务的根地址。登录状态会继续沿用，请只使用你信任的提供商。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = gatewayBaseUrlDraft,
                    onValueChange = { gatewayBaseUrlDraft = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("服务地址") },
                    placeholder = { Text(DEFAULT_GATEWAY_BASE_URL) },
                    supportingText = if (gatewayBaseUrlDraft.isNotBlank() && normalizedGatewayBaseUrl == null) {
                        { Text("请输入有效的 HTTP 或 HTTPS 地址") }
                    } else {
                        null
                    },
                    isError = gatewayBaseUrlDraft.isNotBlank() && normalizedGatewayBaseUrl == null,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = { gatewayBaseUrlDraft = DEFAULT_GATEWAY_BASE_URL }) {
                        Text("恢复默认")
                    }
                    Spacer(Modifier.width(8.dp))
                    Button(
                        onClick = {
                            normalizedGatewayBaseUrl?.let(controller::updateGatewayBaseUrl)
                        },
                        enabled = normalizedGatewayBaseUrl != null &&
                            normalizedGatewayBaseUrl != controller.gatewayBaseUrl,
                    ) {
                        Text("保存")
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("完成") } },
    )
}

@Composable
private fun TopBar(controller: DesktopPlayerController) {
    var accountMenuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        NaturalLanguageField(
            value = controller.searchQuery,
            onValueChange = controller::updateSearchQuery,
            modifier = Modifier.weight(1f).widthIn(max = 650.dp),
        )
        Spacer(Modifier.weight(0.18f))
        GatewayStatus(controller)
        Spacer(Modifier.width(8.dp))
        IconButton(
            onClick = controller::toggleTheme,
            modifier = Modifier.size(40.dp),
            colors = IconButtonDefaults.iconButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        ) {
            Icon(
                if (controller.isDark) Icons.Outlined.LightMode else Icons.Outlined.DarkMode,
                "切换明暗主题",
                Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(8.dp))
        Box {
            IconButton(
                onClick = {
                    if (controller.isSignedIn) accountMenuOpen = true else controller.openLogin()
                },
                modifier = Modifier.size(40.dp),
                colors = IconButtonDefaults.iconButtonColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
            ) {
                if (controller.isSignedIn) {
                    UserAvatar(
                        controller.currentUser?.nickname ?: "你",
                        controller.currentUser?.avatarUrl,
                        Modifier.size(32.dp),
                    )
                } else {
                    Icon(Icons.Outlined.Person, "登录", Modifier.size(18.dp))
                }
            }
            if (accountMenuOpen && controller.isSignedIn) {
                Popup(
                    alignment = Alignment.TopEnd,
                    offset = IntOffset(0, 48),
                    onDismissRequest = { accountMenuOpen = false },
                    properties = PopupProperties(focusable = true),
                ) {
                    val colors = MaterialTheme.colorScheme
                    Surface(
                        shape = RoundedCornerShape(14.dp),
                        color = colors.surface,
                        shadowElevation = 8.dp,
                        border = androidx.compose.foundation.BorderStroke(1.dp, colors.outlineVariant),
                        modifier = Modifier.width(188.dp),
                    ) {
                        Column(Modifier.padding(vertical = 8.dp, horizontal = 6.dp)) {
                            Text(
                                controller.currentUser?.nickname.orEmpty(),
                                style = MaterialTheme.typography.titleSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                            )
                            TextButton(
                                onClick = {
                                    accountMenuOpen = false
                                    controller.syncLibrary()
                                },
                                modifier = Modifier.fillMaxWidth(),
                                contentPadding = PaddingValues(horizontal = 10.dp),
                            ) {
                                Icon(Icons.Outlined.Sync, null, Modifier.size(16.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("同步歌单", modifier = Modifier.weight(1f), textAlign = TextAlign.Start)
                            }
                            TextButton(
                                onClick = {
                                    accountMenuOpen = false
                                    controller.logout()
                                },
                                modifier = Modifier.fillMaxWidth(),
                                contentPadding = PaddingValues(horizontal = 10.dp),
                                colors = ButtonDefaults.textButtonColors(contentColor = colors.error),
                            ) {
                                Icon(Icons.AutoMirrored.Outlined.Logout, null, Modifier.size(16.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("退出登录", modifier = Modifier.weight(1f), textAlign = TextAlign.Start)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun NaturalLanguageField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.height(50.dp),
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyMedium.copy(
            color = colors.onSurface,
            lineHeight = 22.sp,
        ),
        cursorBrush = SolidColor(colors.primary),
        decorationBox = { innerTextField ->
            Row(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(15.dp))
                    .background(colors.surface.copy(alpha = 0.86f))
                    .border(1.dp, colors.outlineVariant, RoundedCornerShape(15.dp))
                    .padding(horizontal = 15.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Search, null, Modifier.size(19.dp), tint = colors.primary)
                Spacer(Modifier.width(10.dp))
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (value.isEmpty()) {
                        Text(
                            "搜索...",
                            style = MaterialTheme.typography.bodyMedium,
                            color = colors.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    innerTextField()
                }
                if (value.isNotEmpty()) {
                    IconButton(onClick = { onValueChange("") }, modifier = Modifier.size(30.dp)) {
                        Icon(Icons.Outlined.Close, "清空搜索", Modifier.size(16.dp), tint = colors.onSurfaceVariant)
                    }
                }
            }
        },
    )
}

/** A fixed-size status slot prevents Gateway activity from shifting x/y positions in the top bar. */
@Composable
private fun GatewayStatus(controller: DesktopPlayerController) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = Modifier.width(196.dp).height(40.dp),
        shape = RoundedCornerShape(12.dp),
        color = colors.surface.copy(alpha = 0.62f),
        border = androidx.compose.foundation.BorderStroke(1.dp, colors.outlineVariant.copy(alpha = 0.75f)),
    ) {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                if (controller.isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(15.dp),
                        strokeWidth = 1.7.dp,
                        color = colors.primary,
                    )
                } else {
                    Icon(Icons.Outlined.CloudDone, null, Modifier.size(17.dp), tint = colors.primary)
                }
            }
            Spacer(Modifier.width(7.dp))
            Text(
                controller.statusMessage ?: if (controller.isSignedIn) "个人音乐已同步" else "音乐服务已连接",
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun HomePage(controller: DesktopPlayerController, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    val inertia = LocalScrollInertia.current
    LazyColumn(
        state = listState,
        modifier = modifier
            .fillMaxWidth()
            .scrollInertia(listState, inertia),
        contentPadding = PaddingValues(top = 18.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        item {
            Column {
                SectionHeading(
                    if (controller.isSignedIn) "今天为你整理" else "最近有人在听",
                    if (controller.isSignedIn) "来自你的听歌偏好" else "登录后会换成你的每日推荐",
                )
                Spacer(Modifier.height(12.dp))
                PlaylistStrip(controller.featuredPlaylists.take(8), controller::openPlaylist)
            }
        }
        item {
            TrackSection(
                title = controller.activePlaylistTitle ?: "接着听",
                tracks = controller.recentTracks.take(8),
                onPlay = controller::playTrack,
            )
        }
    }
}

@Composable
private fun IntentSuggestions(controller: DesktopPlayerController) {
    val suggestions = listOf("适合专注写作的纯音乐", "傍晚散步，轻一点", "熟悉但不吵的华语歌", "雨天慢节奏")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        suggestions.forEach { suggestion ->
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.74f),
                border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.clickable { controller.useIntentSuggestion(suggestion) },
            ) {
                Text(
                    suggestion,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 13.dp, vertical = 9.dp),
                )
            }
        }
    }
}

@Composable
private fun DiscoverPage(controller: DesktopPlayerController, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    val inertia = LocalScrollInertia.current
    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxWidth().scrollInertia(listState, inertia),
        contentPadding = PaddingValues(top = 22.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        item {
            PageHeading("慢慢发现", "从编辑精选到每日推荐，内容会跟着你的听歌习惯变化。")
        }
        item { PlaylistStrip(controller.featuredPlaylists, controller::openPlaylist) }
        item { TrackSection("正在流动", controller.recentTracks.take(12), controller::playTrack) }
    }
}

@Composable
private fun LibraryPage(controller: DesktopPlayerController, modifier: Modifier = Modifier) {
    val active = controller.activePlaylist
    val browsing = controller.browsePlaylists()
    val listState = rememberLazyListState()
    val inertia = LocalScrollInertia.current
    val currentTrackIndex = if (active?.isLikedCollection == false) {
        controller.recentTracks.indexOfFirst { it.id == controller.nowPlaying?.id }
    } else {
        -1
    }
    val scope = rememberCoroutineScope()
    Box(modifier = modifier.fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().scrollInertia(listState, inertia),
            contentPadding = PaddingValues(
                top = 22.dp,
                bottom = if (currentTrackIndex >= 0) 96.dp else 28.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            when {
                !controller.isSignedIn -> {
                    item { PageHeading("你的音乐库", "登录后，歌单会出现在这里。") }
                    item { SignInInvitation(controller::openLogin) }
                }
                browsing.isEmpty() && active == null -> {
                    item {
                        Row(verticalAlignment = Alignment.Bottom) {
                            PageHeading("你的音乐库", "歌单与收藏已通过 Gateway 保持同步。")
                            Spacer(Modifier.weight(1f))
                            TextButton(onClick = controller::syncLibrary) {
                                Icon(Icons.Outlined.Refresh, null, Modifier.size(16.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("同步歌单")
                            }
                        }
                    }
                    item { QuietEmptyState("还没有歌单", "在网易云音乐中新建歌单后，再点一次同步歌单。") }
                }
                active != null && (active.isLikedCollection.not()) -> {
                    item { PlaylistDetailHeader(active, onPlayAll = { active.let { controller.recentTracks.firstOrNull()?.let(controller::playTrack) } }) }
                    if (controller.recentTracks.isEmpty()) {
                        item {
                            QuietEmptyState(
                                if (controller.isLoading) "正在整理歌曲" else "这个歌单还是空的",
                                if (controller.isLoading) "封面与曲目正在同步。" else "换一个歌单看看。",
                            )
                        }
                    } else {
                        itemsIndexed(controller.recentTracks, key = { _, track -> track.id }) { index, track ->
                            TrackRow(track, track.id == controller.nowPlaying?.id, { controller.playTrack(track) }, index + 1)
                        }
                    }
                }
                else -> {
                    item {
                        Row(verticalAlignment = Alignment.Bottom) {
                            PageHeading("你的音乐库", "点开一个歌单，封面与曲目会出现在这里。")
                            Spacer(Modifier.weight(1f))
                            TextButton(onClick = controller::syncLibrary) {
                                Icon(Icons.Outlined.Refresh, null, Modifier.size(16.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("同步歌单")
                            }
                        }
                    }
                    item { PlaylistStrip(browsing, controller::openPlaylist) }
                }
            }
        }
        if (currentTrackIndex >= 0) {
            NowPlayingLocatorButton(
                onClick = {
                    inertia.stop()
                    scope.launch { listState.animateScrollToItem(currentTrackIndex + 1) }
                },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 22.dp, bottom = 22.dp),
            )
        }
    }
}

@Composable
private fun LikedPage(controller: DesktopPlayerController, modifier: Modifier = Modifier) {
    LaunchedEffect(controller.isSignedIn, controller.likedPlaylist()?.id) {
        if (controller.isSignedIn) controller.openLikedCollection()
    }
    val playlist = controller.activePlaylist?.takeIf { it.isLikedCollection }
        ?: controller.likedPlaylist()
        ?: PlaylistItem(
            id = -5L,
            title = "我喜欢",
            subtitle = "私人收藏",
            coverUrl = controller.likedTracks.firstOrNull()?.coverUrl,
            trackCount = controller.likedTracks.size,
            creatorName = controller.currentUser?.nickname,
            isLikedCollection = true,
        )
    val tracks = if (controller.activePlaylist?.isLikedCollection == true) {
        controller.recentTracks
    } else {
        controller.likedTracks
    }
    val listState = rememberLazyListState()
    val inertia = LocalScrollInertia.current
    val currentTrackIndex = tracks.indexOfFirst { it.id == controller.nowPlaying?.id }
    val scope = rememberCoroutineScope()
    Box(modifier = modifier.fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().scrollInertia(listState, inertia),
            contentPadding = PaddingValues(
                top = 22.dp,
                bottom = if (currentTrackIndex >= 0) 96.dp else 28.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            when {
                !controller.isSignedIn -> {
                    item { PageHeading("我喜欢", "登录后，喜欢状态会和你的账号保持一致。") }
                    item { SignInInvitation(controller::openLogin) }
                }
                else -> {
                    item {
                        PlaylistDetailHeader(
                            playlist = playlist.copy(
                                title = "我喜欢",
                                trackCount = tracks.size.takeIf { it > 0 } ?: playlist.trackCount,
                                coverUrl = playlist.coverUrl ?: tracks.firstOrNull()?.coverUrl,
                            ),
                            onPlayAll = { tracks.firstOrNull()?.let(controller::playTrack) },
                        )
                    }
                    if (tracks.isEmpty()) {
                        item {
                            QuietEmptyState(
                                if (controller.isLoading) "正在整理喜欢的歌" else "这里还很安静",
                                if (controller.isLoading) "按你收藏时的顺序同步中。" else "播放一首歌，点亮播放栏里的心形即可收藏。",
                            )
                        }
                    } else {
                        itemsIndexed(tracks, key = { _, track -> track.id }) { index, track ->
                            TrackRow(track, track.id == controller.nowPlaying?.id, { controller.playTrack(track) }, index + 1)
                        }
                    }
                }
            }
        }
        if (controller.isSignedIn && currentTrackIndex >= 0) {
            NowPlayingLocatorButton(
                onClick = {
                    inertia.stop()
                    scope.launch { listState.animateScrollToItem(currentTrackIndex + 1) }
                },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 22.dp, bottom = 22.dp),
            )
        }
    }
}

@Composable
private fun NowPlayingLocatorButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    ExtendedFloatingActionButton(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = MaterialTheme.colorScheme.primary,
        elevation = FloatingActionButtonDefaults.elevation(defaultElevation = 4.dp, pressedElevation = 2.dp),
        icon = { Icon(Icons.Outlined.MyLocation, null, Modifier.size(18.dp)) },
        text = { Text("定位当前歌曲", style = MaterialTheme.typography.labelLarge) },
    )
}

@Composable
private fun PlaylistDetailHeader(playlist: PlaylistItem, onPlayAll: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Artwork(
            id = playlist.id,
            title = playlist.title,
            coverUrl = playlist.coverUrl,
            modifier = Modifier.size(148.dp),
            cornerRadius = 18.dp,
        )
        Spacer(Modifier.width(22.dp))
        Column(
            modifier = Modifier.weight(1f).padding(top = 6.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                if (playlist.isLikedCollection) "我喜欢" else playlist.title,
                style = MaterialTheme.typography.headlineMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val creator = playlist.creatorName?.takeIf { it.isNotBlank() }
            if (creator != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(22.dp)
                            .clip(CircleShape)
                            .background(colors.primaryContainer),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            creator.first().toString(),
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onPrimaryContainer,
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(creator, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                }
            }
            Text(
                buildString {
                    val count = playlist.trackCount
                    if (count > 0) append("$count 首") else append("整理中")
                    playlist.creatorName?.takeIf { it.isNotBlank() }?.let {
                        // creator already shown above; keep the meta line minimal
                    }
                },
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = onPlayAll,
                shape = RoundedCornerShape(12.dp),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Icon(Icons.Filled.PlayArrow, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("播放全部")
            }
        }
    }
}

@Composable
private fun SearchPage(controller: DesktopPlayerController, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    val inertia = LocalScrollInertia.current
    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxWidth().scrollInertia(listState, inertia),
        contentPadding = PaddingValues(top = 22.dp, bottom = 28.dp),
    ) {
        item {
            PageHeading("关于「${controller.searchQuery}」", "Lazer 正在按你的描述整理歌曲。")
            Spacer(Modifier.height(22.dp))
        }
        if (controller.searchResults.isEmpty() && !controller.isLoading) {
            item { QuietEmptyState("还没有合适的结果", "试着加入一种心情、场景或语言。") }
        } else {
            items(controller.searchResults, key = { it.id }) { track ->
                TrackRow(track, track.id == controller.nowPlaying?.id, { controller.playTrack(track) })
            }
        }
    }
}

@Composable
private fun PageHeading(title: String, subtitle: String) {
    Column(Modifier.widthIn(max = 720.dp)) {
        Text(title, style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(5.dp))
        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SectionHeading(title: String, subtitle: String) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.width(12.dp))
        Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun PlaylistStrip(playlists: List<PlaylistItem>, onPlaylistClick: (PlaylistItem) -> Unit) {
    if (playlists.isEmpty()) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            repeat(4) { index -> PlaylistPlaceholder(index) }
        }
        return
    }
    val listState = rememberLazyListState()
    val inertia = LocalScrollInertia.current
    val scope = rememberCoroutineScope()
    var stripHovered by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .onPointerEvent(PointerEventType.Enter) { stripHovered = true }
            .onPointerEvent(PointerEventType.Exit) { stripHovered = false },
    ) {
        LazyRow(
            state = listState,
            modifier = Modifier.fillMaxWidth().scrollInertia(listState, inertia, Orientation.Horizontal),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(end = 12.dp),
        ) {
            items(playlists, key = { it.id }) { playlist ->
                PlaylistTile(playlist, onClick = { onPlaylistClick(playlist) })
            }
        }
        AnimatedVisibility(
            visible = stripHovered && (listState.canScrollBackward || listState.canScrollForward),
            modifier = Modifier.matchParentSize(),
            enter = fadeIn(tween(durationMillis = 220, easing = FastOutSlowInEasing)),
            exit = fadeOut(tween(durationMillis = 140, easing = FastOutSlowInEasing)),
        ) {
            Box(Modifier.fillMaxSize()) {
                if (listState.canScrollBackward) {
                    PlaylistStripScrollButton(
                        icon = Icons.AutoMirrored.Outlined.ArrowBack,
                        description = "查看前面的歌单",
                        modifier = Modifier.align(Alignment.CenterStart).padding(start = 4.dp),
                        onClick = {
                            scope.launch {
                                listState.animateScrollToItem(
                                    (listState.firstVisibleItemIndex - 3).coerceAtLeast(0),
                                )
                            }
                        },
                    )
                }
                if (listState.canScrollForward) {
                    PlaylistStripScrollButton(
                        icon = Icons.AutoMirrored.Outlined.ArrowForward,
                        description = "查看后面的歌单",
                        modifier = Modifier.align(Alignment.CenterEnd).padding(end = 4.dp),
                        onClick = {
                            scope.launch {
                                listState.animateScrollToItem(
                                    (listState.firstVisibleItemIndex + 3).coerceAtMost(playlists.lastIndex),
                                )
                            }
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun PlaylistStripScrollButton(
    icon: ImageVector,
    description: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    IconButton(
        onClick = onClick,
        modifier = modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(colors.surface.copy(alpha = 0.96f))
            .border(1.dp, colors.outlineVariant.copy(alpha = 0.78f), CircleShape),
        colors = IconButtonDefaults.iconButtonColors(
            contentColor = colors.onSurface,
        ),
    ) {
        Icon(icon, contentDescription = description, modifier = Modifier.size(19.dp))
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun PlaylistTile(playlist: PlaylistItem, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    var hovered by remember { mutableStateOf(false) }
    val maskAlpha by animateFloatAsState(
        targetValue = if (hovered) 0.18f else 0f,
        animationSpec = tween(durationMillis = if (hovered) 180 else 130, easing = FastOutSlowInEasing),
        label = "playlist-tile-mask",
    )
    val coverShape = RoundedCornerShape(16.dp)
    Column(
        Modifier
            .width(148.dp)
            .onPointerEvent(PointerEventType.Enter) { hovered = true }
            .onPointerEvent(PointerEventType.Exit) { hovered = false }
            .clickable(onClick = onClick),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(148.dp)
                .clip(coverShape),
        ) {
            Artwork(
                playlist.id,
                playlist.title,
                playlist.coverUrl,
                Modifier.matchParentSize(),
                cornerRadius = 16.dp,
            )
            Box(
                Modifier
                    .matchParentSize()
                    .background(colors.scrim.copy(alpha = maskAlpha)),
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(playlist.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(2.dp))
        Text(
            playlist.subtitle,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PlaylistPlaceholder(index: Int) {
    Column(Modifier.width(148.dp)) {
        Box(
            Modifier.fillMaxWidth().height(148.dp).clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.66f)),
        )
        Spacer(Modifier.height(10.dp))
        Box(Modifier.width((100 + index * 7).dp).height(10.dp).clip(CircleShape).background(MaterialTheme.colorScheme.outlineVariant))
    }
}

@Composable
private fun Artwork(
    id: Long,
    title: String,
    coverUrl: String?,
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 18.dp,
) {
    val gradient = calmArtwork[(id.hashCode().absoluteValue) % calmArtwork.size]
    val shape = RoundedCornerShape(cornerRadius)
    val sizedUrl = remember(coverUrl) { coverUrl?.toArtworkUrl() }
    Box(
        modifier.clip(shape).background(Brush.linearGradient(gradient)),
        contentAlignment = Alignment.Center,
    ) {
        ArtworkFallback(title, gradient)
        if (sizedUrl != null) {
            AsyncImage(
                model = sizedUrl,
                contentDescription = "$title 封面",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }
    }
}

@Composable
private fun ArtworkFallback(title: String, gradient: List<Color>) {
    Box(
        Modifier.fillMaxSize().background(Brush.linearGradient(gradient)),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.fillMaxSize(0.52f).clip(CircleShape).border(1.dp, Color.White.copy(alpha = 0.62f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(title.firstOrNull()?.toString() ?: "L", color = Color.White, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun UserAvatar(name: String, avatarUrl: String?, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val sizedUrl = remember(avatarUrl) { avatarUrl?.toArtworkUrl() }
    Box(
        modifier.clip(CircleShape).background(colors.primaryContainer),
        contentAlignment = Alignment.Center,
    ) {
        AvatarFallback(name)
        if (sizedUrl != null) {
            AsyncImage(
                model = sizedUrl,
                contentDescription = "$name 的头像",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }
    }
}

@Composable
private fun AvatarFallback(name: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            name.firstOrNull()?.toString() ?: "你",
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            fontWeight = FontWeight.SemiBold,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

private fun String.toArtworkUrl(): String {
    val trimmed = trim()
    if (trimmed.isEmpty()) return trimmed
    val withScheme = when {
        trimmed.startsWith("//") -> "https:$trimmed"
        trimmed.startsWith("http://") -> "https://" + trimmed.removePrefix("http://")
        else -> trimmed
    }
    if ("param=" in withScheme) return withScheme
    return withScheme + if ('?' in withScheme) "&param=256y256" else "?param=256y256"
}

@Composable
private fun TrackSection(title: String, tracks: List<TrackItem>, onPlay: (TrackItem) -> Unit) {
    Column {
        SectionHeading(title, if (tracks.isEmpty()) "正在整理" else "${tracks.size} 首")
        Spacer(Modifier.height(10.dp))
        if (tracks.isEmpty()) {
            QuietEmptyState("音乐还在路上", "连接成功后会自动出现在这里。")
        } else {
            tracks.forEachIndexed { index, track ->
                TrackRow(track, false, { onPlay(track) }, index + 1)
            }
        }
    }
}

@Composable
private fun TrackRow(
    track: TrackItem,
    selected: Boolean,
    onClick: () -> Unit,
    index: Int? = null,
) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(11.dp))
            .background(if (selected) colors.primaryContainer.copy(alpha = 0.68f) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = index?.toString() ?: "♪",
            modifier = Modifier.width(28.dp),
            style = MaterialTheme.typography.labelSmall,
            color = if (selected) colors.primary else colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.width(8.dp))
        Artwork(
            track.id,
            track.title,
            track.coverUrl,
            Modifier.size(44.dp),
            cornerRadius = 10.dp,
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1.2f)) {
            Text(track.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(track.artist, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(
            track.album,
            modifier = Modifier.weight(0.8f),
            style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(track.durationLabel, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant, modifier = Modifier.width(48.dp))
        IconButton(onClick = onClick, modifier = Modifier.size(30.dp)) {
            Icon(Icons.Filled.PlayArrow, "播放 ${track.title}", Modifier.size(17.dp), tint = colors.primary)
        }
    }
}

@Composable
private fun SignInInvitation(onLogin: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(22.dp), color = colors.primaryContainer.copy(alpha = 0.74f)) {
        Row(Modifier.fillMaxWidth().padding(24.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(48.dp).clip(CircleShape).background(colors.surface), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Person, null, tint = colors.primary)
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text("登录后继续", style = MaterialTheme.typography.titleLarge)
                Text("优先使用二维码，不需要在电脑上输入密码。", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
            }
            Button(onClick = onLogin, shape = RoundedCornerShape(11.dp)) { Text("扫码登录") }
        }
    }
}

@Composable
private fun QuietEmptyState(title: String, body: String) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.62f),
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.72f)),
    ) {
        Column(Modifier.padding(22.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(3.dp))
            Text(body, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun PlayerBar(controller: DesktopPlayerController) {
    val colors = MaterialTheme.colorScheme
    val displayProgress by animateFloatAsState(
        targetValue = controller.progress.coerceIn(0f, 1f),
        animationSpec = when {
            controller.isSeeking || !controller.isPlaying -> snap()
            else -> spring(
                dampingRatio = Spring.DampingRatioNoBouncy,
                stiffness = Spring.StiffnessHigh,
                visibilityThreshold = 0.0001f,
            )
        },
        label = "playback-progress",
    )
    Surface(
        modifier = Modifier.fillMaxWidth().height(84.dp),
        color = colors.surface.copy(alpha = 0.96f),
        border = androidx.compose.foundation.BorderStroke(1.dp, colors.outlineVariant.copy(alpha = 0.7f)),
    ) {
        Row(Modifier.fillMaxSize().padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.width(250.dp), verticalAlignment = Alignment.CenterVertically) {
                var nowPlayingHovered by remember { mutableStateOf(false) }
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(14.dp))
                        .background(
                            if (nowPlayingHovered) {
                                colors.surfaceVariant.copy(alpha = 0.55f)
                            } else {
                                Color.Transparent
                            },
                        )
                        .clickable(onClick = controller::openLyrics)
                        .onPointerEvent(PointerEventType.Enter) { nowPlayingHovered = true }
                        .onPointerEvent(PointerEventType.Exit) { nowPlayingHovered = false }
                        .padding(horizontal = 6.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Artwork(
                        controller.nowPlaying?.id ?: 0,
                        controller.nowPlaying?.title ?: "L",
                        controller.nowPlaying?.coverUrl,
                        Modifier.size(50.dp).clip(RoundedCornerShape(12.dp)),
                        cornerRadius = 12.dp,
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            controller.nowPlaying?.title ?: "选一首音乐开始",
                            style = MaterialTheme.typography.titleSmall,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            controller.nowPlaying?.artist ?: "Lazer",
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                IconButton(onClick = controller::toggleLiked, modifier = Modifier.size(30.dp)) {
                    Icon(
                        if (controller.isLiked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder,
                        "喜欢",
                        Modifier.size(17.dp),
                        tint = if (controller.isLiked) colors.tertiary else colors.onSurfaceVariant,
                    )
                }
            }

            Column(Modifier.weight(1f).padding(horizontal = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    CompactIconButton(Icons.Outlined.Shuffle, controller::toggleShuffle, "随机播放", controller.shuffle)
                    CompactIconButton(Icons.Filled.SkipPrevious, controller::playPrevious, "上一首")
                    IconButton(
                        onClick = controller::togglePlayPause,
                        modifier = Modifier.size(38.dp),
                        colors = IconButtonDefaults.iconButtonColors(containerColor = colors.primary, contentColor = colors.onPrimary),
                    ) {
                        Icon(if (controller.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (controller.isPlaying) "暂停" else "播放", Modifier.size(21.dp))
                    }
                    CompactIconButton(Icons.Filled.SkipNext, controller::playNext, "下一首")
                    CompactIconButton(Icons.Outlined.Repeat, controller::toggleRepeat, "循环播放", controller.repeat)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val total = controller.nowPlaying?.durationLabel ?: "00:00"
                    val elapsed = controller.nowPlaying?.let {
                        formatDuration((it.durationMillis * displayProgress).roundToInt().toLong())
                    } ?: "00:00"
                    Text(elapsed, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                    ThinSeekBar(
                        progress = if (controller.isSeeking) controller.progress else displayProgress,
                        bufferedProgress = controller.bufferedProgress,
                        onSeek = controller::seekTo,
                        onSeekFinished = controller::commitSeek,
                        modifier = Modifier.weight(1f).padding(horizontal = 10.dp),
                    )
                    Text(total, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                }
            }

            Row(
                Modifier.widthIn(min = 140.dp).width(168.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.End,
            ) {
                VolumePanelControl(controller.volume, controller::updateVolume)
                Spacer(Modifier.width(2.dp))
                QualityControl(
                    quality = controller.audioQuality,
                    onQualityChange = controller::updateAudioQuality,
                    bitrate = controller.streamBitrate,
                )
                Spacer(Modifier.width(2.dp))
                CompactIconButton(
                    Icons.Outlined.Lyrics,
                    controller::openLyrics,
                    "歌词",
                    selected = controller.isLyricsVisible,
                )
                Spacer(Modifier.width(2.dp))
                CompactIconButton(Icons.AutoMirrored.Outlined.QueueMusic, {}, "播放队列")
            }
        }
    }
}

@Composable
private fun ThinSeekBar(
    progress: Float,
    bufferedProgress: Float = progress,
    onSeek: (Float) -> Unit,
    onSeekFinished: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val fraction = progress.coerceIn(0f, 1f)
    val bufferedFraction = maxOf(fraction, bufferedProgress.coerceIn(0f, 1f))
    val currentOnSeek by rememberUpdatedState(onSeek)
    val currentOnSeekFinished by rememberUpdatedState(onSeekFinished)
    BoxWithConstraints(
        modifier
            .height(14.dp)
            .fillMaxWidth()
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val width = size.width.coerceAtLeast(1)
                    currentOnSeek((down.position.x / width).coerceIn(0f, 1f))
                    down.consume()

                    var finished = false
                    while (!finished) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id }
                        if (change == null) {
                            currentOnSeekFinished()
                            finished = true
                        } else {
                            currentOnSeek((change.position.x / width).coerceIn(0f, 1f))
                            change.consume()
                            if (!change.pressed) {
                                currentOnSeekFinished()
                                finished = true
                            }
                        }
                    }
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        val thumbTravel = (maxWidth - 10.dp).coerceAtLeast(0.dp)
        Box(
            Modifier
                .fillMaxWidth()
                .height(3.dp)
                .clip(CircleShape)
                .background(colors.surfaceVariant.copy(alpha = 0.95f)),
        )
        Box(
            Modifier
                .fillMaxWidth(bufferedFraction)
                .height(3.dp)
                .clip(CircleShape)
                .background(colors.onSurfaceVariant.copy(alpha = 0.34f)),
        )
        Box(
            Modifier
                .fillMaxWidth(fraction)
                .height(3.dp)
                .clip(CircleShape)
                .background(colors.primary),
        )
        Box(
            Modifier
                .offset(x = thumbTravel * fraction)
                .size(10.dp)
                .clip(CircleShape)
                .background(colors.primary),
        )
    }
}

@Composable
private fun CompactIconButton(icon: ImageVector, onClick: () -> Unit, description: String, selected: Boolean = false) {
    IconButton(onClick = onClick, modifier = Modifier.size(30.dp)) {
        Icon(icon, description, Modifier.size(18.dp), tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun VolumePanelControl(
    volume: Float,
    onVolumeChange: (Float) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    var iconHovered by remember { mutableStateOf(false) }
    var panelHovered by remember { mutableStateOf(false) }
    var showPanel by remember { mutableStateOf(false) }
    LaunchedEffect(iconHovered, panelHovered) {
        if (iconHovered || panelHovered) {
            showPanel = true
        } else {
            delay(160)
            if (!iconHovered && !panelHovered) showPanel = false
        }
    }
    Box(
        Modifier
            .size(30.dp)
            .onPointerEvent(PointerEventType.Enter) { iconHovered = true }
            .onPointerEvent(PointerEventType.Exit) { iconHovered = false },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (volume <= 0.001f) Icons.AutoMirrored.Outlined.VolumeOff else Icons.AutoMirrored.Outlined.VolumeUp,
            "音量",
            Modifier.size(18.dp),
            tint = if (showPanel) colors.primary else colors.onSurfaceVariant,
        )
        if (showPanel) {
            Popup(
                alignment = Alignment.TopCenter,
                offset = IntOffset(0, -12),
                properties = PopupProperties(focusable = false),
            ) {
                Surface(
                    modifier = Modifier
                        .width(196.dp)
                        .onPointerEvent(PointerEventType.Enter) { panelHovered = true }
                        .onPointerEvent(PointerEventType.Exit) { panelHovered = false },
                    shape = RoundedCornerShape(16.dp),
                    color = colors.surface.copy(alpha = 0.98f),
                    shadowElevation = 8.dp,
                    border = androidx.compose.foundation.BorderStroke(1.dp, colors.outlineVariant.copy(alpha = 0.85f)),
                ) {
                    Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                        Text(
                            "音量 ${(volume * 100).roundToInt()}%",
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(8.dp))
                        ThinSeekBar(
                            progress = volume,
                            onSeek = onVolumeChange,
                            onSeekFinished = {},
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun QualityControl(
    quality: AudioQuality,
    onQualityChange: (AudioQuality) -> Unit,
    bitrate: Int?,
) {
    val colors = MaterialTheme.colorScheme
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { menuOpen = true },
            modifier = Modifier.size(30.dp),
        ) {
            Icon(
                Icons.Outlined.HighQuality,
                "播放音质",
                Modifier.size(18.dp),
                tint = if (menuOpen) colors.primary else colors.onSurfaceVariant,
            )
        }
        if (menuOpen) {
            Popup(
                alignment = Alignment.TopEnd,
                offset = IntOffset(0, -8),
                onDismissRequest = { menuOpen = false },
                properties = PopupProperties(focusable = true),
            ) {
                Surface(
                    modifier = Modifier.width(168.dp),
                    shape = RoundedCornerShape(16.dp),
                    color = colors.surface,
                    shadowElevation = 8.dp,
                    border = androidx.compose.foundation.BorderStroke(1.dp, colors.outlineVariant),
                ) {
                    Column(Modifier.padding(vertical = 8.dp, horizontal = 6.dp)) {
                        Text(
                            "播放音质",
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                        )
                        listOf(
                            AudioQuality.STANDARD,
                            AudioQuality.HIGHER,
                            AudioQuality.EXHIGH,
                            AudioQuality.LOSSLESS,
                            AudioQuality.HI_RES,
                            AudioQuality.JYMASTER,
                        ).forEach { option ->
                            val selected = option == quality
                            TextButton(
                                onClick = {
                                    onQualityChange(option)
                                    menuOpen = false
                                },
                                modifier = Modifier.fillMaxWidth().height(32.dp),
                                contentPadding = PaddingValues(horizontal = 10.dp),
                                colors = ButtonDefaults.textButtonColors(
                                    contentColor = if (selected) colors.primary else colors.onSurfaceVariant,
                                    containerColor = if (selected) colors.primaryContainer else Color.Transparent,
                                ),
                                shape = RoundedCornerShape(8.dp),
                            ) {
                                Text(
                                    option.label,
                                    style = MaterialTheme.typography.labelMedium,
                                    modifier = Modifier.weight(1f),
                                    textAlign = TextAlign.Start,
                                )
                                if (selected) {
                                    Icon(Icons.Outlined.CheckCircle, null, Modifier.size(14.dp), tint = colors.primary)
                                }
                            }
                        }
                        bitrate?.let {
                            Text(
                                "当前 ${it / 1000} kbps",
                                style = MaterialTheme.typography.labelSmall,
                                color = colors.onSurfaceVariant,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun LyricsOverlay(
    controller: DesktopPlayerController,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val lines = controller.lyrics
    // The lyric index observes the exact same playback position as the seek bar. derivedStateOf
    // avoids recomposing the full lyric page for progress ticks that remain within one line.
    val activeIndex by remember(lines, controller) {
        derivedStateOf { findCurrentLyricIndex(lines, controller.positionMillis) }
    }

    // Original lyric plus its translation share one row, so keep a taller pitch and center
    // the original lyric line within each row.
    val rowPitchPx = with(density) { 112.dp.toPx() }
    val baseFontSp = 34.sp
    val baseLineHeightSp = 48.sp

    var followPlayback by remember { mutableStateOf(true) }
    var manualAtMs by remember { mutableLongStateOf(0L) }
    var lyricScroll by remember { mutableFloatStateOf(0f) }
    val lyricWheelInertia = remember { WheelInertiaMotion() }
    var lyricMotionAtNs by remember { mutableLongStateOf(0L) }

    val maxScroll = ((lines.size - 1).coerceAtLeast(0)) * rowPitchPx

    LaunchedEffect(lines.size, controller.nowPlaying?.id) {
        followPlayback = true
        lyricWheelInertia.stop()
        val idx = findCurrentLyricIndex(controller.lyrics, controller.positionMillis).coerceAtLeast(0)
        lyricScroll = idx * rowPitchPx
        lyricMotionAtNs = 0L
    }

    // One persistent frame loop handles both follow motion and wheel inertia. It never cancels
    // and relaunches competing scroll jobs, and the exponential approach restores the original
    // non-linear lyric motion.
    LaunchedEffect(Unit) {
        while (true) {
            withFrameNanos { now ->
                val dt = if (lyricMotionAtNs == 0L) {
                    1f / 60f
                } else {
                    ((now - lyricMotionAtNs) / 1_000_000_000.0).toFloat().coerceIn(0.001f, 0.05f)
                }
                lyricMotionAtNs = now

                if (!followPlayback && System.currentTimeMillis() - manualAtMs > controller.lyricFollowDelayMillis) {
                    followPlayback = true
                    lyricWheelInertia.stop()
                }

                if (followPlayback) {
                    val liveLines = controller.lyrics
                    val liveIndex = findCurrentLyricIndex(liveLines, controller.positionMillis)
                    if (liveIndex >= 0 && liveLines.isNotEmpty()) {
                        val liveMax = ((liveLines.size - 1).coerceAtLeast(0)) * rowPitchPx
                        val target = (liveIndex * rowPitchPx).coerceIn(0f, liveMax)
                        val distance = target - lyricScroll
                        if (kotlin.math.abs(distance) > 0.05f) {
                            val approach = (1.0 - kotlin.math.exp(-11.0 * dt)).toFloat()
                            lyricScroll += distance * approach
                        } else {
                            lyricScroll = target
                        }
                    }
                } else {
                    val movement = lyricWheelInertia.advance(dt)
                    if (movement != 0f) lyricScroll = (lyricScroll + movement).coerceIn(0f, maxScroll)
                }
            }
        }
    }

    fun markManualScroll() {
        followPlayback = false
        manualAtMs = System.currentTimeMillis()
    }

    fun onWheel(deltaY: Float) {
        if (lines.isEmpty() || deltaY == 0f) return
        markManualScroll()
        lyricScroll = (lyricScroll + lyricWheelInertia.impulse(deltaY)).coerceIn(0f, maxScroll)
    }

    fun onDrag(dy: Float) {
        if (lines.isEmpty()) return
        markManualScroll()
        lyricWheelInertia.stop()
        lyricScroll = (lyricScroll - dy).coerceIn(0f, maxScroll)
    }

    // Exclusive page: main chrome is not composed while lyrics are open, so nothing
    // underneath can receive clicks. This is a full page, not a translucent overlay.
    Box(modifier = modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(colors.background))
        AlbumFlowBackground(
            colors = controller.lyricFlowColors,
            modifier = Modifier.fillMaxSize(),
            cornerRadius = 0.dp,
            veil = colors.background.copy(alpha = 0.38f),
        )

        Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(
                        onClick = controller::closeLyrics,
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回", Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("返回", style = MaterialTheme.typography.labelMedium)
                    }
                    Spacer(Modifier.weight(1f))
                    Column(horizontalAlignment = Alignment.End, modifier = Modifier.widthIn(max = 360.dp)) {
                        ///stp
                        Text(
                            controller.nowPlaying?.title ?: "未在播放",
                            style = MaterialTheme.typography.titleSmall,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            controller.nowPlaying?.artist.orEmpty(),
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }

                    Box(
                        modifier = Modifier
                            .size(50.dp)
                            .clip(RoundedCornerShape(11.dp))
                            .background(Color.Transparent)
                            .padding(6.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        controller.nowPlaying?.title?.let {
                            controller.nowPlaying?.id?.let { id ->
                                Artwork(
                                    id = id,
                                    title = it,
                                    coverUrl = controller.nowPlaying?.coverUrl,
                                    modifier = Modifier.size(36.dp),
                                    cornerRadius = 9.dp,
                                )
                            }
                        }
                    }
                }

                BoxWithConstraints(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .clipToBounds()
                        .onPointerEvent(PointerEventType.Scroll) { event ->
                            val dy = event.changes.fold(0f) { acc, c -> acc + c.scrollDelta.y }
                            if (dy != 0f) {
                                event.changes.forEach { it.consume() }
                                onWheel(dy)
                            }
                        }
                        .pointerInput(lines.size, maxScroll) {
                            detectDragGestures(
                                onDragStart = { markManualScroll() },
                                onDrag = { change, dragAmount ->
                                    change.consume()
                                    onDrag(dragAmount.y)
                                },
                            )
                        },
                ) {
                    val centerYPx = with(density) { (maxHeight * 0.46f).toPx() }
                    val heightPx = with(density) { maxHeight.toPx() }

                    when {
                        controller.nowPlaying == null -> {
                            Text(
                                "选一首音乐后，歌词会出现在这里。",
                                modifier = Modifier.align(Alignment.Center),
                                style = MaterialTheme.typography.bodyLarge,
                                color = colors.onSurfaceVariant,
                            )
                        }
                        controller.lyricsLoading -> {
                            Column(
                                Modifier.align(Alignment.Center),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp, color = colors.primary)
                                Spacer(Modifier.height(12.dp))
                                Text("正在加载歌词…", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                            }
                        }
                        lines.isEmpty() -> {
                            Text(
                                controller.lyricsError ?: "这首歌暂时没有歌词",
                                modifier = Modifier.align(Alignment.Center),
                                style = MaterialTheme.typography.bodyLarge,
                                color = colors.onSurfaceVariant,
                            )
                        }
                        else -> {
                            val visualIndex = if (rowPitchPx <= 0f) 0f else lyricScroll / rowPitchPx
                            lines.forEachIndexed { index, line ->
                                val lineCenterPx = centerYPx + index * rowPitchPx - lyricScroll
                                if (lineCenterPx < -120f || lineCenterPx > heightPx + 120f) return@forEachIndexed

                                val distance = kotlin.math.abs(index - visualIndex)
                                val focus = if (activeIndex < 0) 0f else (1f - distance).coerceAtLeast(0f)
                                val ambient = (1f - distance / 4f).coerceAtLeast(0f)
                                val scale = (0.92f + focus * 0.16f + ambient * 0.03f).coerceIn(0.90f, 1.14f)
                                val alpha = ((130f * ambient + 125f * focus) / 255f).coerceIn(0.125f, 1f)
                                val color = lerpColor(colors.onSurfaceVariant, colors.onSurface, focus)
                                val hasTranslation = !line.translation.isNullOrBlank()
                                val rowHeight = if (hasTranslation) 124.dp else 74.dp
                                val scaledRowHeight = rowHeight * scale
                                val textWidthFraction = (1f / scale).coerceAtMost(1f)
                                val yDp = with(density) { lineCenterPx.toDp() } - scaledRowHeight / 2

                                Box(
                                    Modifier
                                        .fillMaxWidth()
                                        .offset(y = yDp)
                                        .height(scaledRowHeight)
                                        .padding(horizontal = 20.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .clickable {
                                            followPlayback = true
                                            lyricWheelInertia.stop()
                                            controller.seekToLyric(index)
                                            lyricScroll = index * rowPitchPx
                                        },
                                    contentAlignment = if (hasTranslation) Alignment.TopCenter else Alignment.Center,
                                ) {
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                    ) {
                                        Text(
                                            text = line.text,
                                            modifier = Modifier
                                                .fillMaxWidth(textWidthFraction)
                                                .graphicsLayer {
                                                    scaleX = scale
                                                scaleY = scale
                                                this.alpha = alpha
                                                transformOrigin = TransformOrigin.Center
                                            },
                                            style = MaterialTheme.typography.bodyLarge.copy(
                                                fontWeight = if (focus > 0.55f) FontWeight.SemiBold else FontWeight.Normal,
                                                fontSize = baseFontSp,
                                                lineHeight = baseLineHeightSp,
                                            ),
                                            color = color,
                                            textAlign = TextAlign.Center,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        if (hasTranslation) {
                                            Spacer(Modifier.height(6.dp))
                                            Text(
                                                text = line.translation.orEmpty(),
                                                modifier = Modifier.graphicsLayer {
                                                    scaleX = scale
                                                    scaleY = scale
                                                    this.alpha = alpha
                                                    transformOrigin = TransformOrigin.Center
                                                },
                                                style = MaterialTheme.typography.bodyMedium.copy(
                                                    fontSize = 16.sp,
                                                    lineHeight = 21.sp,
                                                    fontWeight = FontWeight.Normal,
                                                ),
                                                color = colors.onSurfaceVariant.copy(alpha = 0.96f),
                                                textAlign = TextAlign.Center,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                ) {
                    CompactIconButton(Icons.Filled.SkipPrevious, controller::playPrevious, "上一首")
                    Spacer(Modifier.width(8.dp))
                    IconButton(
                        onClick = controller::togglePlayPause,
                        modifier = Modifier.size(44.dp),
                        colors = IconButtonDefaults.iconButtonColors(
                            containerColor = colors.primary,
                            contentColor = colors.onPrimary,
                        ),
                    ) {
                        Icon(
                            if (controller.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            if (controller.isPlaying) "暂停" else "播放",
                            Modifier.size(24.dp),
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    CompactIconButton(Icons.Filled.SkipNext, controller::playNext, "下一首")
                }
            }
        }
    }


private fun lerpColor(from: Color, to: Color, t: Float): Color {
    val f = t.coerceIn(0f, 1f)
    return Color(
        red = from.red + (to.red - from.red) * f,
        green = from.green + (to.green - from.green) * f,
        blue = from.blue + (to.blue - from.blue) * f,
        alpha = from.alpha + (to.alpha - from.alpha) * f,
    )
}

@Composable
private fun LoginOverlay(controller: DesktopPlayerController) {
    val colors = MaterialTheme.colorScheme
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.38f))
            .pointerInput(Unit) { detectTapGestures { controller.closeLogin() } },
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            modifier = Modifier
                .width(760.dp)
                .height(520.dp)
                .pointerInput(Unit) { detectTapGestures { } },
            shape = RoundedCornerShape(28.dp),
            color = colors.surface,
            shadowElevation = 18.dp,
        ) {
            Row(Modifier.fillMaxWidth()) {
                Column(
                    Modifier.width(250.dp).fillMaxHeight().background(colors.primaryContainer).padding(26.dp),
                ) {
                    Box(Modifier.size(42.dp).clip(RoundedCornerShape(13.dp)).background(colors.surface), contentAlignment = Alignment.Center) {
                        Text("L", color = colors.primary, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                    }
                    Spacer(Modifier.height(34.dp))
                    Text("把熟悉的音乐，带回这一页。", style = MaterialTheme.typography.headlineMedium, color = colors.onPrimaryContainer)
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "登录后自动同步歌单、喜欢歌曲与每日推荐。会话会保存在这台设备上。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.onPrimaryContainer.copy(alpha = 0.72f),
                    )
                    Spacer(Modifier.weight(1f))
                }

                Column(Modifier.weight(1f).padding(horizontal = 32.dp, vertical = 24.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("登录 Lazer", style = MaterialTheme.typography.headlineSmall)
                        Spacer(Modifier.weight(1f))
                        IconButton(onClick = controller::closeLogin) { Icon(Icons.Outlined.Close, "关闭") }
                    }
                    Spacer(Modifier.height(14.dp))
                    LoginMethodSwitch(controller)
                    Spacer(Modifier.height(22.dp))
                    if (controller.loginMethod == LoginMethod.QR_CODE) {
                        QrLoginContent(controller)
                    } else {
                        PasswordLoginContent(controller)
                    }
                }
            }
        }
    }
}

@Composable
private fun LoginMethodSwitch(controller: DesktopPlayerController) {
    val colors = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth().height(40.dp).clip(RoundedCornerShape(11.dp)).background(colors.surfaceVariant).padding(3.dp),
    ) {
        LoginMethod.entries.forEach { method ->
            val selected = controller.loginMethod == method
            Box(
                Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(9.dp))
                    .background(if (selected) colors.surface else Color.Transparent)
                    .clickable { controller.selectLoginMethod(method) },
                contentAlignment = Alignment.Center,
            ) {
                Text(if (method == LoginMethod.QR_CODE) "二维码登录" else "密码登录", style = MaterialTheme.typography.labelMedium, color = if (selected) colors.onSurface else colors.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun QrLoginContent(controller: DesktopPlayerController) {
    val colors = MaterialTheme.colorScheme
    val qrBitmap = remember(controller.qrFallbackUrl, controller.qrImageData) {
        controller.qrFallbackUrl?.let(::generateQrCodeBitmap)
            ?: decodeQrImage(controller.qrImageData)
    }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(216.dp).clip(RoundedCornerShape(20.dp)).background(Color.White).border(1.dp, colors.outlineVariant, RoundedCornerShape(20.dp)),
            contentAlignment = Alignment.Center,
        ) {
            when {
                qrBitmap != null -> Image(qrBitmap, "登录二维码", Modifier.size(188.dp))
                controller.qrLoginState == QrLoginState.CREATING -> CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp)
                else -> Icon(Icons.Outlined.MusicNote, null, Modifier.size(42.dp), tint = colors.primary)
            }
        }
        Spacer(Modifier.height(14.dp))
        Text(
            when (controller.qrLoginState) {
                QrLoginState.CREATING -> "正在生成二维码…"
                QrLoginState.WAITING_FOR_SCAN -> "打开网易云音乐，扫码登录"
                QrLoginState.WAITING_FOR_CONFIRMATION -> "已扫码，请在手机上确认"
                QrLoginState.EXPIRED -> "二维码已过期"
                QrLoginState.AUTHORIZED -> "登录成功，正在同步音乐"
                QrLoginState.ERROR -> "二维码暂时不可用"
                else -> "准备二维码"
            },
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurface,
        )
        controller.loginError?.let {
            Spacer(Modifier.height(5.dp))
            Text(it, style = MaterialTheme.typography.labelSmall, color = colors.error)
        }
        if (controller.qrLoginState in setOf(QrLoginState.EXPIRED, QrLoginState.ERROR)) {
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = controller::startQrLogin) {
                Icon(Icons.Outlined.Refresh, null, Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("重新生成二维码")
            }
        }
    }
}

@Composable
private fun PasswordLoginContent(controller: DesktopPlayerController) {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth()) {
        Text("使用网易云音乐账号", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(5.dp))
        Text("支持手机号或邮箱。手机号默认使用 +86 区号。", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        Spacer(Modifier.height(20.dp))
        OutlinedTextField(
            value = controller.loginIdentifier,
            onValueChange = controller::updateLoginIdentifier,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("手机号或邮箱") },
            singleLine = true,
            shape = RoundedCornerShape(13.dp),
            colors = quietTextFieldColors(),
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = controller.loginPassword,
            onValueChange = controller::updateLoginPassword,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("密码") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            shape = RoundedCornerShape(13.dp),
            colors = quietTextFieldColors(),
        )
        controller.loginError?.let {
            Spacer(Modifier.height(9.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = colors.error)
        }
        Spacer(Modifier.height(20.dp))
        Button(
            onClick = controller::submitPasswordLogin,
            enabled = !controller.isSubmittingLogin,
            modifier = Modifier.fillMaxWidth().height(46.dp),
            shape = RoundedCornerShape(12.dp),
        ) {
            if (controller.isSubmittingLogin) {
                CircularProgressIndicator(Modifier.size(17.dp), strokeWidth = 2.dp, color = colors.onPrimary)
                Spacer(Modifier.width(8.dp))
            }
            Text(if (controller.isSubmittingLogin) "正在登录" else "登录并同步歌单")
        }
    }
}

@Composable
private fun quietTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = MaterialTheme.colorScheme.surface,
    unfocusedContainerColor = MaterialTheme.colorScheme.surface,
    focusedBorderColor = MaterialTheme.colorScheme.primary,
    unfocusedBorderColor = MaterialTheme.colorScheme.outlineVariant,
)

private fun decodeQrImage(dataUri: String?): ImageBitmap? {
    if (dataUri.isNullOrBlank()) return null
    return runCatching {
        val encoded = dataUri.substringAfter("base64,", dataUri)
        SkiaImage.makeFromEncoded(Base64.getDecoder().decode(encoded)).toComposeImageBitmap()
    }.getOrNull()
}
