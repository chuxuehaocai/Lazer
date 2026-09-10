package dev.naominet.lazer

import android.app.Activity
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Base64
import androidx.activity.BackEventCompat
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.LibraryMusic
import androidx.compose.material.icons.outlined.LightMode
import androidx.compose.material.icons.outlined.Lyrics
import androidx.compose.material.icons.outlined.MyLocation
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.core.view.WindowCompat
import coil3.compose.AsyncImage
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.DEFAULT_GATEWAY_BASE_URL
import dev.naominet.lazer.gateway.normalizeGatewayBaseUrl
import kotlinx.coroutines.launch
import top.yukonga.miuix.kmp.basic.Button as MiuixButton
import top.yukonga.miuix.kmp.basic.ButtonColors as MiuixButtonColors
import top.yukonga.miuix.kmp.basic.ButtonDefaults as MiuixButtonDefaults
import top.yukonga.miuix.kmp.basic.Card as MiuixCard
import top.yukonga.miuix.kmp.basic.NavigationBar as MiuixNavigationBar
import top.yukonga.miuix.kmp.basic.NavigationBarDisplayMode as MiuixNavigationBarDisplayMode
import top.yukonga.miuix.kmp.basic.NavigationBarItem as MiuixNavigationBarItem
import kotlin.math.roundToLong
import kotlin.math.roundToInt

private const val PAGE_TRANSITION_MILLIS = LazerTokens.Motion.pageMillis
private val LazerMotionEasing = CubicBezierEasing(0.2f, 0f, 0f, 1f)

private enum class AndroidMainPageKind(val depth: Int) {
    ROOT(0),
    PLAYLIST(1),
    SETTINGS(1),
}

private data class AndroidMainPage(
    val kind: AndroidMainPageKind,
    val playlist: AndroidPlaylist? = null,
    val tracks: List<AndroidTrack> = emptyList(),
    val isLoading: Boolean = false,
) {
    val contentKey: Any
        get() = if (kind == AndroidMainPageKind.PLAYLIST) kind to playlist?.id else kind
}

private enum class AndroidBackLayer {
    PLAYLIST,
    SETTINGS,
    PLAYER,
    LYRICS,
}

private fun Modifier.predictiveBackTransform(
    enabled: Boolean,
    progress: Float,
    swipeEdge: Int,
): Modifier = if (!enabled) {
    this
} else {
    graphicsLayer {
        val fraction = progress.coerceIn(0f, 1f)
        val direction = if (swipeEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f
        translationX = size.width * 0.08f * fraction * direction
        val scale = 1f - 0.035f * fraction
        scaleX = scale
        scaleY = scale
        alpha = 1f - 0.08f * fraction
    }
}

@Composable
private fun isLandscapeLayout(): Boolean =
    LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

@Composable
private fun ThemeButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    cornerRadius: Dp? = null,
    content: @Composable RowScope.() -> Unit,
) {
    if (LocalLazerThemeEngine.current == LazerThemeEngine.MIUIX) {
        val colors = MiuixButtonDefaults.buttonColorsPrimary()
        CompositionLocalProvider(
            androidx.compose.material3.LocalContentColor provides
                if (enabled) colors.contentColor else colors.disabledContentColor,
        ) {
            MiuixButton(
                onClick = onClick,
                modifier = modifier,
                enabled = enabled,
                cornerRadius = cornerRadius ?: MiuixButtonDefaults.CornerRadius,
                colors = colors,
                content = content,
            )
        }
    } else if (cornerRadius != null) {
        Button(
            onClick = onClick,
            modifier = modifier,
            enabled = enabled,
            shape = RoundedCornerShape(cornerRadius),
            content = content,
        )
    } else {
        Button(onClick = onClick, modifier = modifier, enabled = enabled, content = content)
    }
}

@Composable
private fun ThemeTextButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    if (LocalLazerThemeEngine.current == LazerThemeEngine.MIUIX) {
        val textColors = MiuixButtonDefaults.textButtonColors()
        val colors = MiuixButtonColors(
            color = textColors.color,
            disabledColor = textColors.disabledColor,
            contentColor = textColors.textColor,
            disabledContentColor = textColors.disabledTextColor,
        )
        CompositionLocalProvider(
            androidx.compose.material3.LocalContentColor provides
                if (enabled) colors.contentColor else colors.disabledContentColor,
        ) {
            MiuixButton(
                onClick = onClick,
                modifier = modifier,
                enabled = enabled,
                colors = colors,
                content = content,
            )
        }
    } else {
        TextButton(onClick = onClick, modifier = modifier, enabled = enabled, content = content)
    }
}

@Composable
private fun SettingsCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    if (LocalLazerThemeEngine.current == LazerThemeEngine.MIUIX) {
        CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides colors.onSurface) {
            MiuixCard(
                modifier = modifier.fillMaxWidth(),
                cornerRadius = 18.dp,
            ) {
                content()
            }
        }
    } else {
        Surface(
            modifier = modifier.fillMaxWidth(),
            shape = RoundedCornerShape(18.dp),
            color = colors.surfaceContainerHigh,
        ) {
            content()
        }
    }
}

