package dev.naominet.lazer

import android.content.res.Configuration
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.isActive
import kotlin.math.roundToInt

@Composable
internal fun AndroidLyricsPage(
    track: AndroidTrack?,
    lines: List<AndroidTimedLyricLine>,
    isLoading: Boolean,
    message: String?,
    positionMillis: Long,
    followDelayMillis: Long,
    animationSpeed: LyricAnimationSpeed,
    wordLyricsEnabled: Boolean,
    lyricGlowEnabled: Boolean,
    lyricFontSizeSp: Int,
    showFullLyrics: Boolean,
    onBack: () -> Unit,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val colors = MaterialTheme.colorScheme
    Box(modifier.fillMaxSize()) {
        AndroidAlbumFlowBackground(
            track = track,
            modifier = Modifier.fillMaxSize(),
            cornerRadius = 0.dp,
            veil = colors.background.copy(alpha = 0.38f),
        )
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            if (landscape) {
                Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp)) {
                    IconButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart)) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("lyrics.back_to_player"), tint = colors.onBackground)
                    }
                    LyricTrackHeader(track, Modifier.align(Alignment.Center).padding(horizontal = 56.dp))
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("lyrics.back_to_player"), tint = colors.onBackground)
                    }
                    LyricTrackHeader(track, Modifier.weight(1f).padding(end = 48.dp))
                }
            }
            AndroidLyricsViewport(
                track = track,
                lines = lines,
                isLoading = isLoading,
                message = message,
                positionMillis = positionMillis,
                followDelayMillis = followDelayMillis,
                animationSpeed = animationSpeed,
                wordLyricsEnabled = wordLyricsEnabled,
                lyricGlowEnabled = lyricGlowEnabled,
                lyricFontSizeSp = lyricFontSizeSp,
                showFullLyrics = showFullLyrics,
                onSeek = onSeek,
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        }
    }
}

@Composable
internal fun AndroidLyricsViewport(
    track: AndroidTrack?,
    lines: List<AndroidTimedLyricLine>,
    isLoading: Boolean,
    message: String?,
    positionMillis: Long,
    followDelayMillis: Long,
    animationSpeed: LyricAnimationSpeed,
    wordLyricsEnabled: Boolean,
    lyricGlowEnabled: Boolean,
    lyricFontSizeSp: Int,
    showFullLyrics: Boolean,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    when {
        track == null -> LyricEmpty(tr("lyrics.empty"), modifier)
        isLoading -> LyricEmpty(tr("lyrics.loading"), modifier)
        lines.isEmpty() -> LyricEmpty(message ?: tr("lyrics.none"), modifier)
        else -> AnimatedLyricsViewport(
            trackId = track.id,
            lines = lines,
            positionMillis = positionMillis,
            followDelayMillis = followDelayMillis,
            animationSpeed = animationSpeed,
            wordLyricsEnabled = wordLyricsEnabled,
            lyricGlowEnabled = lyricGlowEnabled,
            lyricFontSizeSp = lyricFontSizeSp,
            showFullLyrics = showFullLyrics,
            onSeek = onSeek,
            modifier = modifier,
        )
    }
}

