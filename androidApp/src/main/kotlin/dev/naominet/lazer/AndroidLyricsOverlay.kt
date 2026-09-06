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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.isActive

@Composable
internal fun AndroidLyricsPage(
    track: AndroidTrack?,
    lines: List<AndroidTimedLyricLine>,
    isLoading: Boolean,
    message: String?,
    positionMillis: Long,
    followDelayMillis: Long,
    onBack: () -> Unit,
    onSeek: (Long) -> Unit,
) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    Box(Modifier.fillMaxSize()) {
        AndroidAlbumFlowBackground(
            track = track,
            modifier = Modifier.fillMaxSize(),
            cornerRadius = 0.dp,
            veil = Color(0xFF1D282D).copy(alpha = 0.38f),
        )
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            if (landscape) {
                Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp)) {
                    IconButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart)) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回播放器", tint = Color(0xFFE7ECEB))
                    }
                    LyricTrackHeader(track, Modifier.align(Alignment.Center).padding(horizontal = 56.dp))
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回播放器", tint = Color(0xFFE7ECEB))
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
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    when {
        track == null -> LyricEmpty("选一首音乐后，歌词会出现在这里。", modifier)
        isLoading -> LyricEmpty("正在加载歌词…", modifier)
        lines.isEmpty() -> LyricEmpty(message ?: "这首歌暂时没有歌词", modifier)
        else -> AnimatedLyricsViewport(
            trackId = track.id,
            lines = lines,
            positionMillis = positionMillis,
            followDelayMillis = followDelayMillis,
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
    onSeek: (Long) -> Unit,
    modifier: Modifier,
) {
    val density = LocalDensity.current
    val activeIndex = remember(lines, positionMillis) { activeAndroidLyricIndex(lines, positionMillis) }
    val currentPositionMillis by rememberUpdatedState(positionMillis)
    val currentLines by rememberUpdatedState(lines)
    val currentFollowDelayMillis by rememberUpdatedState(followDelayMillis)
    val rowPitchPx = with(density) { 112.dp.toPx() }
    val maxScroll = ((lines.size - 1).coerceAtLeast(0)) * rowPitchPx
    val currentMaxScroll by rememberUpdatedState(maxScroll)
    var followPlayback by remember { mutableStateOf(true) }
    var isDragging by remember { mutableStateOf(false) }
    var manualAtMillis by remember { mutableLongStateOf(0L) }
    var lyricScroll by remember { mutableFloatStateOf(0f) }
    var flingVelocity by remember { mutableFloatStateOf(0f) }
    var lastDragNanos by remember { mutableLongStateOf(0L) }
    var lastFrameNanos by remember { mutableLongStateOf(0L) }

    LaunchedEffect(lines.size, trackId) {
        followPlayback = true
        isDragging = false
        flingVelocity = 0f
        lyricScroll = activeAndroidLyricIndex(lines, positionMillis).coerceAtLeast(0) * rowPitchPx
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
                    followPlayback = true
                }
                if (followPlayback) {
                    flingVelocity = 0f
                    val liveIndex = activeAndroidLyricIndex(currentLines, currentPositionMillis)
                    if (liveIndex >= 0) {
                        val target = (liveIndex * rowPitchPx).coerceIn(0f, currentMaxScroll)
                        val distance = target - lyricScroll
                        if (kotlin.math.abs(distance) > 0.05f) {
                            val approach = (1.0 - kotlin.math.exp(-11.0 * deltaSeconds)).toFloat()
                            lyricScroll += distance * approach
                        } else {
                            lyricScroll = target
                        }
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
        val visualIndex = if (rowPitchPx == 0f) 0f else lyricScroll / rowPitchPx
        lines.forEachIndexed { index, line ->
            val lineCenterPx = centerYPx + index * rowPitchPx - lyricScroll
            if (lineCenterPx < -120f || lineCenterPx > heightPx + 120f) return@forEachIndexed
            val distance = kotlin.math.abs(index - visualIndex)
            val focus = if (activeIndex < 0) 0f else (1f - distance).coerceAtLeast(0f)
            val ambient = (1f - distance / 4f).coerceAtLeast(0f)
            val scale = (0.92f + focus * 0.16f + ambient * 0.03f).coerceIn(0.90f, 1.14f)
            val alpha = ((130f * ambient + 125f * focus) / 255f).coerceIn(0.125f, 1f)
            val hasTranslation = !line.translation.isNullOrBlank()
            val rowHeight = if (hasTranslation) 124.dp else 74.dp
            val scaledRowHeight = rowHeight * scale
            val textWidthFraction = (1f / scale).coerceAtMost(1f)
            val y = with(density) { lineCenterPx.toDp() } - scaledRowHeight / 2

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .offset(y = y)
                    .height(scaledRowHeight)
                    .padding(horizontal = 26.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .clickable {
                        followPlayback = true
                        onSeek(line.timeMillis)
                        lyricScroll = index * rowPitchPx
                    },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        text = line.text,
                        modifier = Modifier.fillMaxWidth(textWidthFraction).graphicsLayer {
                            scaleX = scale
                            scaleY = scale
                            this.alpha = alpha
                            transformOrigin = TransformOrigin.Center
                        },
                        color = Color(0xFFF2F6F4),
                        style = MaterialTheme.typography.bodyLarge.copy(
                            fontSize = 27.sp,
                            lineHeight = 37.sp,
                            fontWeight = if (focus > 0.55f) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        textAlign = TextAlign.Center,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (hasTranslation) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = line.translation.orEmpty(),
                            modifier = Modifier.fillMaxWidth(textWidthFraction).graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                this.alpha = alpha
                                transformOrigin = TransformOrigin.Center
                            },
                            color = Color(0xFFC7D3D5),
                            style = MaterialTheme.typography.bodyMedium.copy(lineHeight = 22.sp),
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

@Composable
private fun LyricTrackHeader(track: AndroidTrack?, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            track?.title ?: "歌词",
            modifier = Modifier.fillMaxWidth(),
            color = Color(0xFFE7ECEB),
            style = MaterialTheme.typography.titleSmall,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            track?.artist.orEmpty(),
            modifier = Modifier.fillMaxWidth(),
            color = Color(0xFFC7D3D5),
            style = MaterialTheme.typography.labelSmall,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun LyricEmpty(text: String, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text,
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0xFF1D282D).copy(alpha = 0.42f))
                .padding(horizontal = 20.dp, vertical = 14.dp),
            color = Color(0xFFE7ECEB),
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
        )
    }
}