@Composable
fun AndroidLazerApp() {
    val context = LocalContext.current
    val controller = remember(context.applicationContext) { AndroidGatewayController(context.applicationContext) }
    val playback by AndroidPlaybackConnection.snapshot.collectAsState()
    var playerVisible by remember { mutableStateOf(false) }
    var lyricsVisible by remember { mutableStateOf(false) }
    var requestedBackProgress by remember { mutableFloatStateOf(0f) }
    var isPredictiveBackRunning by remember { mutableStateOf(false) }
    var backSwipeEdge by remember { mutableStateOf(BackEventCompat.EDGE_LEFT) }
    var transformedBackLayer by remember { mutableStateOf<AndroidBackLayer?>(null) }

    val activeBackLayer = when {
        lyricsVisible -> AndroidBackLayer.LYRICS
        playerVisible -> AndroidBackLayer.PLAYER
        controller.isSettingsVisible -> AndroidBackLayer.SETTINGS
        controller.activePlaylist != null -> AndroidBackLayer.PLAYLIST
        else -> null
    }
    val renderedBackProgress by animateFloatAsState(
        targetValue = requestedBackProgress,
        animationSpec = if (isPredictiveBackRunning) {
            snap()
        } else {
            tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing)
        },
        label = "predictive-back-progress",
    )
    LaunchedEffect(isPredictiveBackRunning, renderedBackProgress) {
        if (!isPredictiveBackRunning && renderedBackProgress == 0f) transformedBackLayer = null
    }

    DisposableEffect(controller) {
        onDispose { controller.close() }
    }
    LaunchedEffect(playback.track?.id) { playback.track?.id?.let(controller::loadLyrics) }

    // The currently visible top layer owns back. Gesture progress drives the same page that a
    // normal back press closes; cancelling the gesture eases that page back into place.
    PredictiveBackHandler(enabled = !controller.isLoginVisible && activeBackLayer != null) { events ->
        val layer = activeBackLayer ?: return@PredictiveBackHandler
        transformedBackLayer = layer
        isPredictiveBackRunning = true
        try {
            events.collect { event ->
                requestedBackProgress = event.progress
                backSwipeEdge = event.swipeEdge
            }
            when (layer) {
                AndroidBackLayer.LYRICS -> lyricsVisible = false
                AndroidBackLayer.PLAYER -> playerVisible = false
                AndroidBackLayer.SETTINGS -> controller.closeSettings()
                AndroidBackLayer.PLAYLIST -> controller.closePlaylist()
            }
        } finally {
            isPredictiveBackRunning = false
            requestedBackProgress = 0f
        }
    }

    val mainPage = when {
        controller.isSettingsVisible -> AndroidMainPage(AndroidMainPageKind.SETTINGS)
        controller.activePlaylist != null -> AndroidMainPage(
            kind = AndroidMainPageKind.PLAYLIST,
            playlist = controller.activePlaylist,
            tracks = controller.activePlaylistTracks,
            isLoading = controller.isPlaylistLoading,
        )
        else -> AndroidMainPage(AndroidMainPageKind.ROOT)
    }
    val systemConfiguration = LocalConfiguration.current
    val systemColorScheme = remember(
        controller.useSystemMonetColors,
        controller.isDark,
        systemConfiguration,
    ) {
        if (controller.useSystemMonetColors && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (controller.isDark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else {
            null
        }
    }

    LazerTheme(
        isDark = controller.isDark,
        colorScheme = systemColorScheme,
        engine = controller.themeEngine,
    ) {
        val colors = MaterialTheme.colorScheme
        val view = LocalView.current
        val playFromQueue: (List<AndroidTrack>, AndroidTrack) -> Unit = { queue, track ->
            AndroidPlaybackConnection.play(context, queue, track)
            playerVisible = true
        }
        if (!view.isInEditMode) {
            SideEffect {
                (view.context as? Activity)?.window?.let { window ->
                    WindowCompat.getInsetsController(window, view).apply {
                        isAppearanceLightStatusBars = !controller.isDark
                        isAppearanceLightNavigationBars = !controller.isDark
                    }
                }
            }
        }
        Box(Modifier.fillMaxSize().background(colors.background)) {
            // Android 16 forces edge-to-edge. Keep the visual canvas under the status bar, while
            // placing every interactive root-page element below its dynamic inset.
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                Box(Modifier.weight(1f)) {
                    if (
                        transformedBackLayer == AndroidBackLayer.PLAYLIST ||
                        transformedBackLayer == AndroidBackLayer.SETTINGS
                    ) {
                        AndroidRootContent(
                            controller = controller,
                            currentTrackId = playback.track?.id,
                            onPlay = playFromQueue,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    AnimatedContent(
                        targetState = mainPage,
                        modifier = Modifier.fillMaxSize(),
                        transitionSpec = {
                            val movesForward = targetState.kind.depth > initialState.kind.depth
                            val enter = slideInHorizontally(
                                animationSpec = tween(
                                    durationMillis = PAGE_TRANSITION_MILLIS,
                                    easing = LazerMotionEasing,
                                ),
                                initialOffsetX = { width -> if (movesForward) width / 5 else -width / 5 },
                            ) + fadeIn(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing))
                            val exit = slideOutHorizontally(
                                animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                                targetOffsetX = { width -> if (movesForward) -width / 8 else width / 8 },
                            ) + fadeOut(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing))
                            (enter togetherWith exit).apply {
                                targetContentZIndex = if (movesForward) 1f else -1f
                            }
                        },
                        contentKey = AndroidMainPage::contentKey,
                        label = "android-main-page",
                    ) { page ->
                        Surface(
                            modifier = Modifier
                                .fillMaxSize()
                                .predictiveBackTransform(
                                    enabled = when (page.kind) {
                                        AndroidMainPageKind.PLAYLIST -> transformedBackLayer == AndroidBackLayer.PLAYLIST
                                        AndroidMainPageKind.SETTINGS -> transformedBackLayer == AndroidBackLayer.SETTINGS
                                        AndroidMainPageKind.ROOT -> false
                                    },
                                    progress = renderedBackProgress,
                                    swipeEdge = backSwipeEdge,
                                ),
                            color = colors.background,
                        ) {
                            when (page.kind) {
                                AndroidMainPageKind.SETTINGS -> SettingsPage(controller)
                                AndroidMainPageKind.PLAYLIST -> page.playlist?.let { playlist ->
                                    PlaylistDetail(
                                        playlist = playlist,
                                        tracks = page.tracks,
                                        isLoading = page.isLoading,
                                        currentId = playback.track?.id,
                                        onBack = controller::closePlaylist,
                                        onPlay = { track -> playFromQueue(page.tracks, track) },
                                    )
                                }
                                AndroidMainPageKind.ROOT -> AndroidRootContent(
                                    controller = controller,
                                    currentTrackId = playback.track?.id,
                                    onPlay = playFromQueue,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                        }
                    }
                }
                playback.track?.let { track ->
                    MiniPlayer(track, playback.isPlaying, playback.isPreparing, { playerVisible = true }) {
                        AndroidPlaybackConnection.toggle(context)
                    }
                }
                BottomDock(controller.destination, controller::selectDestination)
            }

            controller.message?.let { text -> MessageBanner(text, Modifier.align(Alignment.TopCenter).safeDrawingPadding().padding(16.dp)) }
            AnimatedVisibility(
                visible = playerVisible && playback.track != null,
                modifier = Modifier.fillMaxSize(),
                enter = slideInVertically(
                    animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                    initialOffsetY = { height -> height / 8 },
                ) + fadeIn(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing)),
                exit = slideOutVertically(
                    animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                    targetOffsetY = { height -> height / 8 },
                ) + fadeOut(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing)),
                label = "now-playing-page",
            ) {
                NowPlayingPage(
                    snapshot = playback,
                    lyricLines = controller.lyrics,
                    lyricsLoading = controller.lyricsLoading,
                    lyricsMessage = controller.lyricsMessage,
                    lyricFollowDelayMillis = controller.lyricFollowDelayMillis,
                    lyricAnimationSpeed = controller.lyricAnimationSpeed,
                    wordLyricsEnabled = controller.wordLyricsEnabled,
                    isLiked = playback.track?.let { controller.isSongLiked(it.id) } == true,
                    onToggleLiked = { playback.track?.let(controller::toggleSongLiked) },
                    onDismiss = { playerVisible = false },
                    onToggle = { AndroidPlaybackConnection.toggle(context) },
                    onPrevious = { AndroidPlaybackConnection.previous(context) },
                    onNext = { AndroidPlaybackConnection.next(context) },
                    onSeek = { AndroidPlaybackConnection.seekTo(context, it) },
                    onLyrics = { lyricsVisible = true },
                    modifier = Modifier
                        .fillMaxSize()
                        .predictiveBackTransform(
                            enabled = transformedBackLayer == AndroidBackLayer.PLAYER,
                            progress = renderedBackProgress,
                            swipeEdge = backSwipeEdge,
                        ),
                )
            }
            AnimatedVisibility(
                visible = lyricsVisible && playback.track != null,
                modifier = Modifier.fillMaxSize(),
                enter = slideInHorizontally(
                    animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                    initialOffsetX = { width -> width / 5 },
                ) + fadeIn(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing)),
                exit = slideOutHorizontally(
                    animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                    targetOffsetX = { width -> width / 5 },
                ) + fadeOut(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing)),
                label = "lyrics-page",
            ) {
                AndroidLyricsPage(
                    track = playback.track,
                    lines = controller.lyrics,
                    isLoading = controller.lyricsLoading,
                    message = controller.lyricsMessage,
                    positionMillis = playback.positionMillis,
                    followDelayMillis = controller.lyricFollowDelayMillis,
                    animationSpeed = controller.lyricAnimationSpeed,
                    wordLyricsEnabled = controller.wordLyricsEnabled,
                    onBack = { lyricsVisible = false },
                    onSeek = { AndroidPlaybackConnection.seekTo(context, it) },
                    modifier = Modifier
                        .fillMaxSize()
                        .predictiveBackTransform(
                            enabled = transformedBackLayer == AndroidBackLayer.LYRICS,
                            progress = renderedBackProgress,
                            swipeEdge = backSwipeEdge,
                        ),
                )
            }
            if (controller.isLoginVisible) LoginSheet(controller)
        }
    }
}