@Composable
private fun AnimatedLyricsViewport(
    trackId: Long,
    lines: List<AndroidTimedLyricLine>,
    positionMillis: Long,
    followDelayMillis: Long,
    animationSpeed: LyricAnimationSpeed,
    wordLyricsEnabled: Boolean,
    lyricGlowEnabled: Boolean,
    lyricFontSizeSp: Int,
    showFullLyrics: Boolean,
    onSeek: (Long) -> Unit,
    modifier: Modifier,
) {
    val density = LocalDensity.current
    val colors = MaterialTheme.colorScheme
    val isDark = colors.background.luminance() < 0.5f
    val activeIndex = remember(lines, positionMillis) { activeAndroidLyricIndex(lines, positionMillis) }
    val currentActiveIndex by rememberUpdatedState(activeIndex)
    val currentAnimationSpeed by rememberUpdatedState(animationSpeed)
    val currentPositionMillis by rememberUpdatedState(positionMillis)
    val currentLines by rememberUpdatedState(lines)
    val currentFollowDelayMillis by rememberUpdatedState(followDelayMillis)
    val mainFontSp = lyricFontSizeSp.sp
    val mainLineHeightSp = (lyricFontSizeSp * 1.38f).sp
    val translationFontSp = (lyricFontSizeSp * 0.50f).coerceIn(12f, 20f).sp
    val translationLineHeightSp = (translationFontSp.value * 1.38f).sp
    val lyricMaxLines = if (showFullLyrics) Int.MAX_VALUE else 2
    val measuredRowHeightsPx = remember(lines, lyricFontSizeSp, showFullLyrics) {
        mutableStateMapOf<Int, Int>()
    }
    val measuredMainHeightsPx = remember(lines, lyricFontSizeSp, showFullLyrics) {
        mutableStateMapOf<Int, Int>()
    }
    val minimumRowGapPx = with(density) { 12.dp.toPx() }
    val maximumRowGapPx = with(density) { 36.dp.toPx() }
    val minimumTranslationGapPx = with(density) { 7.dp.toPx() }
    val maximumTranslationGapPx = with(density) { 22.dp.toPx() }
    val estimatedMainHeightPx = with(density) { mainLineHeightSp.toPx() }
    val estimatedTranslationHeightPx = with(density) { translationLineHeightSp.toPx() }
    val rowHeightsPx = lines.mapIndexed { index, line ->
        measuredRowHeightsPx[index]?.toFloat() ?: (
            estimatedMainHeightPx + if (line.translation.isNullOrBlank()) {
                0f
            } else {
                lyricTranslationGapPx(
                    estimatedMainHeightPx,
                    minimumTranslationGapPx,
                    maximumTranslationGapPx,
                ) + estimatedTranslationHeightPx
            }
        )
    }
    val lineCentersPx = lyricLineCenters(
        rowHeightsPx = rowHeightsPx,
        minimumGapPx = minimumRowGapPx,
        maximumGapPx = maximumRowGapPx,
    )
    val maxScroll = lineCentersPx.lastOrNull() ?: 0f
    val currentLineCentersPx by rememberUpdatedState(lineCentersPx)
    val currentMaxScroll by rememberUpdatedState(maxScroll)
    var followPlayback by remember { mutableStateOf(true) }
    var isDragging by remember { mutableStateOf(false) }
    var manualAtMillis by remember { mutableLongStateOf(0L) }
    var lyricScroll by remember { mutableFloatStateOf(0f) }
    var flingVelocity by remember { mutableFloatStateOf(0f) }
    var lastDragNanos by remember { mutableLongStateOf(0L) }
    var lastFrameNanos by remember { mutableLongStateOf(0L) }
    val lyricLineMotion = remember { LyricLineMotionField() }
    var lyricMotionRevision by remember { mutableLongStateOf(0L) }

    LaunchedEffect(lines.size, trackId, lyricFontSizeSp, showFullLyrics) {
        followPlayback = true
        isDragging = false
        flingVelocity = 0f
        val initialIndex = activeAndroidLyricIndex(lines, positionMillis).coerceAtLeast(0)
        lyricScroll = lineCentersPx.getOrElse(initialIndex) { 0f }
        lyricLineMotion.reset(lines.size, lyricScroll)
        lyricMotionRevision++
        lastFrameNanos = 0L
    }
    LaunchedEffect(Unit) {
        while (isActive) {
            withFrameNanos { now ->
                val deltaSeconds = if (lastFrameNanos == 0L) {
                    1f / 60f
                } else {
                    ((now - lastFrameNanos) / 1_000_000_000.0).toFloat().coerceIn(0.001f, 0.05f)
                }
                lastFrameNanos = now
                if (!followPlayback && !isDragging && kotlin.math.abs(flingVelocity) < 8f &&
                    System.currentTimeMillis() - manualAtMillis > currentFollowDelayMillis
                ) {
                    lyricLineMotion.snapTo(lyricScroll)
                    followPlayback = true
                }
                if (followPlayback) {
                    flingVelocity = 0f
                    val liveIndex = activeAndroidLyricIndex(currentLines, currentPositionMillis)
                    if (liveIndex >= 0) {
                        val target = currentLineCentersPx.getOrElse(liveIndex) { currentMaxScroll }
                            .coerceIn(0f, currentMaxScroll)
                        val intervalMillis = currentLines.getOrNull(liveIndex - 1)?.let { previous ->
                            (currentLines[liveIndex].timeMillis - previous.timeMillis).coerceAtLeast(0L)
                        }
                        if (lyricLineMotion.advance(
                                target = target,
                                activeIndex = liveIndex,
                                seconds = deltaSeconds,
                                intervalMillis = intervalMillis,
                                speed = currentAnimationSpeed,
                            )
                        ) {
                            lyricMotionRevision++
                        }
                        lyricScroll = lyricLineMotion.positionFor(liveIndex).coerceIn(0f, currentMaxScroll)
                    }
                } else if (!isDragging && kotlin.math.abs(flingVelocity) >= 8f) {
                    val nextScroll = (lyricScroll + flingVelocity * deltaSeconds).coerceIn(0f, currentMaxScroll)
                    if (nextScroll == 0f || nextScroll == currentMaxScroll) flingVelocity = 0f
                    lyricScroll = nextScroll
                    flingVelocity *= kotlin.math.exp((-5.2f * deltaSeconds).toDouble()).toFloat()
                    manualAtMillis = System.currentTimeMillis()
                }
            }
        }
    }

    BoxWithConstraints(
        modifier = modifier
            .clipToBounds()
            .pointerInput(lines.size, maxScroll) {
                detectVerticalDragGestures(
                    onDragStart = {
                        if (currentActiveIndex >= 0) {
                            lyricScroll = lyricLineMotion.positionFor(currentActiveIndex)
                                .coerceIn(0f, currentMaxScroll)
                        }
                        lyricLineMotion.snapTo(lyricScroll)
                        followPlayback = false
                        isDragging = true
                        flingVelocity = 0f
                        lastDragNanos = 0L
                        manualAtMillis = System.currentTimeMillis()
                    },
                    onDragEnd = {
                        isDragging = false
                        manualAtMillis = System.currentTimeMillis()
                    },
                    onDragCancel = {
                        isDragging = false
                        flingVelocity = 0f
                        manualAtMillis = System.currentTimeMillis()
                    },
                    onVerticalDrag = { change, dragAmount ->
                        change.consume()
                        val now = change.uptimeMillis * 1_000_000L
                        if (lastDragNanos != 0L) {
                            val deltaSeconds = ((now - lastDragNanos) / 1_000_000_000f).coerceAtLeast(0.001f)
                            val measuredVelocity = -dragAmount / deltaSeconds
                            flingVelocity = flingVelocity * 0.65f + measuredVelocity * 0.35f
                        }
                        lastDragNanos = now
                        manualAtMillis = System.currentTimeMillis()
                        lyricScroll = (lyricScroll - dragAmount).coerceIn(0f, maxScroll)
                    },
                )
            },
    ) {
        val centerYPx = with(density) { (maxHeight / 2).toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        val motionRevision = lyricMotionRevision
        val visualScroll = if (followPlayback && activeIndex >= 0 && motionRevision >= 0) {
            lyricLineMotion.positionFor(activeIndex)
        } else {
            lyricScroll
        }
        val visualIndex = lyricVisualIndex(lineCentersPx, visualScroll)
        lines.forEachIndexed { index, line ->
            val rowScroll = if (followPlayback && motionRevision >= 0) {
                lyricLineMotion.positionFor(index)
            } else {
                lyricScroll
            }
            val rowHeightPx = rowHeightsPx[index]
            val lineCenterPx = centerYPx + lineCentersPx[index] - rowScroll
            if (lineCenterPx < -rowHeightPx || lineCenterPx > heightPx + rowHeightPx) {
                return@forEachIndexed
            }
            val distance = kotlin.math.abs(index - visualIndex)
            val focus = androidx.compose.runtime.key(trackId, index) {
                animatedLyricFocus(index == activeIndex, animationSpeed)
            }
            val ambient = (1f - distance / 4f).coerceAtLeast(0f)
            val scale = 0.96f + focus * 0.08f
            val alpha = (0.24f + ambient * 0.20f) * (1f - focus) + focus
            val hasTranslation = !line.translation.isNullOrBlank()
            val textWidthFraction = 1f / 1.04f
            val mainHeightPx = measuredMainHeightsPx[index]?.toFloat() ?: estimatedMainHeightPx
            val translationGap = with(density) {
                lyricTranslationGapPx(
                    mainHeightPx,
                    minimumTranslationGapPx,
                    maximumTranslationGapPx,
                ).toDp()
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .offset {
                        IntOffset(
                            x = 0,
                            y = (lineCenterPx - rowHeightPx / 2f).roundToInt(),
                        )
                    }
                    .padding(horizontal = 26.dp)
                    .onSizeChanged { size ->
                        if (measuredRowHeightsPx[index] != size.height) {
                            measuredRowHeightsPx[index] = size.height
                        }
                    }
                    .clickable {
                        lyricLineMotion.snapTo(lyricScroll)
                        followPlayback = true
                        onSeek(line.timeMillis)
                    },
                contentAlignment = Alignment.TopCenter,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    androidx.compose.runtime.key(trackId, index) {
                        AmllLyricText(
                            text = line.text,
                            words = line.words,
                            positionMillis = positionMillis,
                            active = wordLyricsEnabled && index == activeIndex,
                            currentLine = index == activeIndex,
                            color = colors.onBackground,
                            shadowColor = if (isDark) Color.White else Color.Black,
                            glowEnabled = lyricGlowEnabled,
                            speed = animationSpeed,
                            modifier = Modifier
                                .fillMaxWidth(textWidthFraction)
                                .onSizeChanged { size ->
                                    if (measuredMainHeightsPx[index] != size.height) {
                                        measuredMainHeightsPx[index] = size.height
                                    }
                                }
                                .graphicsLayer {
                                    scaleX = scale
                                    scaleY = scale
                                    this.alpha = alpha
                                    transformOrigin = TransformOrigin.Center
                                },
                            style = MaterialTheme.typography.bodyLarge.copy(
                                fontSize = mainFontSp,
                                lineHeight = mainLineHeightSp,
                                fontWeight = FontWeight.SemiBold,
                            ),
                            textAlign = TextAlign.Center,
                            maxLines = lyricMaxLines,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (hasTranslation) {
                        Spacer(Modifier.height(translationGap))
                        Text(
                            text = line.translation.orEmpty(),
                            modifier = Modifier.fillMaxWidth(textWidthFraction).graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                this.alpha = alpha
                                transformOrigin = TransformOrigin.Center
                            },
                            color = colors.onSurfaceVariant,
                            style = MaterialTheme.typography.bodyMedium.copy(
                                fontSize = translationFontSp,
                                lineHeight = translationLineHeightSp,
                            ),
                            textAlign = TextAlign.Center,
                            maxLines = lyricMaxLines,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LyricTrackHeader(track: AndroidTrack?, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            track?.title ?: tr("lyrics.nothing"),
            modifier = Modifier.fillMaxWidth(),
            color = colors.onBackground,
            style = MaterialTheme.typography.titleSmall,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            track?.artist.orEmpty(),
            modifier = Modifier.fillMaxWidth(),
            color = colors.onSurfaceVariant,
            style = MaterialTheme.typography.labelSmall,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun LyricEmpty(text: String, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text,
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .background(colors.background.copy(alpha = 0.42f))
                .padding(horizontal = 20.dp, vertical = 14.dp),
            color = colors.onBackground,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
        )
    }
}