@Composable
private fun AndroidRootContent(
    controller: AndroidGatewayController,
    currentTrackId: Long?,
    onPlay: (List<AndroidTrack>, AndroidTrack) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        MobileHeader(
            controller = controller,
            modifier = Modifier.padding(start = 20.dp, top = 12.dp, end = 20.dp, bottom = 6.dp),
        )
        AnimatedContent(
            targetState = controller.destination,
            modifier = Modifier.weight(1f),
            transitionSpec = {
                val movesForward = targetState.motionIndex > initialState.motionIndex
                val enter = slideInHorizontally(
                    animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                    initialOffsetX = { width -> if (movesForward) width / 5 else -width / 5 },
                ) + fadeIn(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing))
                val exit = slideOutHorizontally(
                    animationSpec = tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing),
                    targetOffsetX = { width -> if (movesForward) -width / 8 else width / 8 },
                ) + fadeOut(tween(PAGE_TRANSITION_MILLIS, easing = LazerMotionEasing))
                enter togetherWith exit
            },
            label = "android-root",
        ) { destination ->
            when (destination) {
                AndroidRootDestination.HOME -> HomePage(controller, currentTrackId) { track ->
                    onPlay(controller.homeTracks, track)
                }
                AndroidRootDestination.DISCOVER -> DiscoverPage(controller, currentTrackId) { track ->
                    onPlay(controller.homeTracks, track)
                }
                AndroidRootDestination.SEARCH -> SearchPage(controller, currentTrackId) { track ->
                    onPlay(controller.searchResults, track)
                }
                AndroidRootDestination.LIBRARY -> LibraryPage(controller, currentTrackId) { track ->
                    onPlay(controller.homeTracks, track)
                }
                AndroidRootDestination.ME -> MePage(controller)
            }
        }
    }
}

@Composable
private fun HomePage(controller: AndroidGatewayController, currentId: Long?, onPlay: (AndroidTrack) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp, 12.dp, 20.dp, 18.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        item {
            SectionTitle("从这里开始", if (controller.isSignedIn) "为你整理了今天可以慢慢听的音乐" else "登录后，推荐会跟着你的听歌习惯变化")
            Spacer(Modifier.height(12.dp))
            PlaylistStrip(controller.featuredPlaylists, controller::openPlaylist)
        }
        item { SectionTitle(if (controller.isSignedIn) "每日推荐" else "正在流动") }
        when {
            controller.isLoading && controller.homeTracks.isEmpty() -> item { QuietState("正在整理音乐…") }
            controller.homeTracks.isEmpty() -> item { QuietState("现在还没有可播放的音乐，稍后再试。") }
            else -> items(controller.homeTracks, key = AndroidTrack::id) { TrackRow(it, it.id == currentId) { onPlay(it) } }
        }
    }
}

@Composable
private fun DiscoverPage(controller: AndroidGatewayController, currentId: Long?, onPlay: (AndroidTrack) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp, 12.dp, 20.dp, 18.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        item {
            Column(Modifier.widthIn(max = 470.dp)) {
                Text("慢慢发现", style = MaterialTheme.typography.displaySmall)
                Spacer(Modifier.height(6.dp))
                Text("从一张歌单开始，留一点空间给意外听到的声音。", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item { PlaylistStrip(controller.featuredPlaylists, controller::openPlaylist) }
        item { SectionTitle("此刻可以听") }
        items(controller.homeTracks.take(12), key = AndroidTrack::id) { TrackRow(it, it.id == currentId) { onPlay(it) } }
    }
}

@Composable
private fun SearchPage(controller: AndroidGatewayController, currentId: Long?, onPlay: (AndroidTrack) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp, 12.dp, 20.dp, 18.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item { Text("搜索", style = MaterialTheme.typography.displaySmall) }
        item {
            OutlinedTextField(
                value = controller.searchQuery,
                onValueChange = controller::updateSearchQuery,
                modifier = Modifier.fillMaxWidth(),
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                placeholder = { Text("歌名、音乐人或专辑") },
                singleLine = true,
                shape = RoundedCornerShape(16.dp),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            )
        }
        when {
            controller.searchQuery.isBlank() -> item { QuietState("输入歌名、音乐人或专辑，结果会在这里出现。") }
            controller.isSearching -> item { QuietState("正在搜索…") }
            controller.searchResults.isEmpty() -> item { QuietState("没有找到匹配的音乐。") }
            else -> items(controller.searchResults, key = AndroidTrack::id) { TrackRow(it, it.id == currentId) { onPlay(it) } }
        }
    }
}

@Composable
private fun LibraryPage(controller: AndroidGatewayController, currentId: Long?, onPlay: (AndroidTrack) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp, 12.dp, 20.dp, 18.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        item {
            Text("你的音乐库", style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(6.dp))
            Text(
                if (controller.isSignedIn) "歌单先从本地恢复，再悄悄同步新内容。" else "登录后可以继续听你的歌单和每日推荐。",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        when {
            !controller.isSignedIn -> item { SignInInvitation(controller::openLogin) }
            controller.userPlaylists.isEmpty() && controller.isLoading -> item { QuietState("正在同步你的歌单…") }
            controller.userPlaylists.isEmpty() -> item { QuietState("还没有找到歌单。") }
            else -> items(controller.userPlaylists, key = AndroidPlaylist::id) { PlaylistListRow(it, controller::openPlaylist) }
        }
        if (controller.homeTracks.isNotEmpty()) {
            item { SectionTitle("接着听") }
            items(controller.homeTracks.take(5), key = AndroidTrack::id) { TrackRow(it, it.id == currentId) { onPlay(it) } }
        }
    }
}

@Composable
private fun MePage(controller: AndroidGatewayController) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp, 12.dp, 20.dp, 18.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        if (!controller.isSignedIn) {
            item {
                Text("我的", style = MaterialTheme.typography.displaySmall)
                Spacer(Modifier.height(6.dp))
                Text("登录后，在这里集中查看你的资料和歌单。", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            item { SignInInvitation(controller::openLogin) }
        } else {
            val user = controller.currentUser!!
            item {
                Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.68f)) {
                    Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                        MobileArtwork(normalizedArtworkUrl(user.avatarUrl), user.nickname, Modifier.size(64.dp), 32.dp)
                        Spacer(Modifier.width(16.dp))
                        Column(Modifier.weight(1f)) {
                            Text(user.nickname.ifBlank { "我的音乐" }, style = MaterialTheme.typography.headlineSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            user.signature?.takeIf(String::isNotBlank)?.let { signature ->
                                Spacer(Modifier.height(4.dp))
                                Text(signature, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.75f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                            }
                            Spacer(Modifier.height(7.dp))
                            Text("网易云 ID ${user.userId}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.72f))
                        }
                    }
                }
            }
            item { SectionTitle("我的歌单", "完整歌单和离线恢复内容都在音乐库") }
            when {
                controller.userPlaylists.isEmpty() && controller.isLoading -> item { QuietState("正在同步你的歌单…") }
                controller.userPlaylists.isEmpty() -> item { QuietState("还没有找到歌单。") }
                else -> items(controller.userPlaylists.take(3), key = AndroidPlaylist::id) { PlaylistListRow(it, controller::openPlaylist) }
            }
            item {
                ThemeTextButton(onClick = { controller.selectDestination(AndroidRootDestination.LIBRARY) }) {
                    Text("查看完整音乐库")
                }
            }
        }
    }
}

@Composable
private fun SettingsPage(controller: AndroidGatewayController, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val systemMonetAvailable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    var isAudioQualitySheetVisible by remember { mutableStateOf(false) }
    var isCacheSheetVisible by remember { mutableStateOf(false) }
    var followDelaySliderValue by remember(controller.lyricFollowDelayMillis) {
        mutableFloatStateOf(controller.lyricFollowDelayMillis.toFloat())
    }
    var gatewayBaseUrlDraft by remember(controller.gatewayBaseUrl) {
        mutableStateOf(controller.gatewayBaseUrl)
    }
    val displayedFollowDelay = normalizeLyricFollowDelayMillis(followDelaySliderValue.roundToLong())
    val animationSpeedOptions = LyricAnimationSpeed.entries
    val normalizedGatewayBaseUrl = normalizeGatewayBaseUrl(gatewayBaseUrlDraft)
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp, 10.dp, 20.dp, 18.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = controller::closeSettings) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回")
                }
                Spacer(Modifier.width(4.dp))
                Text("设置", style = MaterialTheme.typography.headlineSmall)
            }
        }
        item { SectionTitle("外观") }
        item {
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Switch) {
                            controller.updateThemeEngine(
                                if (controller.themeEngine == LazerThemeEngine.MIUIX) {
                                    LazerThemeEngine.MATERIAL3
                                } else {
                                    LazerThemeEngine.MIUIX
                                },
                            )
                        }
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Miuix 组件风格", style = MaterialTheme.typography.titleSmall)
                        Text(
                            "当前：${controller.themeEngine.label} · 切换后立即生效",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    LazerThemeEngineSwitch(
                        engine = controller.themeEngine,
                        onEngineChange = controller::updateThemeEngine,
                    )
                }
            }
        }
        item {
            SettingsCard {
                Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 10.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("界面", style = MaterialTheme.typography.titleSmall)
                        Text(if (controller.isDark) "深色外观" else "浅色外观", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                    }
                    ThemeTextButton(onClick = controller::toggleTheme) {
                        Text(if (controller.isDark) "切换浅色" else "切换深色")
                    }
                }
            }
        }
        item {
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = systemMonetAvailable, role = Role.Switch) {
                            controller.updateUseSystemMonetColors(!controller.useSystemMonetColors)
                        }
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("系统 Monet 取色", style = MaterialTheme.typography.titleSmall)
                        Text(
                            if (systemMonetAvailable) "使用当前壁纸生成的系统配色" else "需要 Android 12 或更高版本",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    LazerSwitch(
                        engine = controller.themeEngine,
                        checked = controller.useSystemMonetColors && systemMonetAvailable,
                        onCheckedChange = null,
                        enabled = systemMonetAvailable,
                    )
                }
            }
        }
        item { SectionTitle("播放") }
        item {
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button) { isAudioQualitySheetVisible = true }
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("音质", style = MaterialTheme.typography.titleSmall)
                        Text(
                            "${controller.audioQuality.description} · 下次播放时生效",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(16.dp))
                    Text(
                        controller.audioQuality.label,
                        style = MaterialTheme.typography.labelLarge,
                        color = colors.primary,
                    )
                }
            }
        }
        item {
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Switch) {
                            controller.updateExclusiveAudio(!controller.exclusiveAudio)
                        }
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("独占音频", style = MaterialTheme.typography.titleSmall)
                        Text(
                            if (controller.exclusiveAudio) {
                                "播放时请求系统暂停其他应用的声音"
                            } else {
                                "与其他应用共享音频输出"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    LazerSwitch(
                        engine = controller.themeEngine,
                        checked = controller.exclusiveAudio,
                        onCheckedChange = null,
                    )
                }
            }
        }
        item { SectionTitle("歌词") }
        item {
            SettingsCard(
                modifier = Modifier.clickable(role = Role.Switch) {
                    controller.updateWordLyricsEnabled(!controller.wordLyricsEnabled)
                },
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("逐字歌词", style = MaterialTheme.typography.titleSmall)
                        Text(
                            if (controller.wordLyricsEnabled) "显示逐字渐亮和模糊过渡" else "只显示整行歌词",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    LazerSwitch(
                        engine = controller.themeEngine,
                        checked = controller.wordLyricsEnabled,
                        onCheckedChange = null,
                    )
                }
            }
        }
        item {
            SettingsCard {
                Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("歌词动画速率", style = MaterialTheme.typography.titleSmall)
                            Text(
                                "调整滚动收束和逐字过渡的节奏",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant,
                            )
                        }
                        Text(
                            controller.lyricAnimationSpeed.label,
                            style = MaterialTheme.typography.labelLarge,
                            color = colors.primary,
                        )
                    }
                    LazerSlider(
                        engine = controller.themeEngine,
                        value = controller.lyricAnimationSpeed.ordinal.toFloat(),
                        onValueChange = { value ->
                            controller.updateLyricAnimationSpeed(
                                animationSpeedOptions[value.roundToInt().coerceIn(animationSpeedOptions.indices)],
                            )
                        },
                        valueRange = 0f..animationSpeedOptions.lastIndex.toFloat(),
                        steps = animationSpeedOptions.size - 2,
                    )
                    Row(Modifier.fillMaxWidth()) {
                        Text(
                            animationSpeedOptions.first().label,
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            LyricAnimationSpeed.STANDARD.label,
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            animationSpeedOptions.last().label,
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                }
            }
        }
        item {
            SettingsCard {
                Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("恢复自动跟随", style = MaterialTheme.typography.titleSmall)
                            Text(
                                "手动滑动歌词后，等待这段时间再继续跟随播放",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant,
                            )
                        }
                        Text(
                            lyricFollowDelayLabel(displayedFollowDelay),
                            style = MaterialTheme.typography.labelLarge,
                            color = colors.primary,
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
                            color = colors.onSurfaceVariant,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            lyricFollowDelayLabel(MAX_LYRIC_FOLLOW_DELAY_MILLIS),
                            style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                }
            }
        }
        item { SectionTitle("存储与同步") }
        item {
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button) { isCacheSheetVisible = true }
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("清除本地缓存", style = MaterialTheme.typography.titleSmall)
                        Text(
                            "选择清除歌曲缓存或歌单缓存",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Text("选择", style = MaterialTheme.typography.labelLarge, color = colors.primary)
                }
            }
        }
        item {
            SettingsCard {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("强制重新同步", style = MaterialTheme.typography.titleSmall)
                        Text(
                            "保留当前内容，并重新获取最新歌单",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                    ThemeButton(onClick = controller::forceResync, enabled = !controller.isLoading) {
                        Text(if (controller.isLoading) "同步中" else "重新同步")
                    }
                }
            }
        }
        item { SectionTitle("音乐服务") }
        item {
            SettingsCard {
                Column(Modifier.fillMaxWidth().padding(18.dp)) {
                    Text("API 服务提供商", style = MaterialTheme.typography.titleSmall)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        "填写兼容服务的根地址。登录状态会继续沿用，请只使用你信任的提供商。",
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        value = gatewayBaseUrlDraft,
                        onValueChange = { gatewayBaseUrlDraft = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("服务地址") },
                        placeholder = { Text(DEFAULT_GATEWAY_BASE_URL) },
                        supportingText = if (gatewayBaseUrlDraft.isNotBlank() && normalizedGatewayBaseUrl == null) {
                            { Text("请输入有效的 HTTP 或 HTTPS 服务地址") }
                        } else {
                            null
                        },
                        isError = gatewayBaseUrlDraft.isNotBlank() && normalizedGatewayBaseUrl == null,
                        singleLine = true,
                        shape = RoundedCornerShape(14.dp),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        ThemeTextButton(onClick = { gatewayBaseUrlDraft = DEFAULT_GATEWAY_BASE_URL }) {
                            Text("恢复默认")
                        }
                        Spacer(Modifier.width(8.dp))
                        ThemeButton(
                            onClick = {
                                normalizedGatewayBaseUrl?.let { controller.updateGatewayBaseUrl(it) }
                            },
                            enabled = normalizedGatewayBaseUrl != null && normalizedGatewayBaseUrl != controller.gatewayBaseUrl,
                        ) {
                            Text("保存")
                        }
                    }
                }
            }
        }
        item { SectionTitle("帐号") }
        if (controller.isSignedIn) {
            val user = controller.currentUser!!
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    MobileArtwork(normalizedArtworkUrl(user.avatarUrl), user.nickname, Modifier.size(42.dp), 21.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(user.nickname.ifBlank { "已登录" }, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("当前已连接网易云音乐", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                    }
                }
            }
            item {
                ThemeTextButton(onClick = controller::logout) {
                    Text("退出登录", color = colors.error)
                }
            }
        } else {
            item { SignInInvitation(controller::openLogin) }
        }
    }
    if (isAudioQualitySheetVisible) {
        AudioQualitySheet(
            selected = controller.audioQuality,
            onSelected = {
                controller.updateAudioQuality(it)
                isAudioQualitySheetVisible = false
            },
            onDismiss = { isAudioQualitySheetVisible = false },
        )
    }
    if (isCacheSheetVisible) {
        CacheChoiceSheet(
            onClearSongs = {
                controller.clearSongCache()
                isCacheSheetVisible = false
            },
            onClearPlaylists = {
                controller.clearPlaylistCache()
                isCacheSheetVisible = false
            },
            onDismiss = { isCacheSheetVisible = false },
        )
    }
}

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
private fun CacheChoiceSheet(
    onClearSongs: () -> Unit,
    onClearPlaylists: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.surface,
    ) {
        Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 28.dp)) {
            Text("清除本地缓存", style = MaterialTheme.typography.headlineSmall)
            Text(
                "清除后，需要时会重新加载。登录状态不会受影响。",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp, bottom = 14.dp),
            )
            ThemeTextButton(onClick = onClearSongs, modifier = Modifier.fillMaxWidth()) {
                Text("清除歌曲缓存", color = colors.error)
            }
            ThemeTextButton(onClick = onClearPlaylists, modifier = Modifier.fillMaxWidth()) {
                Text("清除歌单缓存", color = colors.error)
            }
        }
    }
}

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
private fun AudioQualitySheet(
    selected: AudioQuality,
    onSelected: (AudioQuality) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surface,
        contentColor = colors.onSurface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
        ) {
            Text(
                "播放音质",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp),
            )
            Text(
                "高音质会使用更多流量；会员音质以帐号权限为准。",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            )
            Spacer(Modifier.height(8.dp))
            ANDROID_AUDIO_QUALITY_OPTIONS.forEach { quality ->
                val isSelected = quality == selected
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .selectable(
                            selected = isSelected,
                            role = Role.RadioButton,
                            onClick = { onSelected(quality) },
                        )
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(
                        selected = isSelected,
                        onClick = null,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        quality.label,
                        style = MaterialTheme.typography.titleMedium,
                        color = if (isSelected) colors.primary else colors.onSurface,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        quality.description,
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun PlaylistDetail(
    playlist: AndroidPlaylist,
    tracks: List<AndroidTrack>,
    isLoading: Boolean,
    currentId: Long?,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onPlay: (AndroidTrack) -> Unit,
) {
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val currentTrackIndex = tracks.indexOfFirst { it.id == currentId }
    Box(modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(20.dp, 10.dp, 20.dp, if (currentTrackIndex >= 0) 96.dp else 20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回音乐库") }
                Text("歌单", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MobileArtwork(playlist.coverUrl, playlist.title, Modifier.size(96.dp), 20.dp)
                Spacer(Modifier.width(18.dp))
                Column(Modifier.weight(1f)) {
                    Text(playlist.title, style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(5.dp))
                    Text(playlist.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text("${tracks.size.takeIf { it > 0 } ?: playlist.trackCount} 首", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        if (isLoading && tracks.isEmpty()) item { QuietState("正在打开歌单…") }
        if (!isLoading && tracks.isEmpty()) item { QuietState("这个歌单暂时没有歌曲。") }
            items(tracks, key = AndroidTrack::id) { TrackRow(it, it.id == currentId) { onPlay(it) } }
        }
        if (currentTrackIndex >= 0) {
            ExtendedFloatingActionButton(
                onClick = { scope.launch { listState.animateScrollToItem(currentTrackIndex + 2) } },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 20.dp, bottom = 20.dp),
                shape = RoundedCornerShape(16.dp),
                containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                contentColor = MaterialTheme.colorScheme.primary,
                elevation = FloatingActionButtonDefaults.elevation(defaultElevation = 4.dp, pressedElevation = 2.dp),
                icon = { Icon(Icons.Outlined.MyLocation, null, Modifier.size(18.dp)) },
                text = { Text("定位当前歌曲", style = MaterialTheme.typography.labelLarge) },
            )
        }
    }
}

@Composable
private fun MobileHeader(controller: AndroidGatewayController, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Lazer", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
        }
        IconButton(onClick = controller::toggleTheme) { Icon(if (controller.isDark) Icons.Outlined.LightMode else Icons.Outlined.DarkMode, "切换主题") }
        IconButton(onClick = controller::openSettings) {
            Icon(Icons.Outlined.Settings, "打开设置")
        }
    }
}

@Composable
private fun SectionTitle(title: String, subtitle: String? = null) {
    Column {
        Text(title, style = MaterialTheme.typography.titleLarge)
        subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun PlaylistStrip(playlists: List<AndroidPlaylist>, onOpen: (AndroidPlaylist) -> Unit) {
    if (playlists.isEmpty()) {
        QuietState("歌单会在连接成功后显示。")
    } else {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(playlists, key = AndroidPlaylist::id) { playlist ->
                Column(
                    Modifier.width(158.dp).clip(RoundedCornerShape(18.dp)).clickable(role = Role.Button) { onOpen(playlist) }.padding(bottom = 4.dp),
                ) {
                    MobileArtwork(playlist.coverUrl, playlist.title, Modifier.size(158.dp), 18.dp)
                    Spacer(Modifier.height(10.dp))
                    Text(playlist.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(playlist.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun PlaylistListRow(playlist: AndroidPlaylist, onOpen: (AndroidPlaylist) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).clickable(role = Role.Button) { onOpen(playlist) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MobileArtwork(playlist.coverUrl, playlist.title, Modifier.size(56.dp), 14.dp)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Text(if (playlist.isLikedCollection) "我喜欢" else playlist.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(playlist.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text("${playlist.trackCount}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun TrackRow(track: AndroidTrack, current: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp))
            .background(if (current) colors.primaryContainer.copy(alpha = 0.58f) else Color.Transparent)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MobileArtwork(track.coverUrl, track.title, Modifier.size(48.dp), 12.dp)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Text(track.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOf(track.artist, track.album).filter(String::isNotBlank).joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(track.durationLabel, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
    }
}

@Composable
private fun MobileArtwork(url: String?, label: String, modifier: Modifier, cornerRadius: androidx.compose.ui.unit.Dp) {
    val colors = MaterialTheme.colorScheme
    Box(
        modifier.clip(RoundedCornerShape(cornerRadius)).background(Brush.linearGradient(listOf(colors.primaryContainer, colors.secondaryContainer))),
        contentAlignment = Alignment.Center,
    ) {
        Text(label.firstOrNull()?.toString().orEmpty(), style = MaterialTheme.typography.titleMedium, color = colors.onPrimaryContainer)
        if (!url.isNullOrBlank()) {
            AsyncImage(
                model = url,
                contentDescription = "$label 封面",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }
    }
}

@Composable
private fun SignInInvitation(onSignIn: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(22.dp), color = colors.primaryContainer.copy(alpha = 0.74f)) {
        Column(Modifier.padding(22.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(42.dp).clip(CircleShape).background(colors.surface), contentAlignment = Alignment.Center) { Icon(Icons.Outlined.Person, null, tint = colors.primary) }
                Spacer(Modifier.width(13.dp))
                Column(Modifier.weight(1f)) {
                    Text("登录后继续", style = MaterialTheme.typography.titleLarge, color = colors.onPrimaryContainer)
                    Text("先用验证码，密码和二维码在需要时再用。", style = MaterialTheme.typography.bodySmall, color = colors.onPrimaryContainer.copy(alpha = 0.74f))
                }
            }
            Spacer(Modifier.height(16.dp))
            ThemeButton(onClick = onSignIn, cornerRadius = 11.dp) { Text("登录网易云音乐") }
        }
    }
}

@Composable
private fun MiniPlayer(
    track: AndroidTrack,
    isPlaying: Boolean,
    isPreparing: Boolean,
    onOpen: () -> Unit,
    onToggle: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = Modifier.fillMaxWidth().height(76.dp).clickable(role = Role.Button, onClick = onOpen),
        color = colors.surface.copy(alpha = 0.98f),
        border = BorderStroke(1.dp, colors.outlineVariant.copy(alpha = 0.78f)),
    ) {
        Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            MobileArtwork(track.coverUrl, track.title, Modifier.size(48.dp), 12.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(track.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (isPreparing) "正在准备播放" else track.artist, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = onToggle, modifier = Modifier.size(42.dp), colors = IconButtonDefaults.iconButtonColors(containerColor = colors.primaryContainer)) {
                Icon(if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (isPlaying) "暂停" else "播放", tint = colors.onPrimaryContainer)
            }
        }
    }
}

@Composable
private fun BottomDock(selected: AndroidRootDestination, onSelect: (AndroidRootDestination) -> Unit) {
    if (LocalLazerThemeEngine.current == LazerThemeEngine.MIUIX) {
        MiuixNavigationBar(
            modifier = Modifier.fillMaxWidth(),
            showDivider = true,
            defaultWindowInsetsPadding = true,
            mode = MiuixNavigationBarDisplayMode.IconAndText,
        ) {
            AndroidRootDestination.entries.forEach { destination ->
                MiuixNavigationBarItem(
                    selected = selected == destination,
                    onClick = { onSelect(destination) },
                    icon = destination.icon(),
                    label = destination.label,
                )
            }
        }
        return
    }

    val colors = MaterialTheme.colorScheme
    Surface(Modifier.fillMaxWidth().navigationBarsPadding(), color = colors.background) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 9.dp), horizontalArrangement = Arrangement.SpaceAround) {
            AndroidRootDestination.entries.forEach { destination ->
                val active = selected == destination
                Column(
                    Modifier.clip(RoundedCornerShape(13.dp)).clickable(role = Role.Tab) { onSelect(destination) }
                        .padding(horizontal = 14.dp, vertical = 6.dp).semantics { contentDescription = "打开${destination.label}" },
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(destination.icon(), null, Modifier.size(20.dp), tint = if (active) colors.primary else colors.onSurfaceVariant)
                    Text(destination.label, style = MaterialTheme.typography.labelSmall, color = if (active) colors.primary else colors.onSurfaceVariant, fontWeight = if (active) FontWeight.Medium else FontWeight.Normal)
                }
            }
        }
    }
}

@Composable
private fun NowPlayingPage(
    snapshot: AndroidPlaybackSnapshot,
    lyricLines: List<AndroidTimedLyricLine>,
    lyricsLoading: Boolean,
    lyricsMessage: String?,
    lyricFollowDelayMillis: Long,
    lyricAnimationSpeed: LyricAnimationSpeed,
    wordLyricsEnabled: Boolean,
    isLiked: Boolean,
    onToggleLiked: () -> Unit,
    onDismiss: () -> Unit,
    onToggle: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onSeek: (Long) -> Unit,
    onLyrics: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val track = snapshot.track ?: return
    val colors = MaterialTheme.colorScheme
    val duration = snapshot.durationMillis.takeIf { it > 0L } ?: track.durationMillis
    val target = if (duration > 0) snapshot.positionMillis.toFloat() / duration else 0f
    val display by animateFloatAsState(
        target.coerceIn(0f, 1f),
        if (snapshot.isPlaying) spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessHigh) else snap(),
        label = "android-playback-progress",
    )
    var seeking by remember(track.id) { mutableStateOf(false) }
    var seekProgress by remember(track.id) { mutableFloatStateOf(display) }
    LaunchedEffect(display, seeking) { if (!seeking) seekProgress = display }

    // Keep the visual background edge-to-edge; only the controls need to avoid system bars.
    Surface(modifier.fillMaxSize(), color = colors.background) {
        if (isLandscapeLayout()) {
            Box(Modifier.fillMaxSize()) {
                AndroidAlbumFlowBackground(
                    track = track,
                    modifier = Modifier.fillMaxSize(),
                    cornerRadius = 0.dp,
                    veil = Color(0xFF1D282D).copy(alpha = 0.38f),
                )
                Row(
                    Modifier
                        .fillMaxSize()
                        .statusBarsPadding()
                        .navigationBarsPadding()
                        .padding(horizontal = 36.dp, vertical = 0.dp),
                ) {
                    Column(Modifier.widthIn(min = 230.dp, max = 320.dp).fillMaxSize()) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "收起播放器", tint = Color(0xFFC7D3D5)) }
                            Text("正在播放", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = Color(0xFFC7D3D5))
                        }
                        MobileArtwork(track.coverUrl, track.title, Modifier.size(132.dp).align(Alignment.CenterHorizontally), 20.dp)
                        Spacer(Modifier.height(10.dp))
                        Text(track.title, color = Color(0xFFF2F6F4), style = MaterialTheme.typography.titleLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(track.artist, color = Color(0xFFC7D3D5), style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.weight(1f))
                        ThinSeekBar(
                            progress = seekProgress,
                            bufferedProgress = snapshot.bufferedFraction,
                            onSeek = { seeking = true; seekProgress = it },
                            onFinished = { seeking = false; onSeek((duration * seekProgress).toLong()) },
                        )
                        Row(Modifier.fillMaxWidth()) {
                            Text(formatPlaybackTime((duration * seekProgress).toLong()), style = MaterialTheme.typography.labelSmall, color = Color(0xFFC7D3D5))
                            Spacer(Modifier.weight(1f))
                            Text(formatPlaybackTime(duration), style = MaterialTheme.typography.labelSmall, color = Color(0xFFC7D3D5))
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = onPrevious, modifier = Modifier.size(48.dp)) { Icon(Icons.Filled.SkipPrevious, "上一首", Modifier.size(30.dp), tint = Color(0xFFE7ECEB)) }
                            IconButton(onClick = onToggle, modifier = Modifier.size(60.dp), colors = IconButtonDefaults.iconButtonColors(containerColor = Color(0xFFE7ECEB), contentColor = Color(0xFF1D282D))) {
                                Icon(if (snapshot.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (snapshot.isPlaying) "暂停" else "播放", Modifier.size(32.dp))
                            }
                            IconButton(onClick = onNext, modifier = Modifier.size(48.dp)) { Icon(Icons.Filled.SkipNext, "下一首", Modifier.size(30.dp), tint = Color(0xFFE7ECEB)) }
                            IconButton(onClick = onToggleLiked, modifier = Modifier.size(48.dp)) {
                                Icon(if (isLiked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder, if (isLiked) "移出我喜欢" else "加入我喜欢", tint = if (isLiked) colors.primary else Color(0xFFE7ECEB))
                            }
                        }
                    }
                    Spacer(Modifier.width(24.dp))
                    AndroidLyricsViewport(
                        track = track,
                        lines = lyricLines,
                        isLoading = lyricsLoading,
                        message = lyricsMessage,
                        positionMillis = snapshot.positionMillis,
                        followDelayMillis = lyricFollowDelayMillis,
                        animationSpeed = lyricAnimationSpeed,
                        wordLyricsEnabled = wordLyricsEnabled,
                        onSeek = onSeek,
                        modifier = Modifier.weight(1f).fillMaxSize(),
                    )
                }
            }
        } else {
            Column(
                Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = 24.dp, vertical = 16.dp),
            ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "收起播放器", tint = colors.onSurfaceVariant) }
                Text("正在播放", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
            }
            Spacer(Modifier.weight(0.4f))
            MobileArtwork(track.coverUrl, track.title, Modifier.fillMaxWidth().heightIn(max = 390.dp).height(320.dp), 30.dp)
            Spacer(Modifier.height(32.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(track.title, style = MaterialTheme.typography.headlineMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(track.artist, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                IconButton(onClick = onToggleLiked, modifier = Modifier.size(48.dp)) {
                    Icon(if (isLiked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder, if (isLiked) "移出我喜欢" else "加入我喜欢", tint = if (isLiked) colors.primary else colors.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(28.dp))
            ThinSeekBar(
                progress = seekProgress,
                bufferedProgress = snapshot.bufferedFraction,
                onSeek = { seeking = true; seekProgress = it },
                onFinished = { seeking = false; onSeek((duration * seekProgress).toLong()) },
            )
            Row(Modifier.fillMaxWidth()) {
                Text(formatPlaybackTime((duration * seekProgress).toLong()), style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Text(formatPlaybackTime(duration), style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
            }
            Spacer(Modifier.height(18.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onPrevious, modifier = Modifier.size(50.dp)) { Icon(Icons.Filled.SkipPrevious, "上一首", Modifier.size(31.dp)) }
                IconButton(onClick = onToggle, modifier = Modifier.size(68.dp), colors = IconButtonDefaults.iconButtonColors(containerColor = colors.primary, contentColor = colors.onPrimary)) {
                    Icon(if (snapshot.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (snapshot.isPlaying) "暂停" else "播放", Modifier.size(35.dp))
                }
                IconButton(onClick = onNext, modifier = Modifier.size(50.dp)) { Icon(Icons.Filled.SkipNext, "下一首", Modifier.size(31.dp)) }
            }
            Spacer(Modifier.weight(1f))
            ThemeTextButton(onClick = onLyrics, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Icon(Icons.Outlined.Lyrics, null, Modifier.size(18.dp)); Spacer(Modifier.width(7.dp)); Text("歌词")
            }
            snapshot.message?.let { Text(it, Modifier.fillMaxWidth().padding(bottom = 8.dp), style = MaterialTheme.typography.bodySmall, color = colors.error, textAlign = TextAlign.Center) }
            }
        }
    }
}

/** Same visual construction as the desktop control: base rail, buffered rail, then blue playhead. */
@Composable
private fun ThinSeekBar(
    progress: Float,
    bufferedProgress: Float,
    onSeek: (Float) -> Unit,
    onFinished: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val fraction = progress.coerceIn(0f, 1f)
    val buffered = maxOf(fraction, bufferedProgress.coerceIn(0f, 1f))
    BoxWithConstraints(
        Modifier.height(20.dp).fillMaxWidth().pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val width = size.width.coerceAtLeast(1)
                onSeek((down.position.x / width).coerceIn(0f, 1f)); down.consume()
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    onSeek((change.position.x / width).coerceIn(0f, 1f)); change.consume()
                    if (!change.pressed) break
                }
                onFinished()
            }
        },
        contentAlignment = Alignment.CenterStart,
    ) {
        val travel = (maxWidth - 10.dp).coerceAtLeast(0.dp)
        Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(colors.surfaceVariant.copy(alpha = 0.95f)))
        Box(Modifier.fillMaxWidth(buffered).height(3.dp).clip(CircleShape).background(colors.onSurfaceVariant.copy(alpha = 0.34f)))
        Box(Modifier.fillMaxWidth(fraction).height(3.dp).clip(CircleShape).background(colors.primary))
        Box(Modifier.padding(start = travel * fraction).size(10.dp).clip(CircleShape).background(colors.primary))
    }
}

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
private fun LoginSheet(controller: AndroidGatewayController) {
    val colors = MaterialTheme.colorScheme
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val contentScrollState = rememberScrollState()
    ModalBottomSheet(
        onDismissRequest = controller::closeLogin,
        sheetState = sheetState,
        containerColor = colors.surface,
        contentColor = colors.onSurface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(contentScrollState)
                .padding(horizontal = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("登录后继续", style = MaterialTheme.typography.headlineSmall)
            Text("先用验证码；遇到问题时再试密码或二维码。", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                AndroidLoginMethod.entries.forEach { method ->
                    ThemeTextButton(onClick = { controller.selectLoginMethod(method) }) {
                        Text(method.label, color = if (method == controller.loginMethod) colors.primary else colors.onSurfaceVariant, fontWeight = if (method == controller.loginMethod) FontWeight.SemiBold else FontWeight.Normal)
                    }
                }
            }
            when (controller.loginMethod) {
                AndroidLoginMethod.CAPTCHA -> CaptchaLogin(controller)
                AndroidLoginMethod.PASSWORD -> PasswordLogin(controller)
                AndroidLoginMethod.QR_CODE -> QrLogin(controller)
            }
            controller.loginMessage?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = if (it.contains("成功") || it.contains("已发送")) colors.primary else colors.error)
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun CaptchaLogin(controller: AndroidGatewayController) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        PhoneField(controller.loginPhone, controller::updateLoginPhone)
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                controller.loginCaptcha, controller::updateLoginCaptcha, Modifier.weight(1f), label = { Text("验证码") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
            )
            Spacer(Modifier.width(10.dp))
            ThemeTextButton(onClick = controller::sendCaptcha, enabled = !controller.isSendingCaptcha) {
                Text(if (controller.isSendingCaptcha) "发送中" else if (controller.captchaSent) "重新发送" else "获取验证码")
            }
        }
        ThemeButton(
            onClick = controller::submitCaptchaLogin,
            modifier = Modifier.fillMaxWidth(),
            enabled = !controller.isSubmittingLogin,
        ) { Text(if (controller.isSubmittingLogin) "正在登录" else "用验证码登录") }
    }
}

@Composable
private fun PasswordLogin(controller: AndroidGatewayController) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        PhoneField(controller.loginPhone, controller::updateLoginPhone)
        OutlinedTextField(
            controller.loginPassword, controller::updateLoginPassword, Modifier.fillMaxWidth(), label = { Text("密码") }, singleLine = true,
            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        )
        ThemeButton(
            onClick = controller::submitPasswordLogin,
            modifier = Modifier.fillMaxWidth(),
            enabled = !controller.isSubmittingLogin,
        ) { Text(if (controller.isSubmittingLogin) "正在登录" else "用密码登录") }
    }
}

@Composable
private fun PhoneField(value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value, onChange, Modifier.fillMaxWidth(), label = { Text("手机号") }, leadingIcon = { Text("+86", style = MaterialTheme.typography.labelLarge) },
        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone, imeAction = ImeAction.Next),
    )
}

@Composable
private fun QrLogin(controller: AndroidGatewayController) {
    val image = remember(controller.qrImageData) { decodeQrImage(controller.qrImageData) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (image != null) {
            androidx.compose.foundation.Image(image, "网易云音乐登录二维码", Modifier.size(208.dp).clip(RoundedCornerShape(18.dp)))
        } else {
            Box(Modifier.size(208.dp).clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                Text(if (controller.qrState == AndroidQrLoginState.CREATING) "正在生成二维码…" else "二维码暂时不可用", color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
        Text(
            when (controller.qrState) {
                AndroidQrLoginState.WAITING_FOR_SCAN -> "请用网易云音乐扫描二维码"
                AndroidQrLoginState.WAITING_FOR_CONFIRMATION -> "请在网易云音乐中确认登录"
                AndroidQrLoginState.EXPIRED -> "二维码已过期"
                AndroidQrLoginState.ERROR -> "二维码生成失败"
                else -> ""
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (controller.qrState == AndroidQrLoginState.EXPIRED || controller.qrState == AndroidQrLoginState.ERROR) {
            ThemeTextButton(controller::startQrLogin) { Text("重新生成二维码") }
        }
    }
}

private fun decodeQrImage(data: String?): androidx.compose.ui.graphics.ImageBitmap? = runCatching {
    val encoded = data?.substringAfter("base64,", data).orEmpty()
    val bytes = Base64.decode(encoded, Base64.DEFAULT)
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
}.getOrNull()

@Composable
private fun QuietState(text: String) {
    Text(text, Modifier.fillMaxWidth().padding(vertical = 14.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
}

@Composable
private fun MessageBanner(text: String, modifier: Modifier) {
    Surface(modifier, shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = 5.dp) {
        Text(text, Modifier.padding(horizontal = 14.dp, vertical = 10.dp), style = MaterialTheme.typography.bodySmall)
    }
}

private fun AndroidRootDestination.icon() = when (this) {
    AndroidRootDestination.HOME -> Icons.Outlined.Home
    AndroidRootDestination.DISCOVER -> Icons.Outlined.Explore
    AndroidRootDestination.SEARCH -> Icons.Outlined.Search
    AndroidRootDestination.LIBRARY -> Icons.Outlined.LibraryMusic
    AndroidRootDestination.ME -> Icons.Outlined.Person
}

@Preview(showBackground = true, widthDp = 393, heightDp = 852)
@Composable
private fun AndroidLazerPreview() = AndroidLazerApp()
